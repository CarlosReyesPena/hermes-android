import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/services/gateway_turn_journal.dart';

const _digestA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _digestB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _mobileA = '11111111-1111-4111-8111-111111111111';
const _mobileB = '22222222-2222-4222-8222-222222222222';
const _clientA = '33333333-3333-4333-8333-333333333333';
const _baseMs = 1720000000000;

class _MemoryJournalStore implements GatewayTurnJournalStore {
  String? value;
  String? legacyValue;
  bool unavailable = false;
  bool failNextWrite = false;
  bool corruptNextReadback = false;
  bool failLegacyDelete = false;
  Duration delay = Duration.zero;

  @override
  Future<void> delete() async {
    await Future<void>.delayed(delay);
    if (unavailable) throw StateError('unavailable');
    value = null;
  }

  @override
  Future<String?> read() async {
    await Future<void>.delayed(delay);
    if (unavailable) throw StateError('unavailable');
    if (corruptNextReadback) {
      corruptNextReadback = false;
      return '${value ?? ''}corrupt';
    }
    return value;
  }

  @override
  Future<void> write(String newValue) async {
    await Future<void>.delayed(delay);
    if (unavailable) throw StateError('unavailable');
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('write failed');
    }
    value = newValue;
  }

  @override
  Future<void> deleteLegacy() async {
    await Future<void>.delayed(delay);
    if (unavailable || failLegacyDelete) throw StateError('unavailable');
    legacyValue = null;
  }

  @override
  Future<String?> readLegacy() async {
    await Future<void>.delayed(delay);
    if (unavailable) throw StateError('unavailable');
    return legacyValue;
  }
}

GatewayTurnJournalBinding _binding({
  String connectionId = 'connection-a',
  String endpointDigest = _digestA,
  String localSessionId = 'local-session-a',
  String mobileSessionId = _mobileA,
  String storedSessionId = 'stored-session-a',
  int bindingVersion = 1,
  int updatedAtEpochMs = _baseMs,
}) => GatewayTurnJournalBinding(
  connectionId: connectionId,
  endpointDigest: endpointDigest,
  localSessionId: localSessionId,
  mobileSessionId: mobileSessionId,
  storedSessionId: storedSessionId,
  bindingVersion: bindingVersion,
  updatedAtEpochMs: updatedAtEpochMs,
);

GatewayTurnJournalEntry _entry({
  GatewayTurnJournalBinding? binding,
  String clientTurnId = _clientA,
  String? turnId,
  GatewayRecoveryTurnStatus? status,
  int lastSeq = 0,
  bool ackUncertain = true,
  int updatedAtEpochMs = _baseMs,
}) => GatewayTurnJournalEntry(
  bindingIdentity: (binding ?? _binding()).bindingIdentity,
  clientTurnId: clientTurnId,
  turnId: turnId,
  status: status,
  lastSeq: lastSeq,
  ackUncertain: ackUncertain,
  updatedAtEpochMs: updatedAtEpochMs,
);

String _uuidFor(int value) =>
    '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

String _repeat(String value, int count) => List.filled(count, value).join();

Future<void> _seedBinding(
  GatewayTurnJournal journal, [
  GatewayTurnJournalBinding? binding,
]) => journal.upsertBinding(binding ?? _binding());

void main() {
  group('durable turn journal v2', () {
    test('round-trips a durable binding and metadata-only turn', () async {
      final store = _MemoryJournalStore();
      final firstProcess = GatewayTurnJournal(store: store);
      final binding = _binding();
      await firstProcess.upsertBinding(binding);
      await firstProcess.upsert(
        _entry(
          binding: binding,
          turnId: 'turn-1',
          status: GatewayRecoveryTurnStatus.running,
          lastSeq: 3,
        ),
        now: DateTime.fromMillisecondsSinceEpoch(_baseMs, isUtc: true),
      );

      final secondProcess = GatewayTurnJournal(store: store);
      final restoredBinding = await secondProcess.loadBinding(
        connectionId: binding.connectionId,
        endpointDigest: binding.endpointDigest,
        localSessionId: binding.localSessionId,
      );
      expect(restoredBinding?.mobileSessionId, _mobileA);
      expect(restoredBinding?.storedSessionId, 'stored-session-a');
      final restored = await secondProcess.loadForBinding(restoredBinding!);
      expect(restored, hasLength(1));
      expect(restored.single.clientTurnId, _clientA);
      expect(restored.single.turnId, 'turn-1');
      expect(restored.single.lastSeq, 3);

      final encoded = store.value!;
      expect(encoded, contains(GatewayTurnJournal.schema));
      for (final forbidden in <String>[
        'runtime_session_id',
        'prompt',
        'credential',
        'token',
        'password',
        'attachment_path',
        'attachment_bytes',
        'ref_text',
        'assistant_text',
        'tool_result',
        'reasoning',
        'sudo',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
    });

    test(
      'retains the session binding after its terminal turn expires',
      () async {
        final store = _MemoryJournalStore();
        final journal = GatewayTurnJournal(store: store);
        final now = DateTime.utc(2026, 8, 10, 12);
        final binding = _binding(
          updatedAtEpochMs: now
              .subtract(const Duration(days: 30))
              .millisecondsSinceEpoch,
        );
        await journal.upsertBinding(binding);
        await journal.upsert(
          _entry(
            binding: binding,
            turnId: 'terminal-old',
            status: GatewayRecoveryTurnStatus.completed,
            ackUncertain: false,
            updatedAtEpochMs: now
                .subtract(const Duration(hours: 25))
                .millisecondsSinceEpoch,
          ),
          now: now.subtract(const Duration(hours: 25)),
        );

        final compacted = await journal.compact(now: now);
        expect(compacted.entries, isEmpty);
        expect(compacted.bindings, hasLength(1));
        expect(compacted.bindings.single.mobileSessionId, _mobileA);
      },
    );

    test(
      'isolates bindings by connection, endpoint, and local session',
      () async {
        final journal = GatewayTurnJournal(store: _MemoryJournalStore());
        await _seedBinding(journal);

        expect(
          await journal.loadBinding(
            connectionId: 'connection-b',
            endpointDigest: _digestA,
            localSessionId: 'local-session-a',
          ),
          isNull,
        );
        expect(
          await journal.loadBinding(
            connectionId: 'connection-a',
            endpointDigest: _digestB,
            localSessionId: 'local-session-a',
          ),
          isNull,
        );
        expect(
          await journal.loadBinding(
            connectionId: 'connection-a',
            endpointDigest: _digestA,
            localSessionId: 'local-session-b',
          ),
          isNull,
        );
        expect(
          await journal.loadBinding(
            connectionId: 'connection-a',
            endpointDigest: _digestA,
            localSessionId: 'local-session-a',
          ),
          isNotNull,
        );
      },
    );

    test(
      'rejects binding mutation, version regression, and orphan turns',
      () async {
        final journal = GatewayTurnJournal(store: _MemoryJournalStore());
        await _seedBinding(journal);

        await expectLater(
          journal.upsertBinding(_binding(mobileSessionId: _mobileB)),
          throwsA(isA<GatewayTurnJournalException>()),
        );
        await journal.upsertBinding(_binding(bindingVersion: 2));
        await expectLater(
          journal.upsertBinding(_binding(bindingVersion: 1)),
          throwsA(isA<GatewayTurnJournalException>()),
        );
        await expectLater(
          journal.upsertBinding(
            _binding(bindingVersion: 2, updatedAtEpochMs: _baseMs - 1),
          ),
          throwsA(isA<GatewayTurnJournalException>()),
        );
        await expectLater(
          journal.upsert(
            _entry(binding: _binding(localSessionId: 'missing-binding')),
          ),
          throwsA(isA<GatewayTurnJournalException>()),
        );
      },
    );

    test('rejects stale or nonmonotonic turn entry replacement', () async {
      final store = _MemoryJournalStore();
      final journal = GatewayTurnJournal(store: store);
      await _seedBinding(journal);
      await journal.upsert(
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.running,
          lastSeq: 4,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 10,
        ),
      );

      for (final invalid in <GatewayTurnJournalEntry>[
        _entry(
          turnId: 'turn-mutated',
          status: GatewayRecoveryTurnStatus.running,
          lastSeq: 4,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 11,
        ),
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.running,
          lastSeq: 3,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 11,
        ),
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.accepted,
          lastSeq: 4,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 11,
        ),
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.running,
          lastSeq: 4,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 9,
        ),
      ]) {
        final before = store.value;
        await expectLater(
          journal.upsert(invalid),
          throwsA(isA<GatewayTurnJournalException>()),
        );
        expect(store.value, before);
      }

      await journal.upsert(
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.completed,
          lastSeq: 5,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 12,
        ),
        now: DateTime.fromMillisecondsSinceEpoch(_baseMs + 12, isUtc: true),
      );
      final terminal = store.value;
      for (final invalid in <GatewayTurnJournalEntry>[
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.running,
          lastSeq: 5,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 13,
        ),
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.completed,
          lastSeq: 6,
          ackUncertain: false,
          updatedAtEpochMs: _baseMs + 13,
        ),
        _entry(
          turnId: 'turn-authoritative',
          status: GatewayRecoveryTurnStatus.completed,
          lastSeq: 5,
          ackUncertain: true,
          updatedAtEpochMs: _baseMs + 13,
        ),
      ]) {
        await expectLater(
          journal.upsert(invalid),
          throwsA(isA<GatewayTurnJournalException>()),
        );
        expect(store.value, terminal);
      }
    });

    test(
      'fails closed on unavailable, malformed, and orphaned storage',
      () async {
        final unavailable = _MemoryJournalStore()..unavailable = true;
        await expectLater(
          GatewayTurnJournal(store: unavailable).loadSnapshot(),
          throwsA(isA<GatewayTurnJournalException>()),
        );

        final corrupt = _MemoryJournalStore()..value = '{not-json';
        await expectLater(
          GatewayTurnJournal(store: corrupt).loadSnapshot(),
          throwsA(isA<GatewayTurnJournalException>()),
        );

        final binding = _binding();
        final unknownField = _MemoryJournalStore()
          ..value = jsonEncode(<String, Object>{
            'schema': GatewayTurnJournal.schema,
            'bindings': <Object>[binding.toJson()],
            'entries': <Object>[
              <String, Object?>{
                ..._entry(binding: binding).toJson(),
                'prompt': 'must fail closed',
              },
            ],
          });
        await expectLater(
          GatewayTurnJournal(store: unknownField).loadSnapshot(),
          throwsA(isA<GatewayTurnJournalException>()),
        );

        final orphan = _MemoryJournalStore()
          ..value = jsonEncode(<String, Object>{
            'schema': GatewayTurnJournal.schema,
            'bindings': const <Object>[],
            'entries': <Object>[_entry().toJson()],
          });
        await expectLater(
          GatewayTurnJournal(store: orphan).loadSnapshot(),
          throwsA(isA<GatewayTurnJournalException>()),
        );
      },
    );

    test('purges legacy v1 without reading or migrating it', () async {
      final legacyPayload = jsonEncode(<String, Object>{
        'schema': 'hermes.android.turn-journal.v1',
        'runtime_session_id': 'runtime-must-never-migrate',
        'entries': const <Object>[],
      });
      final store = _MemoryJournalStore()..legacyValue = legacyPayload;
      final journal = GatewayTurnJournal(store: store);

      await expectLater(
        journal.loadSnapshot(),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.legacyValue, isNull);
      expect(store.value, isNull);
      expect((await journal.loadSnapshot()).bindings, isEmpty);

      final blocked = _MemoryJournalStore()
        ..legacyValue = legacyPayload
        ..failLegacyDelete = true;
      await expectLater(
        GatewayTurnJournal(store: blocked).loadSnapshot(),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(blocked.legacyValue, legacyPayload);
      expect(blocked.value, isNull);
    });

    test('measures persisted capacity in UTF-8 bytes', () async {
      final bindings = <Object>[
        for (var index = 1; index <= GatewayTurnJournal.maxBindings; index += 1)
          _binding(
            connectionId: '${_repeat('😀', 100)}-$index',
            localSessionId: '${_repeat('界', 150)}-$index',
            mobileSessionId: _uuidFor(index),
            storedSessionId: 'stored-$index',
          ).toJson(),
      ];
      final encoded = jsonEncode(<String, Object>{
        'schema': GatewayTurnJournal.schema,
        'bindings': bindings,
        'entries': const <Object>[],
      });
      expect(encoded.length, lessThan(GatewayTurnJournal.maxEncodedBytes));
      expect(
        utf8.encode(encoded).length,
        greaterThan(GatewayTurnJournal.maxEncodedBytes),
      );
      final store = _MemoryJournalStore()..value = encoded;
      await expectLater(
        GatewayTurnJournal(store: store).loadSnapshot(),
        throwsA(isA<GatewayTurnJournalException>()),
      );
    });

    test('rolls back a failed write or readback verification', () async {
      final store = _MemoryJournalStore();
      final journal = GatewayTurnJournal(store: store);
      await _seedBinding(journal);
      final original = store.value;

      store.failNextWrite = true;
      await expectLater(
        journal.upsertBinding(
          _binding(localSessionId: 'local-b', mobileSessionId: _mobileB),
        ),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.value, original);

      store.corruptNextReadback = true;
      await expectLater(
        journal.upsert(
          _entry(clientTurnId: _uuidFor(2), updatedAtEpochMs: _baseMs + 1),
        ),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.value, original);
    });

    test('serializes writes and refuses a sixty-fifth active turn', () async {
      final store = _MemoryJournalStore()
        ..delay = const Duration(milliseconds: 1);
      final journal = GatewayTurnJournal(store: store);
      await _seedBinding(journal);
      final now = DateTime.fromMillisecondsSinceEpoch(
        _baseMs + 1000,
        isUtc: true,
      );
      await Future.wait(<Future<void>>[
        for (var index = 1; index <= GatewayTurnJournal.maxEntries; index += 1)
          journal.upsert(
            _entry(
              clientTurnId: _uuidFor(index),
              updatedAtEpochMs: _baseMs + index,
            ),
            now: now,
          ),
      ]);

      final entries = await journal.loadAll();
      expect(entries, hasLength(GatewayTurnJournal.maxEntries));
      final before = store.value;
      await expectLater(
        journal.upsert(
          _entry(
            clientTurnId: _uuidFor(GatewayTurnJournal.maxEntries + 1),
            updatedAtEpochMs: _baseMs + GatewayTurnJournal.maxEntries + 1,
          ),
          now: now,
        ),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.value, before);
      expect(await journal.loadAll(), hasLength(GatewayTurnJournal.maxEntries));
    });

    test(
      'evicts only safe terminal turns and retains uncertain history',
      () async {
        final store = _MemoryJournalStore();
        final journal = GatewayTurnJournal(store: store);
        await _seedBinding(journal);
        final now = DateTime.fromMillisecondsSinceEpoch(
          _baseMs + 10000,
          isUtc: true,
        );
        for (var index = 1; index < GatewayTurnJournal.maxEntries; index += 1) {
          await journal.upsert(
            _entry(
              clientTurnId: _uuidFor(index),
              updatedAtEpochMs: _baseMs + index,
            ),
            now: now,
          );
        }
        await journal.upsert(
          _entry(
            clientTurnId: _uuidFor(64),
            turnId: 'terminal-safe',
            status: GatewayRecoveryTurnStatus.completed,
            ackUncertain: false,
            updatedAtEpochMs: _baseMs + 64,
          ),
          now: now,
        );
        await journal.upsert(
          _entry(clientTurnId: _uuidFor(65), updatedAtEpochMs: _baseMs + 65),
          now: now,
        );
        final entries = await journal.loadAll();
        expect(entries, hasLength(GatewayTurnJournal.maxEntries));
        expect(
          entries.map((entry) => entry.clientTurnId),
          isNot(contains(_uuidFor(64))),
        );

        final oldUncertain = _entry(
          clientTurnId: _uuidFor(1),
          turnId: 'still-uncertain',
          status: GatewayRecoveryTurnStatus.failed,
          ackUncertain: true,
          updatedAtEpochMs: _baseMs + 1,
        );
        final isolated = GatewayTurnJournal(store: _MemoryJournalStore());
        await _seedBinding(isolated);
        await isolated.upsert(oldUncertain, now: now);
        expect((await isolated.compact(now: now)).entries, hasLength(1));
      },
    );

    test('never evicts a binding referenced by an active turn', () async {
      final store = _MemoryJournalStore();
      final journal = GatewayTurnJournal(store: store);
      for (var index = 1; index <= GatewayTurnJournal.maxBindings; index += 1) {
        final binding = _binding(
          connectionId: 'connection-$index',
          localSessionId: 'local-$index',
          mobileSessionId: _uuidFor(index),
          storedSessionId: 'stored-$index',
          updatedAtEpochMs: _baseMs + index,
        );
        await journal.upsertBinding(binding);
        await journal.upsert(
          _entry(
            binding: binding,
            clientTurnId: _uuidFor(index),
            updatedAtEpochMs: _baseMs + index,
          ),
        );
      }
      final before = store.value;
      await expectLater(
        journal.upsertBinding(
          _binding(
            connectionId: 'connection-overflow',
            localSessionId: 'local-overflow',
            mobileSessionId: _uuidFor(65),
            storedSessionId: 'stored-overflow',
            updatedAtEpochMs: _baseMs + 65,
          ),
        ),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.value, before);
      expect(
        (await journal.loadSnapshot()).bindings,
        hasLength(GatewayTurnJournal.maxBindings),
      );
    });

    test('rejects noncanonical identities before touching storage', () {
      expect(
        () => _binding(endpointDigest: _digestA.toUpperCase()),
        throwsArgumentError,
      );
      expect(
        () => _binding(mobileSessionId: 'not-a-uuid'),
        throwsArgumentError,
      );
      expect(() => _entry(clientTurnId: 'not-a-uuid'), throwsArgumentError);
    });
  });
}

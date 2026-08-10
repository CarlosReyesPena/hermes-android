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

class _MemoryJournalStore implements GatewayTurnJournalStore {
  String? value;
  bool unavailable = false;
  bool failNextWrite = false;
  bool corruptNextReadback = false;
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
}

GatewayTurnJournalBinding _bindingA() => GatewayTurnJournalBinding(
  connectionId: 'connection-a',
  endpointDigest: _digestA,
  mobileSessionId: _mobileA,
);

GatewayTurnJournalEntry _entry({
  String connectionId = 'connection-a',
  String endpointDigest = _digestA,
  String mobileSessionId = _mobileA,
  String clientTurnId = _clientA,
  String runtimeSessionId = 'runtime-1',
  String storedSessionId = 'stored-1',
  String? turnId,
  GatewayTurnStatus? status,
  int lastSeq = 0,
  bool ackUncertain = true,
  int updatedAtEpochMs = 1720000000000,
}) => GatewayTurnJournalEntry(
  connectionId: connectionId,
  endpointDigest: endpointDigest,
  mobileSessionId: mobileSessionId,
  runtimeSessionId: runtimeSessionId,
  storedSessionId: storedSessionId,
  bindingVersion: 1,
  clientTurnId: clientTurnId,
  turnId: turnId,
  status: status,
  lastSeq: lastSeq,
  ackUncertain: ackUncertain,
  updatedAtEpochMs: updatedAtEpochMs,
);

String _uuidFor(int value) =>
    '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

void main() {
  group('durable turn journal', () {
    test(
      'round-trips across coordinator reconstruction with metadata only',
      () async {
        final store = _MemoryJournalStore();
        final firstProcess = GatewayTurnJournal(store: store);
        await firstProcess.upsert(
          _entry(
            turnId: 'turn-1',
            status: GatewayTurnStatus.running,
            lastSeq: 3,
          ),
          now: DateTime.fromMillisecondsSinceEpoch(1720000000000, isUtc: true),
        );

        final secondProcess = GatewayTurnJournal(store: store);
        final restored = await secondProcess.loadForBinding(_bindingA());
        expect(restored, hasLength(1));
        expect(restored.single.clientTurnId, _clientA);
        expect(restored.single.turnId, 'turn-1');
        expect(restored.single.lastSeq, 3);
        expect(restored.single.ackUncertain, isTrue);

        final encoded = store.value!;
        expect(encoded, contains(GatewayTurnJournal.schema));
        for (final forbidden in <String>[
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
      },
    );

    test(
      'isolates connection, endpoint, and mobile-session bindings',
      () async {
        final store = _MemoryJournalStore();
        final journal = GatewayTurnJournal(store: store);
        await journal.upsert(
          _entry(),
          now: DateTime.fromMillisecondsSinceEpoch(1720000000000, isUtc: true),
        );

        final wrongEndpoint = GatewayTurnJournalBinding(
          connectionId: 'connection-a',
          endpointDigest: _digestB,
          mobileSessionId: _mobileA,
        );
        final wrongMobile = GatewayTurnJournalBinding(
          connectionId: 'connection-a',
          endpointDigest: _digestA,
          mobileSessionId: _mobileB,
        );
        final wrongConnection = GatewayTurnJournalBinding(
          connectionId: 'connection-b',
          endpointDigest: _digestA,
          mobileSessionId: _mobileA,
        );

        expect(await journal.loadForBinding(wrongEndpoint), isEmpty);
        expect(await journal.loadForBinding(wrongMobile), isEmpty);
        expect(await journal.loadForBinding(wrongConnection), isEmpty);
        expect(await journal.loadForBinding(_bindingA()), hasLength(1));
      },
    );

    test('fails closed on unavailable and malformed storage', () async {
      final unavailable = _MemoryJournalStore()..unavailable = true;
      await expectLater(
        GatewayTurnJournal(store: unavailable).loadAll(),
        throwsA(isA<GatewayTurnJournalException>()),
      );

      final corrupt = _MemoryJournalStore()..value = '{not-json';
      await expectLater(
        GatewayTurnJournal(store: corrupt).loadAll(),
        throwsA(isA<GatewayTurnJournalException>()),
      );

      final unknownField = _MemoryJournalStore();
      unknownField.value = jsonEncode(<String, Object>{
        'schema': GatewayTurnJournal.schema,
        'entries': <Object>[
          <String, Object?>{..._entry().toJson(), 'prompt': 'must fail closed'},
        ],
      });
      await expectLater(
        GatewayTurnJournal(store: unknownField).loadAll(),
        throwsA(isA<GatewayTurnJournalException>()),
      );
    });

    test('rolls back a failed write or failed readback verification', () async {
      final store = _MemoryJournalStore();
      final journal = GatewayTurnJournal(store: store);
      final now = DateTime.fromMillisecondsSinceEpoch(
        1720000000000,
        isUtc: true,
      );
      await journal.upsert(_entry(), now: now);
      final original = store.value;

      store.failNextWrite = true;
      await expectLater(
        journal.upsert(
          _entry(clientTurnId: _uuidFor(2), updatedAtEpochMs: 1720000000001),
          now: now,
        ),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.value, original);

      store.corruptNextReadback = true;
      await expectLater(
        journal.upsert(
          _entry(clientTurnId: _uuidFor(3), updatedAtEpochMs: 1720000000002),
          now: now,
        ),
        throwsA(isA<GatewayTurnJournalException>()),
      );
      expect(store.value, original);
    });

    test(
      'serializes concurrent writes and preserves every distinct turn',
      () async {
        final store = _MemoryJournalStore()
          ..delay = const Duration(milliseconds: 1);
        final journal = GatewayTurnJournal(store: store);
        final now = DateTime.fromMillisecondsSinceEpoch(
          1720000001000,
          isUtc: true,
        );
        await Future.wait(<Future<void>>[
          for (var index = 1; index <= 12; index += 1)
            journal.upsert(
              _entry(
                clientTurnId: _uuidFor(index),
                updatedAtEpochMs: 1720000000000 + index,
              ),
              now: now,
            ),
        ]);

        expect(await journal.loadAll(), hasLength(12));
      },
    );

    test(
      'uses bounded active and terminal retention with max-count compaction',
      () async {
        final store = _MemoryJournalStore();
        final journal = GatewayTurnJournal(store: store);
        final now = DateTime.utc(2026, 8, 10, 12);
        final activeOld = now.subtract(const Duration(days: 8));
        final terminalOld = now.subtract(const Duration(hours: 25));
        final terminalFresh = now.subtract(const Duration(hours: 23));

        await journal.upsert(
          _entry(
            clientTurnId: _uuidFor(1),
            updatedAtEpochMs: activeOld.millisecondsSinceEpoch,
          ),
          now: activeOld,
        );
        await journal.upsert(
          _entry(
            clientTurnId: _uuidFor(2),
            turnId: 'turn-old',
            status: GatewayTurnStatus.completed,
            updatedAtEpochMs: terminalOld.millisecondsSinceEpoch,
          ),
          now: terminalOld,
        );
        await journal.upsert(
          _entry(
            clientTurnId: _uuidFor(3),
            turnId: 'turn-fresh',
            status: GatewayTurnStatus.completed,
            updatedAtEpochMs: terminalFresh.millisecondsSinceEpoch,
          ),
          now: terminalFresh,
        );
        final retained = await journal.compact(now: now);
        expect(retained.map((entry) => entry.clientTurnId), <String>[
          _uuidFor(3),
        ]);

        for (var index = 10; index < 80; index += 1) {
          await journal.upsert(
            _entry(
              clientTurnId: _uuidFor(index),
              updatedAtEpochMs: now.millisecondsSinceEpoch + index,
            ),
            now: now,
          );
        }
        final bounded = await journal.loadAll();
        expect(bounded, hasLength(GatewayTurnJournal.maxEntries));
        expect(bounded.first.clientTurnId, _uuidFor(79));
        expect(bounded.last.clientTurnId, _uuidFor(16));
      },
    );

    test('rejects noncanonical identities before touching storage', () {
      expect(
        () => GatewayTurnJournalBinding(
          connectionId: 'connection-a',
          endpointDigest: _digestA.toUpperCase(),
          mobileSessionId: _mobileA,
        ),
        throwsArgumentError,
      );
      expect(() => _entry(clientTurnId: 'not-a-uuid'), throwsArgumentError);
    });
  });
}

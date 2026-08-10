import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/gateway_turn_contract.dart';

abstract interface class GatewayTurnJournalStore {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> delete();

  Future<String?> readLegacy();

  Future<void> deleteLegacy();
}

/// Android Keystore-backed production store for the single bounded journal.
class FlutterSecureGatewayTurnJournalStore implements GatewayTurnJournalStore {
  static const _key = 'gateway_turn_journal_v2';
  static const _legacyKey = 'gateway_turn_journal_v1';
  static const AndroidOptions _androidOptions = AndroidOptions(
    resetOnError: false,
    migrateWithBackup: true,
    storageNamespace: 'hermes_android_turn_recovery',
  );

  final FlutterSecureStorage _storage;

  FlutterSecureGatewayTurnJournalStore({FlutterSecureStorage? storage})
    : _storage = storage ?? FlutterSecureStorage(aOptions: _androidOptions);

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);

  @override
  Future<String?> readLegacy() => _storage.read(key: _legacyKey);

  @override
  Future<void> deleteLegacy() => _storage.delete(key: _legacyKey);
}

class GatewayTurnJournalException implements Exception {
  const GatewayTurnJournalException();

  @override
  String toString() => 'Turn recovery journal is unavailable.';
}

/// Durable server-owned session binding for one local chat.
///
/// Runtime session IDs are deliberately absent. A runtime ID is valid only for
/// the physical transport on which a fresh `session.open` returned it.
class GatewayTurnJournalBinding {
  static const allowedJsonKeys = <String>{
    'connection_id',
    'endpoint_digest',
    'local_session_id',
    'mobile_session_id',
    'stored_session_id',
    'binding_version',
    'updated_at_epoch_ms',
  };

  final String connectionId;
  final String endpointDigest;
  final String localSessionId;
  final String mobileSessionId;
  final String storedSessionId;
  final int bindingVersion;
  final int updatedAtEpochMs;

  factory GatewayTurnJournalBinding({
    required String connectionId,
    required String endpointDigest,
    required String localSessionId,
    required String mobileSessionId,
    required String storedSessionId,
    required int bindingVersion,
    required int updatedAtEpochMs,
  }) {
    if (!_boundedIdentity(connectionId) ||
        !_lowerHexDigest(endpointDigest) ||
        !_boundedIdentity(localSessionId) ||
        !_canonicalUuid(mobileSessionId) ||
        !_boundedIdentity(storedSessionId) ||
        bindingVersion <= 0 ||
        updatedAtEpochMs <= 0) {
      throw ArgumentError('Invalid recovery journal binding.');
    }
    return GatewayTurnJournalBinding._(
      connectionId: connectionId,
      endpointDigest: endpointDigest,
      localSessionId: localSessionId,
      mobileSessionId: mobileSessionId,
      storedSessionId: storedSessionId,
      bindingVersion: bindingVersion,
      updatedAtEpochMs: updatedAtEpochMs,
    );
  }

  const GatewayTurnJournalBinding._({
    required this.connectionId,
    required this.endpointDigest,
    required this.localSessionId,
    required this.mobileSessionId,
    required this.storedSessionId,
    required this.bindingVersion,
    required this.updatedAtEpochMs,
  });

  String get bindingIdentity =>
      jsonEncode(<String>[connectionId, endpointDigest, localSessionId]);

  Map<String, Object> toJson() => <String, Object>{
    'connection_id': connectionId,
    'endpoint_digest': endpointDigest,
    'local_session_id': localSessionId,
    'mobile_session_id': mobileSessionId,
    'stored_session_id': storedSessionId,
    'binding_version': bindingVersion,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  static GatewayTurnJournalBinding _fromJson(Map<String, dynamic> value) {
    if (value.length != allowedJsonKeys.length ||
        value.keys.any((key) => !allowedJsonKeys.contains(key)) ||
        value['connection_id'] is! String ||
        value['endpoint_digest'] is! String ||
        value['local_session_id'] is! String ||
        value['mobile_session_id'] is! String ||
        value['stored_session_id'] is! String ||
        value['binding_version'] is! int ||
        value['updated_at_epoch_ms'] is! int) {
      throw const GatewayTurnJournalException();
    }
    try {
      return GatewayTurnJournalBinding(
        connectionId: value['connection_id'] as String,
        endpointDigest: value['endpoint_digest'] as String,
        localSessionId: value['local_session_id'] as String,
        mobileSessionId: value['mobile_session_id'] as String,
        storedSessionId: value['stored_session_id'] as String,
        bindingVersion: value['binding_version'] as int,
        updatedAtEpochMs: value['updated_at_epoch_ms'] as int,
      );
    } on ArgumentError {
      throw const GatewayTurnJournalException();
    }
  }
}

/// Metadata-only write-ahead record for one client intent.
///
/// It references a separately durable binding. Prompt text, attachment
/// manifests, outputs, credentials, endpoints, and runtime session IDs are not
/// permitted in this schema.
class GatewayTurnJournalEntry {
  static const allowedJsonKeys = <String>{
    'binding_id',
    'client_turn_id',
    'turn_id',
    'status',
    'last_seq',
    'ack_uncertain',
    'updated_at_epoch_ms',
  };

  final String bindingIdentity;
  final String clientTurnId;
  final String? turnId;
  final GatewayRecoveryTurnStatus? status;
  final int lastSeq;
  final bool ackUncertain;
  final int updatedAtEpochMs;

  factory GatewayTurnJournalEntry({
    required String bindingIdentity,
    required String clientTurnId,
    String? turnId,
    GatewayRecoveryTurnStatus? status,
    required int lastSeq,
    required bool ackUncertain,
    required int updatedAtEpochMs,
  }) {
    if (!_boundedReference(bindingIdentity) ||
        !_canonicalUuid(clientTurnId) ||
        turnId != null && !_boundedIdentity(turnId) ||
        lastSeq < 0 ||
        updatedAtEpochMs <= 0) {
      throw ArgumentError('Invalid recovery journal entry.');
    }
    return GatewayTurnJournalEntry._(
      bindingIdentity: bindingIdentity,
      clientTurnId: clientTurnId,
      turnId: turnId,
      status: status,
      lastSeq: lastSeq,
      ackUncertain: ackUncertain,
      updatedAtEpochMs: updatedAtEpochMs,
    );
  }

  const GatewayTurnJournalEntry._({
    required this.bindingIdentity,
    required this.clientTurnId,
    required this.turnId,
    required this.status,
    required this.lastSeq,
    required this.ackUncertain,
    required this.updatedAtEpochMs,
  });

  bool get isTerminal => status?.isTerminal == true;

  String get entryIdentity => '$bindingIdentity:$clientTurnId';

  GatewayTurnJournalEntry copyWith({
    String? turnId,
    GatewayRecoveryTurnStatus? status,
    int? lastSeq,
    bool? ackUncertain,
    int? updatedAtEpochMs,
  }) {
    return GatewayTurnJournalEntry(
      bindingIdentity: bindingIdentity,
      clientTurnId: clientTurnId,
      turnId: turnId ?? this.turnId,
      status: status ?? this.status,
      lastSeq: lastSeq ?? this.lastSeq,
      ackUncertain: ackUncertain ?? this.ackUncertain,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'binding_id': bindingIdentity,
    'client_turn_id': clientTurnId,
    if (turnId != null) 'turn_id': turnId,
    if (status != null) 'status': status!.wireValue,
    'last_seq': lastSeq,
    'ack_uncertain': ackUncertain,
    'updated_at_epoch_ms': updatedAtEpochMs,
  };

  static GatewayTurnJournalEntry _fromJson(Map<String, dynamic> value) {
    if (value.keys.any((key) => !allowedJsonKeys.contains(key))) {
      throw const GatewayTurnJournalException();
    }
    final statusRaw = value['status'];
    final status = statusRaw == null
        ? null
        : GatewayRecoveryTurnStatus.fromWire(statusRaw);
    if (statusRaw != null && status == null ||
        value['binding_id'] is! String ||
        value['client_turn_id'] is! String ||
        value['turn_id'] != null && value['turn_id'] is! String ||
        value['last_seq'] is! int ||
        value['ack_uncertain'] is! bool ||
        value['updated_at_epoch_ms'] is! int) {
      throw const GatewayTurnJournalException();
    }
    try {
      return GatewayTurnJournalEntry(
        bindingIdentity: value['binding_id'] as String,
        clientTurnId: value['client_turn_id'] as String,
        turnId: value['turn_id'] as String?,
        status: status,
        lastSeq: value['last_seq'] as int,
        ackUncertain: value['ack_uncertain'] as bool,
        updatedAtEpochMs: value['updated_at_epoch_ms'] as int,
      );
    } on ArgumentError {
      throw const GatewayTurnJournalException();
    }
  }
}

class GatewayTurnJournalSnapshot {
  final List<GatewayTurnJournalBinding> bindings;
  final List<GatewayTurnJournalEntry> entries;

  const GatewayTurnJournalSnapshot({
    required this.bindings,
    required this.entries,
  });
}

class GatewayTurnJournal {
  static const schema = 'hermes.android.turn-journal.v2';
  static const maxBindings = 64;
  static const maxEntries = 64;
  static const maxEncodedBytes = 64 * 1024;
  static const activeRetention = Duration(days: 7);
  static const terminalRetention = Duration(hours: 24);

  final GatewayTurnJournalStore _store;
  Future<void> _tail = Future<void>.value();

  GatewayTurnJournal({GatewayTurnJournalStore? store})
    : _store = store ?? FlutterSecureGatewayTurnJournalStore();

  Future<GatewayTurnJournalSnapshot> loadSnapshot() {
    return _serialized(() async => _freeze(await _readData()));
  }

  Future<List<GatewayTurnJournalEntry>> loadAll() {
    return _serialized(() async {
      final data = await _readData();
      return List<GatewayTurnJournalEntry>.unmodifiable(data.entries);
    });
  }

  Future<GatewayTurnJournalBinding?> loadBinding({
    required String connectionId,
    required String endpointDigest,
    required String localSessionId,
  }) {
    return _serialized(() async {
      final probe = GatewayTurnJournalBinding(
        connectionId: connectionId,
        endpointDigest: endpointDigest,
        localSessionId: localSessionId,
        mobileSessionId: '00000000-0000-4000-8000-000000000001',
        storedSessionId: 'probe',
        bindingVersion: 1,
        updatedAtEpochMs: 1,
      );
      final data = await _readData();
      return data.bindings.cast<GatewayTurnJournalBinding?>().firstWhere(
        (binding) => binding!.bindingIdentity == probe.bindingIdentity,
        orElse: () => null,
      );
    });
  }

  Future<List<GatewayTurnJournalEntry>> loadForBinding(
    GatewayTurnJournalBinding binding,
  ) {
    return _serialized(() async {
      final data = await _readData();
      return List<GatewayTurnJournalEntry>.unmodifiable(
        data.entries.where(
          (entry) => entry.bindingIdentity == binding.bindingIdentity,
        ),
      );
    });
  }

  Future<void> upsertBinding(GatewayTurnJournalBinding binding) {
    return _serialized(() async {
      final data = await _readData();
      final index = data.bindings.indexWhere(
        (candidate) => candidate.bindingIdentity == binding.bindingIdentity,
      );
      if (index >= 0) {
        final previous = data.bindings[index];
        if (previous.mobileSessionId != binding.mobileSessionId ||
            previous.storedSessionId != binding.storedSessionId ||
            binding.bindingVersion < previous.bindingVersion ||
            binding.updatedAtEpochMs < previous.updatedAtEpochMs) {
          throw const GatewayTurnJournalException();
        }
        data.bindings[index] = binding;
      } else {
        data.bindings.add(binding);
      }
      await _writeData(
        _compact(
          data,
          DateTime.now().toUtc(),
          protectedBindingIdentity: binding.bindingIdentity,
        ),
      );
    });
  }

  Future<void> upsert(GatewayTurnJournalEntry entry, {DateTime? now}) {
    return _serialized(() async {
      final data = await _readData();
      if (!data.bindings.any(
        (binding) => binding.bindingIdentity == entry.bindingIdentity,
      )) {
        throw const GatewayTurnJournalException();
      }
      final index = data.entries.indexWhere(
        (candidate) => candidate.entryIdentity == entry.entryIdentity,
      );
      if (index >= 0) {
        _validateEntryUpdate(data.entries[index], entry);
        data.entries[index] = entry;
      } else {
        data.entries.add(entry);
      }
      await _writeData(_compact(data, now ?? DateTime.now().toUtc()));
    });
  }

  Future<void> remove(String entryIdentity) {
    return _serialized(() async {
      final data = await _readData();
      data.entries.removeWhere((entry) => entry.entryIdentity == entryIdentity);
      await _writeData(data);
    });
  }

  Future<GatewayTurnJournalSnapshot> compact({DateTime? now}) {
    return _serialized(() async {
      final compacted = _compact(
        await _readData(),
        now ?? DateTime.now().toUtc(),
      );
      await _writeData(compacted);
      return _freeze(compacted);
    });
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }

  Future<_JournalData> _readData() async {
    try {
      await _rejectLegacyState();
      final encoded = await _store.read();
      if (encoded == null) return _JournalData.empty();
      if (utf8.encode(encoded).length > maxEncodedBytes) {
        throw const GatewayTurnJournalException();
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const GatewayTurnJournalException();
      final root = Map<String, dynamic>.from(decoded);
      if (root.length != 3 ||
          root['schema'] != schema ||
          root['bindings'] is! List ||
          root['entries'] is! List) {
        throw const GatewayTurnJournalException();
      }
      final rawBindings = root['bindings'] as List;
      final rawEntries = root['entries'] as List;
      if (rawBindings.length > maxBindings || rawEntries.length > maxEntries) {
        throw const GatewayTurnJournalException();
      }
      final bindings = <GatewayTurnJournalBinding>[];
      final bindingIds = <String>{};
      for (final rawBinding in rawBindings) {
        if (rawBinding is! Map) throw const GatewayTurnJournalException();
        final binding = GatewayTurnJournalBinding._fromJson(
          Map<String, dynamic>.from(rawBinding),
        );
        if (!bindingIds.add(binding.bindingIdentity)) {
          throw const GatewayTurnJournalException();
        }
        bindings.add(binding);
      }
      final entries = <GatewayTurnJournalEntry>[];
      final entryIds = <String>{};
      for (final rawEntry in rawEntries) {
        if (rawEntry is! Map) throw const GatewayTurnJournalException();
        final entry = GatewayTurnJournalEntry._fromJson(
          Map<String, dynamic>.from(rawEntry),
        );
        if (!bindingIds.contains(entry.bindingIdentity) ||
            !entryIds.add(entry.entryIdentity)) {
          throw const GatewayTurnJournalException();
        }
        entries.add(entry);
      }
      return _JournalData(bindings: bindings, entries: entries);
    } on GatewayTurnJournalException {
      rethrow;
    } catch (_) {
      throw const GatewayTurnJournalException();
    }
  }

  _JournalData _compact(
    _JournalData data,
    DateTime now, {
    String? protectedBindingIdentity,
  }) {
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    data.entries.removeWhere((entry) {
      final ageMs = nowMs - entry.updatedAtEpochMs;
      if (ageMs < 0) return false;
      return entry.isTerminal &&
          !entry.ackUncertain &&
          ageMs > terminalRetention.inMilliseconds;
    });
    data.entries.sort(
      (left, right) => right.updatedAtEpochMs.compareTo(left.updatedAtEpochMs),
    );
    if (data.entries.length > maxEntries) {
      final removable =
          data.entries
              .where((entry) => entry.isTerminal && !entry.ackUncertain)
              .toList()
            ..sort(
              (left, right) =>
                  left.updatedAtEpochMs.compareTo(right.updatedAtEpochMs),
            );
      final removeCount = data.entries.length - maxEntries;
      if (removable.length < removeCount) {
        throw const GatewayTurnJournalException();
      }
      final removeIds = removable
          .take(removeCount)
          .map((entry) => entry.entryIdentity)
          .toSet();
      data.entries.removeWhere(
        (entry) => removeIds.contains(entry.entryIdentity),
      );
    }

    // Session bindings have independent retention. They survive removal of the
    // last turn and are bounded only by recency/count. A referenced binding is
    // recovery authority and is never evicted silently.
    data.bindings.sort(
      (left, right) => right.updatedAtEpochMs.compareTo(left.updatedAtEpochMs),
    );
    if (data.bindings.length > maxBindings) {
      final referencedIds = data.entries
          .map((entry) => entry.bindingIdentity)
          .toSet();
      final removable =
          data.bindings
              .where(
                (binding) =>
                    !referencedIds.contains(binding.bindingIdentity) &&
                    binding.bindingIdentity != protectedBindingIdentity,
              )
              .toList()
            ..sort(
              (left, right) =>
                  left.updatedAtEpochMs.compareTo(right.updatedAtEpochMs),
            );
      final removeCount = data.bindings.length - maxBindings;
      if (removable.length < removeCount) {
        throw const GatewayTurnJournalException();
      }
      final removeIds = removable
          .take(removeCount)
          .map((binding) => binding.bindingIdentity)
          .toSet();
      data.bindings.removeWhere(
        (binding) => removeIds.contains(binding.bindingIdentity),
      );
    }
    return data;
  }

  Future<void> _writeData(_JournalData data) async {
    final encoded = data.bindings.isEmpty && data.entries.isEmpty
        ? null
        : jsonEncode(<String, Object>{
            'schema': schema,
            'bindings': data.bindings
                .map((binding) => binding.toJson())
                .toList(),
            'entries': data.entries.map((entry) => entry.toJson()).toList(),
          });
    if (encoded != null && utf8.encode(encoded).length > maxEncodedBytes) {
      throw const GatewayTurnJournalException();
    }

    String? previous;
    try {
      previous = await _store.read();
      if (encoded == null) {
        await _store.delete();
      } else {
        await _store.write(encoded);
      }
      final verified = await _store.read();
      if (verified != encoded) throw const GatewayTurnJournalException();
    } catch (_) {
      try {
        if (previous == null) {
          await _store.delete();
        } else {
          await _store.write(previous);
        }
      } catch (_) {
        // The caller still receives only the generic fail-closed exception.
      }
      throw const GatewayTurnJournalException();
    }
  }

  GatewayTurnJournalSnapshot _freeze(_JournalData data) {
    return GatewayTurnJournalSnapshot(
      bindings: List<GatewayTurnJournalBinding>.unmodifiable(data.bindings),
      entries: List<GatewayTurnJournalEntry>.unmodifiable(data.entries),
    );
  }

  Future<void> _rejectLegacyState() async {
    try {
      final legacy = await _store.readLegacy();
      if (legacy == null) return;
      await _store.deleteLegacy();
      if (await _store.readLegacy() != null) {
        throw const GatewayTurnJournalException();
      }
    } catch (_) {
      throw const GatewayTurnJournalException();
    }
    // The first encounter always stops. No v1 field, especially a runtime
    // session ID, is ever read or migrated into the v2 authority record.
    throw const GatewayTurnJournalException();
  }
}

class _JournalData {
  final List<GatewayTurnJournalBinding> bindings;
  final List<GatewayTurnJournalEntry> entries;

  _JournalData({required this.bindings, required this.entries});

  factory _JournalData.empty() => _JournalData(bindings: [], entries: []);
}

void _validateEntryUpdate(
  GatewayTurnJournalEntry previous,
  GatewayTurnJournalEntry next,
) {
  final previousTurnId = previous.turnId;
  if (previousTurnId != null && next.turnId != previousTurnId ||
      next.lastSeq < previous.lastSeq ||
      next.updatedAtEpochMs < previous.updatedAtEpochMs) {
    throw const GatewayTurnJournalException();
  }

  final previousStatus = previous.status;
  final nextStatus = next.status;
  if (previousStatus != null &&
      (nextStatus == null ||
          !_journalTransitionAllowed(previousStatus, nextStatus))) {
    throw const GatewayTurnJournalException();
  }
  if (previous.isTerminal &&
      (next.turnId != previous.turnId ||
          next.status != previous.status ||
          next.lastSeq != previous.lastSeq ||
          next.ackUncertain != previous.ackUncertain)) {
    throw const GatewayTurnJournalException();
  }
}

bool _journalTransitionAllowed(
  GatewayRecoveryTurnStatus from,
  GatewayRecoveryTurnStatus to,
) {
  if (from == to) return true;
  if (from.isTerminal) return false;
  if (to.isTerminal) return true;
  return switch (from) {
    GatewayRecoveryTurnStatus.accepted =>
      to == GatewayRecoveryTurnStatus.running,
    GatewayRecoveryTurnStatus.running =>
      to == GatewayRecoveryTurnStatus.waitingInput,
    GatewayRecoveryTurnStatus.waitingInput =>
      to == GatewayRecoveryTurnStatus.running,
    GatewayRecoveryTurnStatus.completed ||
    GatewayRecoveryTurnStatus.failed ||
    GatewayRecoveryTurnStatus.interrupted => false,
  };
}

bool _boundedIdentity(String value) {
  return value.isNotEmpty &&
      value.length <= 256 &&
      value.trim() == value &&
      !value.codeUnits.any((unit) => unit < 32);
}

bool _boundedReference(String value) {
  return value.isNotEmpty &&
      value.length <= 1024 &&
      value.trim() == value &&
      !value.codeUnits.any((unit) => unit < 32);
}

bool _lowerHexDigest(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _canonicalUuid(String value) {
  return value != '00000000-0000-0000-0000-000000000000' &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(value);
}

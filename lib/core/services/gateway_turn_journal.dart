import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/gateway_turn_contract.dart';

abstract interface class GatewayTurnJournalStore {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> delete();
}

/// Android Keystore-backed production store for the single bounded journal.
class FlutterSecureGatewayTurnJournalStore implements GatewayTurnJournalStore {
  static const _key = 'gateway_turn_journal_v1';
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
}

class GatewayTurnJournalException implements Exception {
  const GatewayTurnJournalException();

  @override
  String toString() => 'Turn recovery journal is unavailable.';
}

class GatewayTurnJournalBinding {
  final String connectionId;
  final String endpointDigest;
  final String mobileSessionId;

  factory GatewayTurnJournalBinding({
    required String connectionId,
    required String endpointDigest,
    required String mobileSessionId,
  }) {
    if (!_boundedIdentity(connectionId) ||
        !_lowerHexDigest(endpointDigest) ||
        !_canonicalUuid(mobileSessionId)) {
      throw ArgumentError('Invalid recovery journal binding.');
    }
    return GatewayTurnJournalBinding._(
      connectionId: connectionId,
      endpointDigest: endpointDigest,
      mobileSessionId: mobileSessionId,
    );
  }

  const GatewayTurnJournalBinding._({
    required this.connectionId,
    required this.endpointDigest,
    required this.mobileSessionId,
  });

  String get storageIdentity =>
      '$connectionId:$endpointDigest:$mobileSessionId';

  bool owns(GatewayTurnJournalEntry entry) {
    return entry.connectionId == connectionId &&
        entry.endpointDigest == endpointDigest &&
        entry.mobileSessionId == mobileSessionId;
  }
}

class GatewayTurnJournalEntry {
  static const allowedJsonKeys = <String>{
    'connection_id',
    'endpoint_digest',
    'mobile_session_id',
    'runtime_session_id',
    'stored_session_id',
    'binding_version',
    'client_turn_id',
    'turn_id',
    'status',
    'last_seq',
    'ack_uncertain',
    'updated_at_epoch_ms',
  };

  final String connectionId;
  final String endpointDigest;
  final String mobileSessionId;
  final String runtimeSessionId;
  final String storedSessionId;
  final int bindingVersion;
  final String clientTurnId;
  final String? turnId;
  final GatewayTurnStatus? status;
  final int lastSeq;
  final bool ackUncertain;
  final int updatedAtEpochMs;

  factory GatewayTurnJournalEntry({
    required String connectionId,
    required String endpointDigest,
    required String mobileSessionId,
    required String runtimeSessionId,
    required String storedSessionId,
    required int bindingVersion,
    required String clientTurnId,
    String? turnId,
    GatewayTurnStatus? status,
    required int lastSeq,
    required bool ackUncertain,
    required int updatedAtEpochMs,
  }) {
    if (!_boundedIdentity(connectionId) ||
        !_lowerHexDigest(endpointDigest) ||
        !_canonicalUuid(mobileSessionId) ||
        !_boundedIdentity(runtimeSessionId) ||
        !_boundedIdentity(storedSessionId) ||
        bindingVersion <= 0 ||
        !_canonicalUuid(clientTurnId) ||
        turnId != null && !_boundedIdentity(turnId) ||
        lastSeq < 0 ||
        updatedAtEpochMs <= 0) {
      throw ArgumentError('Invalid recovery journal entry.');
    }
    return GatewayTurnJournalEntry._(
      connectionId: connectionId,
      endpointDigest: endpointDigest,
      mobileSessionId: mobileSessionId,
      runtimeSessionId: runtimeSessionId,
      storedSessionId: storedSessionId,
      bindingVersion: bindingVersion,
      clientTurnId: clientTurnId,
      turnId: turnId,
      status: status,
      lastSeq: lastSeq,
      ackUncertain: ackUncertain,
      updatedAtEpochMs: updatedAtEpochMs,
    );
  }

  const GatewayTurnJournalEntry._({
    required this.connectionId,
    required this.endpointDigest,
    required this.mobileSessionId,
    required this.runtimeSessionId,
    required this.storedSessionId,
    required this.bindingVersion,
    required this.clientTurnId,
    required this.turnId,
    required this.status,
    required this.lastSeq,
    required this.ackUncertain,
    required this.updatedAtEpochMs,
  });

  bool get isTerminal => status?.isTerminal == true;

  String get entryIdentity =>
      '$connectionId:$endpointDigest:$mobileSessionId:$clientTurnId';

  GatewayTurnJournalEntry copyWith({
    String? runtimeSessionId,
    String? storedSessionId,
    int? bindingVersion,
    String? turnId,
    GatewayTurnStatus? status,
    int? lastSeq,
    bool? ackUncertain,
    int? updatedAtEpochMs,
  }) {
    return GatewayTurnJournalEntry(
      connectionId: connectionId,
      endpointDigest: endpointDigest,
      mobileSessionId: mobileSessionId,
      runtimeSessionId: runtimeSessionId ?? this.runtimeSessionId,
      storedSessionId: storedSessionId ?? this.storedSessionId,
      bindingVersion: bindingVersion ?? this.bindingVersion,
      clientTurnId: clientTurnId,
      turnId: turnId ?? this.turnId,
      status: status ?? this.status,
      lastSeq: lastSeq ?? this.lastSeq,
      ackUncertain: ackUncertain ?? this.ackUncertain,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'connection_id': connectionId,
    'endpoint_digest': endpointDigest,
    'mobile_session_id': mobileSessionId,
    'runtime_session_id': runtimeSessionId,
    'stored_session_id': storedSessionId,
    'binding_version': bindingVersion,
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
        : GatewayTurnStatus.fromWire(statusRaw);
    if (statusRaw != null && status == null ||
        value['connection_id'] is! String ||
        value['endpoint_digest'] is! String ||
        value['mobile_session_id'] is! String ||
        value['runtime_session_id'] is! String ||
        value['stored_session_id'] is! String ||
        value['binding_version'] is! int ||
        value['client_turn_id'] is! String ||
        value['turn_id'] != null && value['turn_id'] is! String ||
        value['last_seq'] is! int ||
        value['ack_uncertain'] is! bool ||
        value['updated_at_epoch_ms'] is! int) {
      throw const GatewayTurnJournalException();
    }
    try {
      return GatewayTurnJournalEntry(
        connectionId: value['connection_id'] as String,
        endpointDigest: value['endpoint_digest'] as String,
        mobileSessionId: value['mobile_session_id'] as String,
        runtimeSessionId: value['runtime_session_id'] as String,
        storedSessionId: value['stored_session_id'] as String,
        bindingVersion: value['binding_version'] as int,
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

class GatewayTurnJournal {
  static const schema = 'hermes.android.turn-journal.v1';
  static const maxEntries = 64;
  static const maxEncodedBytes = 64 * 1024;
  static const activeRetention = Duration(days: 7);
  static const terminalRetention = Duration(hours: 24);

  final GatewayTurnJournalStore _store;
  Future<void> _tail = Future<void>.value();

  GatewayTurnJournal({GatewayTurnJournalStore? store})
    : _store = store ?? FlutterSecureGatewayTurnJournalStore();

  Future<List<GatewayTurnJournalEntry>> loadAll() {
    return _serialized(() async => List.unmodifiable(await _readEntries()));
  }

  Future<List<GatewayTurnJournalEntry>> loadForBinding(
    GatewayTurnJournalBinding binding,
  ) {
    return _serialized(() async {
      final entries = await _readEntries();
      return List.unmodifiable(entries.where(binding.owns));
    });
  }

  Future<void> upsert(GatewayTurnJournalEntry entry, {DateTime? now}) {
    return _serialized(() async {
      final entries = await _readEntries();
      entries.removeWhere(
        (candidate) => candidate.entryIdentity == entry.entryIdentity,
      );
      entries.add(entry);
      await _writeEntries(_compact(entries, now ?? DateTime.now().toUtc()));
    });
  }

  Future<void> remove(String entryIdentity) {
    return _serialized(() async {
      final entries = await _readEntries();
      entries.removeWhere((entry) => entry.entryIdentity == entryIdentity);
      await _writeEntries(entries);
    });
  }

  Future<List<GatewayTurnJournalEntry>> compact({DateTime? now}) {
    return _serialized(() async {
      final compacted = _compact(
        await _readEntries(),
        now ?? DateTime.now().toUtc(),
      );
      await _writeEntries(compacted);
      return List.unmodifiable(compacted);
    });
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }

  Future<List<GatewayTurnJournalEntry>> _readEntries() async {
    try {
      final encoded = await _store.read();
      if (encoded == null) return <GatewayTurnJournalEntry>[];
      if (encoded.length > maxEncodedBytes) {
        throw const GatewayTurnJournalException();
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const GatewayTurnJournalException();
      final root = Map<String, dynamic>.from(decoded);
      if (root.length != 2 ||
          root['schema'] != schema ||
          root['entries'] is! List) {
        throw const GatewayTurnJournalException();
      }
      final rawEntries = root['entries'] as List;
      if (rawEntries.length > maxEntries) {
        throw const GatewayTurnJournalException();
      }
      final entries = <GatewayTurnJournalEntry>[];
      final identities = <String>{};
      for (final rawEntry in rawEntries) {
        if (rawEntry is! Map) throw const GatewayTurnJournalException();
        final entry = GatewayTurnJournalEntry._fromJson(
          Map<String, dynamic>.from(rawEntry),
        );
        if (!identities.add(entry.entryIdentity)) {
          throw const GatewayTurnJournalException();
        }
        entries.add(entry);
      }
      return entries;
    } on GatewayTurnJournalException {
      rethrow;
    } catch (_) {
      throw const GatewayTurnJournalException();
    }
  }

  List<GatewayTurnJournalEntry> _compact(
    List<GatewayTurnJournalEntry> entries,
    DateTime now,
  ) {
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    final retained = entries.where((entry) {
      final ageMs = nowMs - entry.updatedAtEpochMs;
      if (ageMs < 0) return true;
      final retention = entry.isTerminal ? terminalRetention : activeRetention;
      return ageMs <= retention.inMilliseconds;
    }).toList();
    retained.sort(
      (left, right) => right.updatedAtEpochMs.compareTo(left.updatedAtEpochMs),
    );
    if (retained.length > maxEntries) {
      retained.removeRange(maxEntries, retained.length);
    }
    return retained;
  }

  Future<void> _writeEntries(List<GatewayTurnJournalEntry> entries) async {
    final encoded = entries.isEmpty
        ? null
        : jsonEncode(<String, Object>{
            'schema': schema,
            'entries': entries.map((entry) => entry.toJson()).toList(),
          });
    if (encoded != null && encoded.length > maxEncodedBytes) {
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
}

bool _boundedIdentity(String value) {
  return value.isNotEmpty &&
      value.length <= 256 &&
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

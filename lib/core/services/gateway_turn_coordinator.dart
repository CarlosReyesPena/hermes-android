import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/gateway_turn_contract.dart';
import 'gateway_turn_journal.dart';
import 'gateway_turn_recovery.dart';
import 'ws_client.dart';

typedef GatewayTurnFreshSocketFactory = Future<WsClient> Function();
typedef GatewayTurnIdFactory = String Function();
typedef GatewayTurnClock = DateTime Function();
typedef GatewayTurnStateCallback =
    void Function(GatewayTurnRecoveryState state);

enum GatewayTurnCoordinatorFailure {
  closed,
  transportUnavailable,
  unsupportedCapability,
  invalidBinding,
  invalidResponse,
  turnUnknown,
  replayPruned,
}

class GatewayTurnCoordinatorException implements Exception {
  final GatewayTurnCoordinatorFailure failure;

  const GatewayTurnCoordinatorException(this.failure);

  @override
  String toString() => 'Gateway turn coordinator stopped: ${failure.name}.';
}

/// Count-only retention view for bounded lifecycle tests and diagnostics.
class GatewayTurnCoordinatorRetentionSnapshot {
  final int activeStates;
  final int settledTombstones;
  final int observers;
  final int activeTurnMappings;
  final int durableTimestampFloors;
  final int retainedEventCount;
  final int retainedSnapshots;
  final bool poisoned;

  const GatewayTurnCoordinatorRetentionSnapshot({
    required this.activeStates,
    required this.settledTombstones,
    required this.observers,
    required this.activeTurnMappings,
    required this.durableTimestampFloors,
    required this.retainedEventCount,
    required this.retainedSnapshots,
    required this.poisoned,
  });
}

/// Opt-in registry for recovery-v2 transports.
///
/// Each local chat owns a distinct physical socket. The registry is deliberately
/// separate from the legacy Desktop transport until a later activation slice.
class GatewayTurnCoordinatorRegistry {
  final String connectionId;
  final String endpointDigest;
  final GatewayTurnJournal journal;
  final GatewayTurnFreshSocketFactory freshSocketFactory;
  final GatewayTurnIdFactory uuidFactory;
  final GatewayTurnClock clock;
  final Map<String, GatewayTurnCoordinator> _coordinators = {};
  final Expando<bool> _leasedSockets = Expando<bool>();
  final Map<String, int> _sessionGenerations = {};
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  bool _closed = false;

  GatewayTurnCoordinatorRegistry({
    required this.connectionId,
    required this.endpointDigest,
    required this.journal,
    required this.freshSocketFactory,
    GatewayTurnIdFactory? uuidFactory,
    GatewayTurnClock? clock,
  }) : uuidFactory = uuidFactory ?? const Uuid().v4,
       clock = clock ?? (() => DateTime.now().toUtc()) {
    if (!_boundedIdentity(connectionId) || !_lowerHexDigest(endpointDigest)) {
      throw ArgumentError('Invalid coordinator registry identity.');
    }
  }

  Future<GatewayTurnCoordinator> open(String localSessionId) {
    if (!_boundedIdentity(localSessionId)) {
      throw ArgumentError.value(
        localSessionId,
        'localSessionId',
        'Invalid local session identity.',
      );
    }
    final requestedGeneration = _sessionGenerations[localSessionId] ?? 0;
    final requestedRegistryGeneration = _generation;
    return _serialized(() async {
      _requireOpenGeneration(
        localSessionId,
        requestedGeneration,
        requestedRegistryGeneration,
      );
      final coordinator = _coordinators.putIfAbsent(
        localSessionId,
        () => GatewayTurnCoordinator(
          connectionId: connectionId,
          endpointDigest: endpointDigest,
          localSessionId: localSessionId,
          journal: journal,
          freshSocketFactory: _leaseFreshSocket,
          uuidFactory: uuidFactory,
          clock: clock,
        ),
      );
      Object? firstError;
      StackTrace? firstStack;
      try {
        await coordinator.ensureOpen();
        _requireOpenGeneration(
          localSessionId,
          requestedGeneration,
          requestedRegistryGeneration,
        );
        if (!identical(_coordinators[localSessionId], coordinator)) {
          throw const GatewayTurnCoordinatorException(
            GatewayTurnCoordinatorFailure.closed,
          );
        }
        return coordinator;
      } catch (error, stack) {
        firstError = error;
        firstStack = stack;
      }
      // A fail-closed state that could not be sealed durably is an absorbing
      // same-process stop. Keep this exact coordinator registered until an
      // explicit registry close resets its lifecycle.
      if (coordinator._isPoisoned) {
        Error.throwWithStackTrace(firstError, firstStack);
      }
      if (identical(_coordinators[localSessionId], coordinator)) {
        _coordinators.remove(localSessionId);
      }
      try {
        await coordinator.close();
      } catch (_) {
        // The open failure remains the primary result.
      }
      Error.throwWithStackTrace(firstError, firstStack);
    });
  }

  Future<GatewayTurnRecoveryState> submit({
    required String localSessionId,
    required String text,
    GatewayTurnStateCallback? onState,
  }) async {
    final coordinator = await open(localSessionId);
    return coordinator.submit(text: text, onState: onState);
  }

  Future<List<GatewayTurnRecoveryState>> recoverPending(
    String localSessionId, {
    GatewayTurnStateCallback? onState,
  }) async {
    final coordinator = await open(localSessionId);
    return coordinator.recoverPending(onState: onState);
  }

  Future<GatewayTurnRecoveryState> interrupt({
    required String localSessionId,
    required String clientTurnId,
  }) async {
    final coordinator = await open(localSessionId);
    return coordinator.interrupt(clientTurnId);
  }

  Future<void> close(String localSessionId) {
    _sessionGenerations[localSessionId] =
        (_sessionGenerations[localSessionId] ?? 0) + 1;
    return _serialized(() async {
      final coordinator = _coordinators[localSessionId];
      if (coordinator == null) return;
      try {
        await coordinator.close();
      } finally {
        if (identical(_coordinators[localSessionId], coordinator)) {
          _coordinators.remove(localSessionId);
        }
      }
    });
  }

  Future<void> closeAll() {
    if (_closed) return _tail;
    _closed = true;
    _generation += 1;
    return _serialized(() async {
      final coordinators = _coordinators.values.toList(growable: false);
      Object? firstError;
      StackTrace? firstStack;
      for (final coordinator in coordinators) {
        try {
          await coordinator.close();
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
      _coordinators.clear();
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStack!);
      }
    });
  }

  Future<WsClient> _leaseFreshSocket() async {
    final client = await freshSocketFactory();
    if (_leasedSockets[client] == true) {
      throw StateError('The fresh socket factory reused a transport.');
    }
    _leasedSockets[client] = true;
    return client;
  }

  void _requireOpenGeneration(
    String localSessionId,
    int requestedGeneration,
    int requestedRegistryGeneration,
  ) {
    if (_closed ||
        _generation != requestedRegistryGeneration ||
        (_sessionGenerations[localSessionId] ?? 0) != requestedGeneration) {
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.closed,
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }
}

/// Serializes one local chat's open/submit/event/reconcile lifecycle.
class GatewayTurnCoordinator {
  static const int maxSettledTombstones = GatewayTurnJournal.maxEntries;

  final String connectionId;
  final String endpointDigest;
  final String localSessionId;
  final GatewayTurnJournal journal;
  final GatewayTurnFreshSocketFactory freshSocketFactory;
  final GatewayTurnIdFactory uuidFactory;
  final GatewayTurnClock clock;

  final Map<String, GatewayTurnRecoveryState> _states = {};
  final Map<String, String> _clientTurnByTurnId = {};
  final Map<String, GatewayTurnStateCallback> _observers = {};
  final LinkedHashMap<String, GatewayTurnRecoveryState> _settledTombstones =
      LinkedHashMap<String, GatewayTurnRecoveryState>();
  final Map<String, int> _durableTimestampFloors = {};
  final Expando<bool> _usedSockets = Expando<bool>();
  Future<void> _tail = Future<void>.value();
  WsClient? _client;
  GatewaySessionBinding? _runtimeBinding;
  GatewayTurnJournalBinding? _durableBinding;
  bool _closed = false;

  GatewayTurnCoordinator({
    required this.connectionId,
    required this.endpointDigest,
    required this.localSessionId,
    required this.journal,
    required this.freshSocketFactory,
    required this.uuidFactory,
    required this.clock,
  }) {
    if (!_boundedIdentity(connectionId) ||
        !_lowerHexDigest(endpointDigest) ||
        !_boundedIdentity(localSessionId)) {
      throw ArgumentError('Invalid turn coordinator identity.');
    }
  }

  GatewaySessionBinding? get runtimeBinding => _runtimeBinding;

  GatewayTurnJournalBinding? get durableBinding => _durableBinding;

  GatewayTurnRecoveryState? stateFor(String clientTurnId) {
    final local = _states[clientTurnId] ?? _settledTombstones[clientTurnId];
    if (local != null) return local;
    final processFailure = _processPoisonedFailure;
    return processFailure?.clientTurnId == clientTurnId ? processFailure : null;
  }

  GatewayTurnCoordinatorRetentionSnapshot get retentionSnapshot {
    final retained = <GatewayTurnRecoveryState>[
      ..._states.values,
      ..._settledTombstones.values,
    ];
    return GatewayTurnCoordinatorRetentionSnapshot(
      activeStates: _states.length,
      settledTombstones: _settledTombstones.length,
      observers: _observers.length,
      activeTurnMappings: _clientTurnByTurnId.length,
      durableTimestampFloors: _durableTimestampFloors.length,
      retainedEventCount: retained.fold<int>(
        0,
        (total, state) => total + state.eventsBySeq.length,
      ),
      retainedSnapshots: retained
          .where((state) => state.snapshot != null)
          .length,
      poisoned: _isPoisoned,
    );
  }

  Future<void> waitForIdle() => _tail;

  Future<void> ensureOpen() => _serialized(() async {
    _requireOperational();
    if (_client?.isConnected == true && _runtimeBinding != null) return;
    await _openFreshTransport();
  });

  Future<GatewayTurnRecoveryState> submit({
    required String text,
    GatewayTurnStateCallback? onState,
  }) => _serialized(() async {
    _requireOperational();
    if (_client?.isConnected != true || _runtimeBinding == null) {
      await _openFreshTransport();
    }
    final client = _client!;
    final runtime = _runtimeBinding!;
    final durable = _durableBinding!;
    if (utf8.encode(text).length > runtime.capability.maxPromptBytes!) {
      throw ArgumentError.value(text, 'text', 'Prompt exceeds gateway limit.');
    }

    final clientTurnId = uuidFactory();
    if (!_canonicalV4Uuid(clientTurnId) ||
        _states.containsKey(clientTurnId) ||
        _settledTombstones.containsKey(clientTurnId)) {
      throw StateError('The coordinator UUID source returned an invalid ID.');
    }
    var state = GatewayTurnRecoveryState.initial(
      clientTurnId: clientTurnId,
    ).markSubmissionStarted();
    _states[clientTurnId] = state;
    if (onState != null) _observers[clientTurnId] = onState;

    // The durable read-back performed by GatewayTurnJournal completes before
    // the first and only prompt.submit write is allowed onto the socket.
    try {
      await _persistDurableState(durable, state);
    } catch (_) {
      _discardUnsubmittedState(state);
      rethrow;
    }
    _requireNotPoisoned();
    Map<String, dynamic> result;
    try {
      final response = await client.send('prompt.submit', <String, dynamic>{
        'session_id': runtime.runtimeSessionId,
        'version': GatewayTurnRecoveryCapability.promptSubmitVersion,
        'client_turn_id': clientTurnId,
        'text': text,
      });
      result = _resultOrThrow('prompt.submit', response);
    } on JsonRpcError catch (error, stack) {
      if (!_ambiguousJsonRpcFailure(error)) {
        state = state.failReconcile(
          GatewayTurnRecoveryFailure.protocolViolation,
        );
        _remember(state);
        await _persistWireStateOrClose(state, client);
        Error.throwWithStackTrace(error, stack);
      }
      if (identical(_client, client) && client.isConnected) {
        return _reconcile(state);
      }
      rethrow;
    } on GatewayTurnCoordinatorException {
      // A malformed/missing acknowledgement is ambiguous. Resolve only from
      // server authority; this path never writes prompt.submit again.
      if (identical(_client, client) && client.isConnected) {
        return _reconcile(state);
      }
      rethrow;
    } catch (error, stack) {
      if (error is IOException || error is TimeoutException) {
        if (identical(_client, client) && client.isConnected) {
          return _reconcile(state);
        }
        rethrow;
      }
      state = state.failReconcile(GatewayTurnRecoveryFailure.protocolViolation);
      _remember(state);
      await _persistWireStateOrClose(state, client);
      Error.throwWithStackTrace(error, stack);
    }
    final ack = GatewayTurnAck.fromWire(result);
    if (ack == null) {
      if (identical(_client, client) && client.isConnected) {
        return _reconcile(state);
      }
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidResponse,
      );
    }
    if (ack.clientTurnId != clientTurnId) {
      state = state.failReconcile(GatewayTurnRecoveryFailure.protocolViolation);
      _remember(state);
      await _persistWireStateOrClose(state, client);
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidResponse,
      );
    }
    state = state.applyAck(ack);
    _remember(state);
    await _persistWireStateOrClose(state, client);
    _requireHealthy(state);
    if (state.requiredAction == GatewayTurnRecoveryAction.reconcile) {
      state = await _reconcile(state);
    }
    return state;
  });

  Future<List<GatewayTurnRecoveryState>> recoverPending({
    GatewayTurnStateCallback? onState,
  }) => _serialized(() async {
    _requireOperational();
    if (_client?.isConnected != true || _runtimeBinding == null) {
      await _openFreshTransport(recoverJournal: false);
    }
    return _recoverJournal(onState: onState);
  });

  Future<GatewayTurnRecoveryState> interrupt(String clientTurnId) =>
      _serialized(() async {
        _requireOperational();
        final client = _client;
        final runtime = _runtimeBinding;
        final state = _states[clientTurnId];
        if (client == null ||
            !client.isConnected ||
            runtime == null ||
            state == null ||
            state.isTerminal ||
            state.isFailClosed) {
          throw const GatewayTurnCoordinatorException(
            GatewayTurnCoordinatorFailure.transportUnavailable,
          );
        }
        final params = <String, dynamic>{
          'session_id': runtime.runtimeSessionId,
          if (state.turnId != null) 'turn_id': state.turnId,
          if (state.turnId == null) 'client_turn_id': clientTurnId,
        };
        final uncertain = state.markDisconnected();
        _remember(uncertain);
        await _persistAndNotify(uncertain);
        _requireNotPoisoned();
        Map<String, dynamic> result;
        try {
          final response = await client.send('turn.interrupt', params);
          result = _resultOrThrow('turn.interrupt', response);
        } catch (_) {
          if (identical(_client, client) && client.isConnected) {
            return _reconcile(uncertain);
          }
          rethrow;
        }
        if (result['automatic_resubmit'] != false ||
            result['client_turn_id'] != clientTurnId ||
            state.turnId != null && result['turn_id'] != state.turnId ||
            GatewayRecoveryTurnStatus.fromWire(result['status']) == null ||
            result['last_seq'] is! int ||
            (result['last_seq'] as int) < state.lastSeq) {
          if (identical(_client, client) && client.isConnected) {
            return _reconcile(uncertain);
          }
          throw const GatewayTurnCoordinatorException(
            GatewayTurnCoordinatorFailure.invalidResponse,
          );
        }
        return _reconcile(uncertain);
      });

  Future<void> close() => _serialized(() async {
    if (_closed) return;
    _closed = true;
    final client = _client;
    _client = null;
    _runtimeBinding = null;
    client?.onConnectionChanged = null;
    client?.onStreamEvent = null;
    Object? firstError;
    StackTrace? firstStack;
    try {
      await _markAllDisconnectedBestEffort();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    } finally {
      try {
        client?.close();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      } finally {
        _releaseAllMemory();
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  });

  Future<void> _openFreshTransport({bool recoverJournal = true}) async {
    _requireOperational();
    final previous = await journal.loadBinding(
      connectionId: connectionId,
      endpointDigest: endpointDigest,
      localSessionId: localSessionId,
    );
    _requireOperational();
    final generatedMobileSessionId = previous == null;
    final mobileSessionId = previous?.mobileSessionId ?? uuidFactory();
    if (generatedMobileSessionId
        ? !_canonicalV4Uuid(mobileSessionId)
        : !_canonicalPersistedUuid(mobileSessionId)) {
      throw StateError('The coordinator mobile UUID is invalid.');
    }
    final client = await freshSocketFactory();
    if (_usedSockets[client] == true) {
      throw StateError('The coordinator socket factory reused a transport.');
    }
    _usedSockets[client] = true;
    client.onStreamEvent = (event) {
      _observeSocketAction(client, () => _handleLiveEvent(client, event));
    };
    client.onConnectionChanged = (connected) {
      if (!connected) {
        _observeSocketAction(client, () => _markTransportLost(client));
      }
    };
    try {
      _requireOperational();
      await client.connect();
      _requireOperational();
      final ready = GatewayTurnRecoveryCapability.fromGatewayReadyFrame(
        await client.waitForGatewayReady(),
      );
      _requireOperational();
      if (!_coordinatorCapabilitySupported(ready)) {
        throw const GatewayTurnCoordinatorException(
          GatewayTurnCoordinatorFailure.unsupportedCapability,
        );
      }
      final openResponse = await client.send('session.open', <String, dynamic>{
        'mobile_session_id': mobileSessionId,
      });
      _requireOperational();
      final openResult = _resultOrThrow('session.open', openResponse);
      final binding = GatewaySessionBinding.fromWire(
        openResult,
        readyCapability: ready,
        expectedMobileSessionId: mobileSessionId,
        expectedStoredSessionId: previous?.storedSessionId,
        minimumBindingVersion: previous == null
            ? null
            : previous.bindingVersion + 1,
      );
      if (binding == null ||
          !_coordinatorCapabilitySupported(binding.capability)) {
        throw const GatewayTurnCoordinatorException(
          GatewayTurnCoordinatorFailure.invalidBinding,
        );
      }
      final durable = GatewayTurnJournalBinding(
        connectionId: connectionId,
        endpointDigest: endpointDigest,
        localSessionId: localSessionId,
        mobileSessionId: binding.mobileSessionId,
        storedSessionId: binding.storedSessionId,
        bindingVersion: binding.bindingVersion,
        updatedAtEpochMs: _causalTimestamp(
          previous?.updatedAtEpochMs,
          _nowEpochMs(),
        ),
      );
      await journal.upsertBinding(durable);
      _requireOperational();
      _client = client;
      _runtimeBinding = binding;
      _durableBinding = durable;
      if (recoverJournal) await _recoverJournal();
    } catch (error, stack) {
      if (identical(_client, client)) {
        _client = null;
        _runtimeBinding = null;
      }
      client.onConnectionChanged = null;
      client.onStreamEvent = null;
      try {
        client.close();
      } catch (_) {
        // Preserve the open failure after guaranteed close was attempted.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<List<GatewayTurnRecoveryState>> _recoverJournal({
    GatewayTurnStateCallback? onState,
  }) async {
    final durable = _durableBinding!;
    final entries = await journal.loadForBinding(durable);
    final recovered = <GatewayTurnRecoveryState>[];
    for (final entry in entries) {
      _durableTimestampFloors[entry.clientTurnId] = entry.updatedAtEpochMs;
      if (onState != null && entry.failure == null && !entry.isTerminal) {
        _observers[entry.clientTurnId] = onState;
      }
      var state = _states[entry.clientTurnId];
      if (state == null) {
        state = GatewayTurnRecoveryState.rehydrate(
          clientTurnId: entry.clientTurnId,
          turnId: entry.turnId,
          status: entry.status,
          lastSeq: entry.lastSeq,
          ackUncertain: entry.ackUncertain,
          eventPayloadBytes: entry.eventPayloadBytes,
          terminalEventRecorded: entry.terminalEventRecorded,
          failure: entry.failure,
        );
        _states[entry.clientTurnId] = state;
        if (entry.turnId != null) {
          _clientTurnByTurnId[entry.turnId!] = entry.clientTurnId;
        }
      }
      if (!_stateBytesWithinCapability(state, _runtimeBinding!.capability)) {
        state = state.failReconcile(
          GatewayTurnRecoveryFailure.protocolViolation,
        );
        _remember(state);
        await _persistWireStateOrClose(state, _client!);
      }
      if (state.isFailClosed) {
        _settleState(state);
      }
      _requireHealthy(state);
      if (state.requiredAction == GatewayTurnRecoveryAction.none) {
        recovered.add(state);
        if (onState != null) {
          try {
            onState(state);
          } catch (_) {
            // An already durable state remains authoritative.
          }
        }
        _settleIfDone(state);
        continue;
      }
      recovered.add(await _reconcile(state, durableCursor: entry));
    }
    return List<GatewayTurnRecoveryState>.unmodifiable(recovered);
  }

  Future<GatewayTurnRecoveryState> _reconcile(
    GatewayTurnRecoveryState state, {
    GatewayTurnJournalEntry? durableCursor,
  }) async {
    _requireNotPoisoned();
    final client = _client;
    final runtime = _runtimeBinding;
    if (client == null || !client.isConnected || runtime == null) {
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.transportUnavailable,
      );
    }
    var pinnedTurnId = state.turnId ?? durableCursor?.turnId;
    var cursor = durableCursor?.lastSeq ?? state.lastSeq;
    while (true) {
      final params = <String, dynamic>{
        'session_id': runtime.runtimeSessionId,
        'turn_id': ?pinnedTurnId,
        if (pinnedTurnId == null) 'client_turn_id': state.clientTurnId,
        'after_seq': cursor,
      };
      Map<String, dynamic> result;
      try {
        _requireNotPoisoned();
        final response = await client.send('turn.reconcile', params);
        result = _resultOrThrow('turn.reconcile', response);
      } on JsonRpcError catch (error) {
        if (error.reason == 'connection_closed' || error.message == 'Timeout') {
          rethrow;
        }
        final failure = switch (error.reason) {
          'turn_unknown' => GatewayTurnRecoveryFailure.turnUnknown,
          'turn_replay_pruned' => GatewayTurnRecoveryFailure.replayPruned,
          _ => GatewayTurnRecoveryFailure.protocolViolation,
        };
        state = state.failReconcile(failure);
        _remember(state);
        await _persistWireStateOrClose(state, client);
        throw GatewayTurnCoordinatorException(switch (failure) {
          GatewayTurnRecoveryFailure.turnUnknown =>
            GatewayTurnCoordinatorFailure.turnUnknown,
          GatewayTurnRecoveryFailure.replayPruned =>
            GatewayTurnCoordinatorFailure.replayPruned,
          _ => GatewayTurnCoordinatorFailure.invalidResponse,
        });
      } on GatewayTurnCoordinatorException {
        state = state.failReconcile(
          GatewayTurnRecoveryFailure.protocolViolation,
        );
        _remember(state);
        await _persistWireStateOrClose(state, client);
        throw const GatewayTurnCoordinatorException(
          GatewayTurnCoordinatorFailure.invalidResponse,
        );
      }
      if (utf8.encode(jsonEncode(result)).length >
          runtime.capability.reconcileMaxPageBytes!) {
        state = state.failReconcile(
          GatewayTurnRecoveryFailure.protocolViolation,
        );
        _remember(state);
        await _persistWireStateOrClose(state, client);
        throw const GatewayTurnCoordinatorException(
          GatewayTurnCoordinatorFailure.invalidResponse,
        );
      }
      final page = GatewayTurnReconcilePage.fromWire(
        result,
        expectedAfterSeq: cursor,
        expectedTurnId: pinnedTurnId,
        expectedClientTurnId: state.clientTurnId,
      );
      if (page == null ||
          page.events.length > runtime.capability.reconcileMaxEvents! ||
          page.hasMore && page.nextAfterSeq <= cursor) {
        state = state.failReconcile(
          GatewayTurnRecoveryFailure.protocolViolation,
        );
        _remember(state);
        await _persistWireStateOrClose(state, client);
        throw const GatewayTurnCoordinatorException(
          GatewayTurnCoordinatorFailure.invalidResponse,
        );
      }
      state = _applyBoundedReconcilePage(state, page, runtime.capability);
      _remember(state);
      if (state.isFailClosed) {
        await _persistWireStateOrClose(state, client);
        _requireHealthy(state);
      }
      if (durableCursor == null || state.lastSeq >= durableCursor.lastSeq) {
        await _persistWireStateOrClose(state, client);
        durableCursor = null;
      }
      if (!page.hasMore) return state;
      pinnedTurnId ??= page.turnId;
      cursor = page.nextAfterSeq;
    }
  }

  Future<void> _handleLiveEvent(WsClient source, StreamEvent event) async {
    final runtime = _runtimeBinding;
    if (!identical(_client, source) ||
        runtime == null ||
        event.sessionId != runtime.runtimeSessionId) {
      return;
    }
    var correlatedClientTurnId = _clientTurnIdForTurnId(
      event.envelope['turn_id'],
    );
    final parsed = GatewayTurnEvent.fromWire(event.envelope);
    if (parsed == null) {
      if (GatewayTurnEvent.allowedTypes.contains(event.type)) {
        await _failActiveProtocol(
          source,
          correlatedClientTurnId: correlatedClientTurnId,
        );
      }
      return;
    }
    final clientTurnId =
        _clientTurnByTurnId[parsed.turnId] ??
        _clientTurnIdForTurnId(parsed.turnId);
    if (clientTurnId == null) {
      await _failActiveProtocol(source);
      return;
    }
    correlatedClientTurnId = clientTurnId;
    var state = _states[clientTurnId];
    if (state == null) {
      // A bounded settled tombstone can correlate a late frame, but terminal
      // history is never resurrected or converted into a durable failure.
      await _failActiveProtocol(
        source,
        correlatedClientTurnId: correlatedClientTurnId,
      );
      return;
    }
    try {
      state = _applyBoundedEvent(state, parsed, runtime.capability);
      _remember(state);
      await _persistAndNotify(state);
      _requireHealthy(state);
      if (state.requiredAction == GatewayTurnRecoveryAction.reconcile) {
        await _reconcile(state);
      }
    } catch (_) {
      try {
        await _quarantineAndCloseExactSource(
          source,
          correlatedClientTurnId: correlatedClientTurnId,
        );
      } finally {
        if (state != null) _settleIfDone(state);
      }
    }
  }

  Future<void> _failActiveProtocol(
    WsClient source, {
    String? correlatedClientTurnId,
  }) async {
    await _quarantineAndCloseExactSource(
      source,
      correlatedClientTurnId: correlatedClientTurnId,
    );
  }

  Future<void> _markTransportLost(WsClient source) async {
    if (!identical(_client, source)) return;
    _client = null;
    _runtimeBinding = null;
    source.onConnectionChanged = null;
    source.onStreamEvent = null;
    Object? firstError;
    StackTrace? firstStack;
    try {
      await _markAllDisconnectedBestEffort();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    } finally {
      try {
        source.close();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  Future<void> _markAllDisconnectedBestEffort() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final entry in _states.entries.toList(growable: false)) {
      final previous = entry.value;
      if (previous.isTerminal || previous.isFailClosed) {
        _settleState(previous);
        continue;
      }
      final state = previous.markDisconnected();
      if (state.ackUncertain == previous.ackUncertain &&
          state.reconcilePending == previous.reconcilePending) {
        continue;
      }
      _states[entry.key] = state;
      try {
        await _persistAndNotify(state);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  Future<void> _quarantineAndCloseExactSource(
    WsClient source, {
    bool sourceOwnedAtDispatch = false,
    String? correlatedClientTurnId,
  }) async {
    final ownsSource = identical(_client, source);
    final quarantineStates =
        ownsSource || sourceOwnedAtDispatch && _client == null;
    if (ownsSource) {
      _client = null;
      _runtimeBinding = null;
    }
    source.onConnectionChanged = null;
    source.onStreamEvent = null;
    Object? firstError;
    StackTrace? firstStack;
    try {
      if (quarantineStates) {
        final candidates = correlatedClientTurnId == null
            ? _states.entries.toList(growable: false)
            : <MapEntry<String, GatewayTurnRecoveryState>>[
                if (_states[correlatedClientTurnId] case final state?)
                  MapEntry<String, GatewayTurnRecoveryState>(
                    correlatedClientTurnId,
                    state,
                  ),
              ];
        for (final entry in candidates) {
          if (entry.value.isTerminal || entry.value.isFailClosed) continue;
          final failed = entry.value.failReconcile(
            GatewayTurnRecoveryFailure.protocolViolation,
          );
          _states[entry.key] = failed;
          try {
            await _persistAndNotify(failed);
          } catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
          } finally {
            _settleState(failed);
          }
        }
        try {
          // Closing the shared source makes every non-target active turn
          // uncertain. They reconcile later; they are not quarantined merely
          // because another correlated turn violated protocol.
          await _markAllDisconnectedBestEffort();
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    } finally {
      try {
        source.close();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  void _observeSocketAction(WsClient source, Future<void> Function() action) {
    final run = _serialized(() async {
      try {
        await action();
      } catch (_) {
        try {
          if (identical(_client, source)) {
            await _markTransportLost(source);
          } else {
            source.onConnectionChanged = null;
            source.onStreamEvent = null;
            source.close();
          }
        } catch (_) {
          source.onConnectionChanged = null;
          source.onStreamEvent = null;
          try {
            source.close();
          } catch (_) {
            // Callback failures have no caller; close was still attempted.
          }
        }
      }
    });
    unawaited(run.then<void>((_) {}, onError: (_, _) {}));
  }

  GatewayTurnRecoveryState _applyBoundedReconcilePage(
    GatewayTurnRecoveryState state,
    GatewayTurnReconcilePage page,
    GatewayTurnRecoveryCapability capability,
  ) {
    if (page.mode == GatewayTurnReconcileMode.snapshot) {
      final snapshot = page.snapshot;
      if (snapshot == null ||
          utf8.encode(snapshot.assistant.text).length >
              capability.maxTurnBytes!) {
        return state.failReconcile(
          GatewayTurnRecoveryFailure.protocolViolation,
        );
      }
      return state.applyReconcilePage(page);
    }
    final payloadBytesBySeq = <int, int>{};
    var probe = state;
    for (final event in page.events) {
      final payloadBytes = GatewayTurnRecoveryState.payloadBytesFor(event);
      payloadBytesBySeq[event.seq] = payloadBytes;
      probe = _applyBoundedEvent(probe, event, capability);
      if (probe.isFailClosed) return probe;
    }
    return state.applyReconcilePage(page, payloadBytesBySeq: payloadBytesBySeq);
  }

  GatewayTurnRecoveryState _applyBoundedEvent(
    GatewayTurnRecoveryState state,
    GatewayTurnEvent event,
    GatewayTurnRecoveryCapability capability,
  ) {
    final payloadBytes = GatewayTurnRecoveryState.payloadBytesFor(event);
    if (payloadBytes > capability.maxEventBytes!) {
      return state.failReconcile(GatewayTurnRecoveryFailure.protocolViolation);
    }
    final newlyAccepted = event.seq == state.lastSeq + 1;
    final next = state.applyEvent(
      event,
      payloadBytes: newlyAccepted ? payloadBytes : 0,
    );
    if (!newlyAccepted || next.isFailClosed) return next;
    final maxTurnBytes = capability.maxTurnBytes!;
    final allowed = next.terminalEventRecorded
        ? maxTurnBytes
        : maxTurnBytes - capability.terminalEventReserveBytes!;
    if (allowed < 0 || next.eventPayloadBytes > allowed) {
      return state.failReconcile(GatewayTurnRecoveryFailure.protocolViolation);
    }
    return next;
  }

  bool _stateBytesWithinCapability(
    GatewayTurnRecoveryState state,
    GatewayTurnRecoveryCapability capability,
  ) {
    final maxTurnBytes = capability.maxTurnBytes!;
    final allowed = state.terminalEventRecorded
        ? maxTurnBytes
        : maxTurnBytes - capability.terminalEventReserveBytes!;
    return allowed >= 0 && state.eventPayloadBytes <= allowed;
  }

  void _remember(GatewayTurnRecoveryState state) {
    _settledTombstones.remove(state.clientTurnId);
    _states[state.clientTurnId] = state;
    if (state.turnId != null) {
      _clientTurnByTurnId[state.turnId!] = state.clientTurnId;
    }
  }

  Future<void> _persistAndNotify(GatewayTurnRecoveryState state) async {
    final durable = _durableBinding;
    if (durable == null) {
      _poisonIfUnpersistedFailure(state);
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidBinding,
      );
    }
    await _persistDurableState(durable, state);
    try {
      _observers[state.clientTurnId]?.call(state);
    } catch (_) {
      // Durable state is authoritative; observer code cannot fail the turn.
    }
    _settleIfDone(state);
  }

  Future<void> _persistDurableState(
    GatewayTurnJournalBinding durable,
    GatewayTurnRecoveryState state,
  ) async {
    try {
      final entry = _entryFromState(
        durable,
        state,
        updatedAtEpochMs: _causalTimestamp(
          _durableTimestampFloors[state.clientTurnId],
          _nowEpochMs(),
        ),
      );
      await journal.upsert(entry);
      _durableTimestampFloors[state.clientTurnId] = entry.updatedAtEpochMs;
    } catch (_) {
      _poisonIfUnpersistedFailure(state);
      rethrow;
    }
  }

  Future<void> _persistWireStateOrClose(
    GatewayTurnRecoveryState state,
    WsClient source,
  ) async {
    try {
      await _persistAndNotify(state);
    } catch (error, stack) {
      try {
        await _quarantineAndCloseExactSource(
          source,
          sourceOwnedAtDispatch: identical(_client, source),
          correlatedClientTurnId: state.clientTurnId,
        );
      } catch (_) {
        // Preserve the first journal failure after exact-source shutdown.
      } finally {
        _settleIfDone(state);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  GatewayTurnJournalEntry _entryFromState(
    GatewayTurnJournalBinding durable,
    GatewayTurnRecoveryState state, {
    required int updatedAtEpochMs,
  }) => GatewayTurnJournalEntry(
    bindingIdentity: durable.bindingIdentity,
    clientTurnId: state.clientTurnId,
    turnId: state.turnId,
    status: state.status,
    lastSeq: state.lastSeq,
    eventPayloadBytes: state.eventPayloadBytes,
    terminalEventRecorded: state.terminalEventRecorded,
    ackUncertain: state.ackUncertain,
    failure: state.failure,
    updatedAtEpochMs: updatedAtEpochMs,
  );

  void _settleIfDone(GatewayTurnRecoveryState state) {
    if (state.isTerminal || state.isFailClosed) _settleState(state);
  }

  void _settleState(GatewayTurnRecoveryState state) {
    _states.remove(state.clientTurnId);
    final turnId = state.turnId;
    if (turnId != null && _clientTurnByTurnId[turnId] == state.clientTurnId) {
      _clientTurnByTurnId.remove(turnId);
    }
    _observers.remove(state.clientTurnId);
    _durableTimestampFloors.remove(state.clientTurnId);
    _settledTombstones.remove(state.clientTurnId);
    _settledTombstones[state.clientTurnId] = state.releasePayloads();
    while (_settledTombstones.length > maxSettledTombstones) {
      _settledTombstones.remove(_settledTombstones.keys.first);
    }
  }

  void _discardUnsubmittedState(GatewayTurnRecoveryState state) {
    _states.remove(state.clientTurnId);
    _observers.remove(state.clientTurnId);
    _durableTimestampFloors.remove(state.clientTurnId);
    final turnId = state.turnId;
    if (turnId != null && _clientTurnByTurnId[turnId] == state.clientTurnId) {
      _clientTurnByTurnId.remove(turnId);
    }
  }

  void _releaseAllMemory() {
    _states.clear();
    _clientTurnByTurnId.clear();
    _observers.clear();
    _settledTombstones.clear();
    _durableTimestampFloors.clear();
  }

  GatewayTurnRecoveryState? get _processPoisonedFailure =>
      journal.processPoisonedFailure(
        connectionId: connectionId,
        endpointDigest: endpointDigest,
        localSessionId: localSessionId,
      );

  bool get _isPoisoned => _processPoisonedFailure != null;

  void _poisonIfUnpersistedFailure(GatewayTurnRecoveryState state) {
    if (!state.isFailClosed || _isPoisoned) return;
    journal.recordProcessPoison(
      connectionId: connectionId,
      endpointDigest: endpointDigest,
      localSessionId: localSessionId,
      failure: state,
    );
  }

  String? _clientTurnIdForTurnId(Object? rawTurnId) {
    if (rawTurnId is! String) return null;
    final active = _clientTurnByTurnId[rawTurnId];
    if (active != null) return active;
    for (final entry in _settledTombstones.entries) {
      if (entry.value.turnId == rawTurnId) return entry.key;
    }
    return null;
  }

  int _nowEpochMs() {
    final value = clock().toUtc().millisecondsSinceEpoch;
    if (value <= 0) throw StateError('Coordinator clock is invalid.');
    return value;
  }

  Map<String, dynamic> _resultOrThrow(
    String method,
    Map<String, dynamic> response,
  ) {
    final error = response['error'];
    if (error != null) {
      if (error is Map) {
        throw JsonRpcError.fromGateway(
          method,
          error,
          fallbackMessage: 'Gateway request failed.',
        );
      }
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidResponse,
      );
    }
    final result = response['result'];
    if (result is! Map) {
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidResponse,
      );
    }
    return <String, dynamic>{
      for (final entry in result.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  void _requireHealthy(GatewayTurnRecoveryState state) {
    if (state.isFailClosed) {
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidResponse,
      );
    }
  }

  void _requireNotClosed() {
    if (_closed) {
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.closed,
      );
    }
  }

  void _requireNotPoisoned() {
    if (_isPoisoned) {
      throw const GatewayTurnCoordinatorException(
        GatewayTurnCoordinatorFailure.invalidResponse,
      );
    }
  }

  void _requireOperational() {
    _requireNotClosed();
    _requireNotPoisoned();
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }
}

bool _canonicalV4Uuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

bool _canonicalPersistedUuid(String value) =>
    value != '00000000-0000-0000-0000-000000000000' &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(value);

bool _ambiguousJsonRpcFailure(JsonRpcError error) {
  if (error.message == 'Timeout') return true;
  return const <String>{
    'connection_closed',
    'transport_closed',
    'transport_error',
    'websocket_error',
    'socket_error',
  }.contains(error.reason);
}

bool _coordinatorCapabilitySupported(GatewayTurnRecoveryCapability capability) {
  final maxTurnBytes = capability.maxTurnBytes;
  final terminalReserveBytes = capability.terminalEventReserveBytes;
  return capability.supported &&
      maxTurnBytes != null &&
      terminalReserveBytes != null &&
      terminalReserveBytes <= maxTurnBytes;
}

int _causalTimestamp(int? durablePrior, int current) =>
    durablePrior != null && durablePrior > current ? durablePrior : current;

bool _boundedIdentity(String value) =>
    value.isNotEmpty &&
    value.length <= 256 &&
    value.trim() == value &&
    !value.codeUnits.any((unit) => unit < 32 || unit >= 127 && unit <= 159);

bool _lowerHexDigest(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

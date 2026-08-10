import '../models/gateway_turn_contract.dart';

enum GatewayTurnRecoveryAction { none, reconcile, stopFailClosed }

enum GatewayTurnRecoveryFailure {
  turnUnknown,
  replayPruned,
  turnMismatch,
  clientTurnMismatch,
  duplicateConflict,
  sequenceGap,
  invalidTransition,
  protocolViolation,
}

/// Immutable, transport-free state for one server-authoritative turn.
///
/// There is intentionally no submit/resubmit action. Once a write-ahead entry
/// exists, an uncertain acknowledgement, disconnect, or process restart may
/// only reconcile by `client_turn_id`/`turn_id` from the durable server.
class GatewayTurnRecoveryState {
  final String clientTurnId;
  final String? turnId;
  final GatewayTurnStatus? status;
  final int lastSeq;
  final Map<int, GatewayTurnEvent> eventsBySeq;
  final GatewayTurnSnapshot? snapshot;
  final bool ackUncertain;
  final bool reconcilePending;
  final GatewayTurnRecoveryFailure? failure;

  GatewayTurnRecoveryState.initial({required this.clientTurnId})
    : turnId = null,
      status = null,
      lastSeq = 0,
      eventsBySeq = const {},
      snapshot = null,
      ackUncertain = false,
      reconcilePending = false,
      failure = null;

  const GatewayTurnRecoveryState._({
    required this.clientTurnId,
    required this.turnId,
    required this.status,
    required this.lastSeq,
    required this.eventsBySeq,
    required this.snapshot,
    required this.ackUncertain,
    required this.reconcilePending,
    required this.failure,
  });

  bool get isFailClosed => failure != null;

  bool get isTerminal => status?.isTerminal == true;

  GatewayTurnRecoveryAction get requiredAction {
    if (failure != null) return GatewayTurnRecoveryAction.stopFailClosed;
    if (ackUncertain || reconcilePending) {
      return GatewayTurnRecoveryAction.reconcile;
    }
    return GatewayTurnRecoveryAction.none;
  }

  List<GatewayTurnEvent> get events {
    final values = eventsBySeq.values.toList(growable: false);
    values.sort((left, right) => left.seq.compareTo(right.seq));
    return values;
  }

  GatewayTurnRecoveryState markSubmissionStarted() {
    if (failure != null || isTerminal) return this;
    return _copyWith(ackUncertain: true, reconcilePending: false);
  }

  GatewayTurnRecoveryState markDisconnected() {
    if (failure != null || isTerminal) return this;
    return _copyWith(ackUncertain: true, reconcilePending: false);
  }

  GatewayTurnRecoveryState applyAck(GatewayTurnAck ack) {
    if (failure != null) return this;
    if (ack.clientTurnId != clientTurnId) {
      return _fail(GatewayTurnRecoveryFailure.clientTurnMismatch);
    }
    if (turnId != null && turnId != ack.turnId) {
      return _fail(GatewayTurnRecoveryFailure.turnMismatch);
    }
    if (ack.lastSeq < lastSeq) {
      return _fail(GatewayTurnRecoveryFailure.protocolViolation);
    }
    if (ack.lastSeq > lastSeq) {
      // The server has committed events not yet applied locally. Preserve the
      // local cursor and reconcile; never infer that the prompt should be sent.
      return _copyWith(
        turnId: ack.turnId,
        ackUncertain: true,
        reconcilePending: false,
      );
    }
    if (status != null && !_transitionAllowed(status!, ack.status)) {
      return _fail(GatewayTurnRecoveryFailure.invalidTransition);
    }
    return _copyWith(
      turnId: ack.turnId,
      status: ack.status,
      ackUncertain: false,
      reconcilePending: false,
    );
  }

  GatewayTurnRecoveryState applyEvent(GatewayTurnEvent event) {
    if (failure != null) return this;
    if (turnId != null && turnId != event.turnId) {
      return _fail(GatewayTurnRecoveryFailure.turnMismatch);
    }
    final duplicate = eventsBySeq[event.seq];
    if (duplicate != null) {
      return duplicate.sameWireEvent(event)
          ? this
          : _fail(GatewayTurnRecoveryFailure.duplicateConflict);
    }
    if (event.seq <= lastSeq) {
      // A terminal snapshot may cover sequences whose individual events were
      // compacted. They are already materialized from the client's view.
      return this;
    }
    if (event.seq != lastSeq + 1) {
      return _fail(GatewayTurnRecoveryFailure.sequenceGap);
    }

    var nextStatus = status;
    if (event.type == 'turn.status') {
      final parsed = GatewayTurnStatus.fromWire(event.payload['status']);
      if (parsed == null) {
        return _fail(GatewayTurnRecoveryFailure.protocolViolation);
      }
      if (nextStatus != null && !_transitionAllowed(nextStatus, parsed)) {
        return _fail(GatewayTurnRecoveryFailure.invalidTransition);
      }
      nextStatus = parsed;
    }

    final nextEvents = Map<int, GatewayTurnEvent>.from(eventsBySeq)
      ..[event.seq] = event;
    return _copyWith(
      turnId: turnId ?? event.turnId,
      status: nextStatus,
      lastSeq: event.seq,
      eventsBySeq: Map<int, GatewayTurnEvent>.unmodifiable(nextEvents),
      ackUncertain: false,
    );
  }

  GatewayTurnRecoveryState applyReconcilePage(GatewayTurnReconcilePage page) {
    if (failure != null) return this;
    if (turnId != null && turnId != page.turnId) {
      return _fail(GatewayTurnRecoveryFailure.turnMismatch);
    }
    if (page.mode == GatewayTurnReconcileMode.snapshot) {
      final nextSnapshot = page.snapshot;
      if (nextSnapshot == null ||
          nextSnapshot.clientTurnId != clientTurnId ||
          nextSnapshot.lastSeq < lastSeq ||
          status != null &&
              !_snapshotTransitionAllowed(status!, nextSnapshot.status)) {
        return _fail(GatewayTurnRecoveryFailure.protocolViolation);
      }
      return _copyWith(
        turnId: nextSnapshot.turnId,
        status: nextSnapshot.status,
        lastSeq: nextSnapshot.lastSeq,
        eventsBySeq: const {},
        snapshot: nextSnapshot,
        ackUncertain: false,
        reconcilePending: false,
      );
    }

    var next = _copyWith(
      turnId: page.turnId,
      ackUncertain: false,
      reconcilePending: false,
    );
    for (final event in page.events) {
      next = next.applyEvent(event);
      if (next.failure != null) return next;
    }
    if (next.lastSeq != page.nextAfterSeq) {
      return next._fail(GatewayTurnRecoveryFailure.protocolViolation);
    }
    if (page.hasMore) {
      return next._copyWith(reconcilePending: true);
    }
    if (page.lastSeq != next.lastSeq) {
      return next._fail(GatewayTurnRecoveryFailure.protocolViolation);
    }
    if (next.status != null && !_transitionAllowed(next.status!, page.status)) {
      return next._fail(GatewayTurnRecoveryFailure.invalidTransition);
    }
    return next._copyWith(status: page.status, reconcilePending: false);
  }

  GatewayTurnRecoveryState failReconcile(GatewayTurnRecoveryFailure reason) {
    if (reason != GatewayTurnRecoveryFailure.turnUnknown &&
        reason != GatewayTurnRecoveryFailure.replayPruned &&
        reason != GatewayTurnRecoveryFailure.protocolViolation) {
      throw ArgumentError.value(reason, 'reason', 'invalid reconcile failure');
    }
    return _fail(reason);
  }

  GatewayTurnRecoveryState _fail(GatewayTurnRecoveryFailure reason) {
    return _copyWith(
      failure: reason,
      ackUncertain: false,
      reconcilePending: false,
    );
  }

  GatewayTurnRecoveryState _copyWith({
    String? turnId,
    GatewayTurnStatus? status,
    int? lastSeq,
    Map<int, GatewayTurnEvent>? eventsBySeq,
    GatewayTurnSnapshot? snapshot,
    bool? ackUncertain,
    bool? reconcilePending,
    GatewayTurnRecoveryFailure? failure,
  }) {
    return GatewayTurnRecoveryState._(
      clientTurnId: clientTurnId,
      turnId: turnId ?? this.turnId,
      status: status ?? this.status,
      lastSeq: lastSeq ?? this.lastSeq,
      eventsBySeq: eventsBySeq ?? this.eventsBySeq,
      snapshot: snapshot ?? this.snapshot,
      ackUncertain: ackUncertain ?? this.ackUncertain,
      reconcilePending: reconcilePending ?? this.reconcilePending,
      failure: failure ?? this.failure,
    );
  }
}

bool _transitionAllowed(GatewayTurnStatus from, GatewayTurnStatus to) {
  if (from == to) return true;
  if (from.isTerminal) return false;
  return switch (from) {
    GatewayTurnStatus.accepted =>
      to == GatewayTurnStatus.running ||
          to == GatewayTurnStatus.failed ||
          to == GatewayTurnStatus.interrupted,
    GatewayTurnStatus.running =>
      to == GatewayTurnStatus.waitingInput ||
          to == GatewayTurnStatus.completed ||
          to == GatewayTurnStatus.failed ||
          to == GatewayTurnStatus.interrupted,
    GatewayTurnStatus.waitingInput =>
      to == GatewayTurnStatus.running ||
          to == GatewayTurnStatus.failed ||
          to == GatewayTurnStatus.interrupted,
    GatewayTurnStatus.completed ||
    GatewayTurnStatus.failed ||
    GatewayTurnStatus.interrupted => false,
  };
}

bool _snapshotTransitionAllowed(GatewayTurnStatus from, GatewayTurnStatus to) {
  if (from == to) return true;
  if (from.isTerminal) return false;
  // A server-selected snapshot may skip replayed intermediate states but can
  // never regress to accepted or leave a terminal state.
  return to.isTerminal;
}

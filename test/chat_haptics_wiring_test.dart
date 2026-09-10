import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_coordinator.dart';
import 'package:hermes_android/core/services/gateway_turn_recovery.dart';
import 'package:hermes_android/core/services/haptics_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';
import 'support/recording_haptics_sink.dart';

const _clientTurnId = '123e4567-e89b-42d3-a456-426614174000';

/// Wires the haptic path ChatScreen actually uses when a turn settles.
///
/// The HapticsService unit test proves the service maps domain events to the
/// right kinds. These tests prove ChatScreen asks — the seam between "a turn
/// completed/failed" and "the phone vibrates" had no coverage.
void main() {
  late RecordingHapticsSink sink;
  late HapticsService haptics;
  late _CallbackCapturingTurnSession turnSession;

  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
    sink = RecordingHapticsSink();
    haptics = HapticsService(sink: sink);
    turnSession = _CallbackCapturingTurnSession();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: SavedConnection(
            id: 'haptics-fixture',
            label: 'Haptics fixture',
            host: 'haptics.fixture',
            port: 8642,
            apiKey: 'fixture-key',
          ),
          session: const Session(
            id: 'haptics-session',
            title: 'Roadmap',
            model: 'fixture-model',
            source: 'test',
            messageCount: 0,
            isActive: true,
            preview: '',
            startedAt: 1,
          ),
          testApiClient: ApiClient(
            baseUrl: 'http://haptics.fixture',
            apiKey: 'fixture-key',
            httpClient: _EmptyChatHttpClient(),
          ),
          testTurnApplicationSession: turnSession,
          testHaptics: haptics,
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
        ),
      ),
    );
    await tester.pump();
    // Let _initializeChat → _fetchMessages → _recoverPendingTurn register the
    // state callback before the test fires a settle.
    await tester.pumpAndSettle();
  }

  testWidgets('a completed turn fires the completion haptic', (tester) async {
    await pumpChat(tester);

    turnSession.settle(_state(GatewayRecoveryTurnStatus.completed));
    await tester.pump();

    expect(sink.events, [HermesHaptic.completion]);
  });

  testWidgets('a failed turn fires the failure haptic', (tester) async {
    await pumpChat(tester);

    turnSession.settle(_state(GatewayRecoveryTurnStatus.failed));
    await tester.pump();

    expect(sink.events, [HermesHaptic.failure]);
  });
}

GatewayTurnRecoveryState _state(GatewayRecoveryTurnStatus status) {
  final accepted = GatewayTurnRecoveryState.initial(clientTurnId: _clientTurnId)
      .markSubmissionStarted()
      .applyAck(
        const GatewayTurnAck(
          clientTurnId: _clientTurnId,
          turnId: 'server-turn',
          status: GatewayRecoveryTurnStatus.accepted,
          lastSeq: 0,
          created: true,
        ),
      );
  final page = GatewayTurnReconcilePage.fromWire(
    {
      'automatic_resubmit': false,
      'mode': 'snapshot',
      'earliest_seq': 1,
      'last_seq': 4,
      'next_after_seq': 4,
      'has_more': false,
      'snapshot': {
        'turn_id': 'server-turn',
        'client_turn_id': _clientTurnId,
        'status': status.wireValue,
        'last_seq': 4,
        'assistant': {
          'message_id': 'msg-1',
          'text': 'answer',
          'complete': true,
        },
        'attachment_manifest_digest':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'final_message_ref': 7,
      },
    },
    expectedAfterSeq: 0,
    expectedTurnId: 'server-turn',
    expectedClientTurnId: _clientTurnId,
  )!;
  return accepted.applyReconcilePage(page);
}

/// Turn session that keeps the state callback ChatScreen registers through
/// [recoverPending], so a test can fire it the way the real gateway would when
/// a turn settles.
class _CallbackCapturingTurnSession implements GatewayTurnApplicationSession {
  GatewayTurnStateCallback? _onState;

  void settle(GatewayTurnRecoveryState state) => _onState?.call(state);

  @override
  set onTurnSettled(GatewayTurnSettledCallback? callback) {}

  @override
  set onSessionBound(GatewayTurnSessionBoundCallback? callback) {}

  @override
  Future<List<GatewayTurnRecoveryState>> recoverPending(
    String localSessionId, {
    GatewayTurnStateCallback? onState,
  }) async {
    _onState = onState;
    return const <GatewayTurnRecoveryState>[];
  }

  @override
  Future<GatewayTurnRecoveryState> submit({
    required String localSessionId,
    required String text,
    List<GatewayTurnAttachmentReceipt> attachments = const [],
    GatewayTurnStateCallback? onState,
  }) => throw UnimplementedError();

  @override
  Future<void> close() async {}

  @override
  Future<void> detachAttachments({
    required String localSessionId,
    required Iterable<GatewayTurnAttachmentReceipt> attachments,
  }) => throw UnimplementedError();

  @override
  Future<GatewayTurnRecoveryState> interrupt({
    required String localSessionId,
    required String clientTurnId,
  }) => throw UnimplementedError();

  @override
  Future<GatewayTurnAttachmentReceipt> stageAttachment({
    required String localSessionId,
    required String clientAttachmentId,
    required String name,
    required String dataUrl,
    required int byteLength,
    required String mediaType,
    required GatewayTurnAttachmentKind kind,
  }) => throw UnimplementedError();
}

class _EmptyChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': <Object>[]}))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'error': 'unexpected request'}))),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}

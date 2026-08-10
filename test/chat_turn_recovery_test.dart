import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_coordinator.dart';
import 'package:hermes_android/core/services/gateway_turn_recovery.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

const _clientTurnId = '123e4567-e89b-42d3-a456-426614174000';
const _turnId = 'server-turn';
const _messageId = 'server-assistant-message';
const _manifestDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets('resume reconciles and materializes one authoritative response', (
    tester,
  ) async {
    final session = _FakeTurnSession([
      _acceptedState(),
      _completedState('Recovered after returning to Hermes'),
    ]);
    await _pumpChat(tester, turnSession: session);

    expect(session.recoverCount, 1);
    expect(session.submitCount, 0);
    expect(find.text('Recovering Hermes…'), findsOneWidget);

    for (final state in const <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pumpAndSettle();

    expect(session.recoverCount, 2);
    expect(session.submitCount, 0);
    expect(find.text('Recovered after returning to Hermes'), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('screen remount reuses owner and does not duplicate snapshot', (
    tester,
  ) async {
    final session = _FakeTurnSession([
      _acceptedState(),
      _completedState('Recovered exactly once'),
    ]);
    await _pumpChat(tester, turnSession: session);
    expect(session.recoverCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(session.closeCount, 0);

    await _pumpChat(tester, turnSession: session);
    expect(session.recoverCount, 2);
    expect(session.submitCount, 0);
    expect(find.text('Recovered exactly once'), findsOneWidget);
  });

  testWidgets('new v2 submit sends raw text exactly once', (tester) async {
    final session = _FakeTurnSession([
      const <GatewayTurnRecoveryState>[],
    ], submitResult: _completedState('Done'));
    await _pumpChat(tester, turnSession: session);

    await tester.enterText(find.byType(TextField), 'Raw user prompt');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(session.submitCount, 1);
    expect(session.submittedTexts, ['Raw user prompt']);
    expect(session.submittedTexts.single, isNot(contains('@file:')));
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('composer stays blocked until pending recovery is known', (
    tester,
  ) async {
    final recoveryGate = Completer<void>();
    final session = _FakeTurnSession([
      const <GatewayTurnRecoveryState>[],
    ], recoverGate: recoveryGate);
    await _pumpChat(tester, turnSession: session);

    final sendButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(find.text('Recovering Hermes…'), findsOneWidget);
    expect(sendButton.onPressed, isNull);
    expect(session.submitCount, 0);

    recoveryGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed,
      isNotNull,
    );
    expect(session.submitCount, 0);
  });

  testWidgets('definitive v2 rejection restores the editable prompt', (
    tester,
  ) async {
    final session = _FakeTurnSession(
      [const <GatewayTurnRecoveryState>[]],
      submitError: JsonRpcError(
        'prompt.submit',
        'Prompt rejected',
        reason: 'schema_violation',
      ),
    );
    await _pumpChat(tester, turnSession: session);

    await tester.enterText(find.byType(TextField), 'Fix this prompt');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    expect(session.submitCount, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Fix this prompt',
    );
    expect(
      find.text('Send failed: JsonRpcError(prompt.submit): Prompt rejected'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed,
      isNotNull,
    );
  });
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required _FakeTurnSession turnSession,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://recovery.fixture',
    apiKey: 'synthetic-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'recovery-fixture',
          label: 'Recovery fixture',
          host: 'recovery.fixture',
          port: 8642,
          apiKey: 'synthetic-key',
        ),
        session: const Session(
          id: 'recovery-session',
          title: 'Recovery chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testTurnApplicationSession: turnSession,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

GatewayTurnRecoveryState _acceptedState() =>
    GatewayTurnRecoveryState.initial(
      clientTurnId: _clientTurnId,
    ).markSubmissionStarted().applyAck(
      const GatewayTurnAck(
        clientTurnId: _clientTurnId,
        turnId: _turnId,
        status: GatewayRecoveryTurnStatus.accepted,
        lastSeq: 0,
        created: true,
      ),
    );

GatewayTurnRecoveryState _completedState(String text) {
  final page = GatewayTurnReconcilePage.fromWire(
    {
      'automatic_resubmit': false,
      'mode': 'snapshot',
      'earliest_seq': 1,
      'last_seq': 4,
      'next_after_seq': 4,
      'has_more': false,
      'snapshot': {
        'turn_id': _turnId,
        'client_turn_id': _clientTurnId,
        'status': 'completed',
        'last_seq': 4,
        'assistant': {'message_id': _messageId, 'text': text, 'complete': true},
        'attachment_manifest_digest': _manifestDigest,
        'final_message_ref': 7,
      },
    },
    expectedAfterSeq: 0,
    expectedTurnId: _turnId,
    expectedClientTurnId: _clientTurnId,
  )!;
  return _acceptedState().applyReconcilePage(page);
}

class _FakeTurnSession implements GatewayTurnApplicationSession {
  final List<Object> _recoverResults;
  final GatewayTurnRecoveryState? submitResult;
  final Object? submitError;
  final Completer<void>? recoverGate;
  int recoverCount = 0;
  int submitCount = 0;
  int closeCount = 0;
  final List<String> submittedTexts = [];

  _FakeTurnSession(
    this._recoverResults, {
    this.submitResult,
    this.submitError,
    this.recoverGate,
  });

  @override
  Future<List<GatewayTurnRecoveryState>> recoverPending(
    String localSessionId, {
    GatewayTurnStateCallback? onState,
  }) async {
    await recoverGate?.future;
    final index = recoverCount < _recoverResults.length
        ? recoverCount
        : _recoverResults.length - 1;
    recoverCount += 1;
    final value = _recoverResults[index];
    final states = value is GatewayTurnRecoveryState
        ? <GatewayTurnRecoveryState>[value]
        : (value as List<GatewayTurnRecoveryState>);
    for (final state in states) {
      onState?.call(state);
    }
    return states;
  }

  @override
  Future<GatewayTurnRecoveryState> submit({
    required String localSessionId,
    required String text,
    List<GatewayTurnAttachmentReceipt> attachments = const [],
    GatewayTurnStateCallback? onState,
  }) async {
    submitCount += 1;
    submittedTexts.add(text);
    if (submitError case final error?) throw error;
    final state = submitResult ?? _completedState('Done');
    onState?.call(state);
    return state;
  }

  @override
  Future<void> close() async => closeCount++;

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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/widgets/gateway_approval_dialog.dart';
import 'package:http/http.dart' as http;

import 'support/fake_voice_composer_adapter.dart';
import 'support/inert_turn_application_session.dart';

class _EmptyHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream.empty(), 200, request: request);
  }
}

void main() {
  testWidgets('reopens a pending approval dialog when the chat mounts with an '
      'unanswered gateway approval', (tester) async {
    final apiClient = ApiClient(
      baseUrl: 'http://gateway.test',
      apiKey: 'test-key',
      httpClient: _EmptyHttpClient(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: SavedConnection(
            id: 'gateway-approval-fixture',
            label: 'Gateway fixture',
            host: 'gateway.test',
            port: 8642,
            apiKey: 'test-key',
            desktopGatewayUrl: 'http://gateway.test:8642',
          ),
          session: const Session(
            id: 'approval-session',
            title: 'Approval chat',
            model: 'fixture-model',
            source: 'test',
            messageCount: 0,
            isActive: true,
            preview: '',
            startedAt: 1,
          ),
          testApiClient: apiClient,
          testTurnApplicationSession: InertTurnApplicationSession(),
          testPendingApprovalLoader: (sessionId) async => [
            {
              'command': 'rm -rf /tmp/fixture',
              'description': 'Remove a fixture directory',
              'choices': ['once', 'deny'],
            },
          ],
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The unanswered approval from the gateway's pending queue is replayed as
    // a dialog instead of leaving the turn silently blocked.
    expect(find.byType(GatewayApprovalDialog), findsOneWidget);
    expect(find.textContaining('rm -rf /tmp/fixture'), findsOneWidget);
  });

  testWidgets(
    'does not replay a dialog when the gateway has no pending approval',
    (tester) async {
      final apiClient = ApiClient(
        baseUrl: 'http://gateway.test',
        apiKey: 'test-key',
        httpClient: _EmptyHttpClient(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            connection: SavedConnection(
              id: 'gateway-approval-fixture',
              label: 'Gateway fixture',
              host: 'gateway.test',
              port: 8642,
              apiKey: 'test-key',
              desktopGatewayUrl: 'http://gateway.test:8642',
            ),
            session: const Session(
              id: 'approval-session',
              title: 'Approval chat',
              model: 'fixture-model',
              source: 'test',
              messageCount: 0,
              isActive: true,
              preview: '',
              startedAt: 1,
            ),
            testApiClient: apiClient,
            testTurnApplicationSession: InertTurnApplicationSession(),
            testPendingApprovalLoader: (sessionId) async => const [],
            testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(GatewayApprovalDialog), findsNothing);
    },
  );
}

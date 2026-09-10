import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
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
  Future<void> pumpChat(
    WidgetTester tester, {
    bool desktopGateway = false,
    Future<void> Function(Session session, String title)? onRename,
    Future<void> Function(Session session)? onDelete,
  }) async {
    final apiClient = ApiClient(
      baseUrl: 'http://gateway.test',
      apiKey: 'test-key',
      httpClient: _EmptyHttpClient(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: SavedConnection(
            id: 'appbar-fixture',
            label: 'Fixture',
            host: 'gateway.test',
            port: 8642,
            apiKey: 'test-key',
            desktopGatewayUrl: desktopGateway
                ? 'http://gateway.test:8642'
                : null,
          ),
          session: const Session(
            id: 'appbar-session',
            title: 'Rename me',
            model: 'fixture-model',
            source: 'test',
            messageCount: 0,
            isActive: true,
            preview: '',
            startedAt: 1,
          ),
          testApiClient: apiClient,
          testTurnApplicationSession: InertTurnApplicationSession(),
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
          onRenameSession: onRename,
          onDeleteSession: onDelete,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'offers Rename in the app-bar menu when a rename callback exists',
    (tester) async {
      await pumpChat(
        tester,
        desktopGateway: true,
        onRename: (_, _) async {},
        onDelete: (_) async {},
      );

      await tester.tap(find.byTooltip('Chat actions'));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    },
  );

  testWidgets('invokes rename with the typed title', (tester) async {
    String? renamedTo;
    await pumpChat(
      tester,
      desktopGateway: true,
      onRename: (_, title) async => renamedTo = title,
    );

    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Roadmap slice');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(renamedTo, 'Roadmap slice');
  });

  testWidgets('confirms before deleting from the app-bar menu', (tester) async {
    final deleted = <String>[];
    await pumpChat(
      tester,
      onDelete: (session) async => deleted.add(session.id),
    );

    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this conversation?'), findsOneWidget);
    expect(deleted, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, ['appbar-session']);
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/composer_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

const _connectionId = 'draft-fixture';
const _sessionId = 'draft-session';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets('a half-typed prompt survives dispose and reopen', (
    tester,
  ) async {
    final store = await ComposerDraftStore.open();

    await _pumpChat(tester, store: store);
    await tester.enterText(find.byType(TextField), 'half-typed prompt');
    // Tear the chat down before the debounce fires so the save-on-dispose
    // path is what persists the draft.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await _pumpChat(tester, store: store);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'half-typed prompt',
    );
  });

  testWidgets('auto-saves the draft while typing after the debounce', (
    tester,
  ) async {
    final store = await ComposerDraftStore.open();
    await _pumpChat(tester, store: store);

    await tester.enterText(find.byType(TextField), 'still typing');
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      store.read(connectionId: _connectionId, sessionId: _sessionId),
      'still typing',
    );
  });

  testWidgets('share text wins over a stored draft and clears it', (
    tester,
  ) async {
    final store = await ComposerDraftStore.open();
    await store.write(
      connectionId: _connectionId,
      sessionId: _sessionId,
      text: 'stale draft',
    );

    await _pumpChat(tester, store: store, initialComposerText: 'shared text');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'shared text',
    );
    expect(
      store.read(connectionId: _connectionId, sessionId: _sessionId),
      isNull,
    );
  });

  testWidgets('a successful send clears the stored draft', (tester) async {
    final store = await ComposerDraftStore.open();
    await _pumpChat(
      tester,
      store: store,
      remoteSubmit:
          ({required sessionId, required text, required onEvent}) async {},
    );

    await tester.enterText(find.byType(TextField), 'send me');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(
      store.read(connectionId: _connectionId, sessionId: _sessionId),
      isNull,
    );
  });
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required ComposerDraftStore store,
  String? initialComposerText,
  TestRemotePromptSubmit? remoteSubmit,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://draft.fixture',
    apiKey: 'test-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: _connectionId,
          label: 'Draft fixture',
          host: 'draft.fixture',
          port: 8642,
          apiKey: 'test-key',
        ),
        session: const Session(
          id: _sessionId,
          title: 'Draft chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        initialComposerText: initialComposerText,
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
        testComposerDraftStore: store,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

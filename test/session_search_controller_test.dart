import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ai_search_query_rewriter.dart';
import 'package:hermes_android/core/services/session_search_client.dart';
import 'package:hermes_android/core/services/session_search_controller.dart';
import 'package:hermes_android/core/services/session_search_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response jsonOk(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  SessionSearchController buildController({
    http.Response Function(http.Request)? searchHandler,
    http.Response Function(http.Request)? rewriteHandler,
    Future<Map<String, dynamic>> Function()? loadModelOptions,
  }) {
    return SessionSearchController(
      client: SessionSearchClient(
        baseUrl: 'http://dashboard.example:9119',
        headers: () async => const {'Cookie': 'session=abc'},
        httpClient: MockClient(
          (request) async => (searchHandler ?? (_) => jsonOk({'results': []}))(
            request,
          ),
        ),
      ),
      rewriter: AiSearchQueryRewriter(
        baseUrl: 'http://gateway.example:8642',
        apiKey: 'key-123',
        httpClient: MockClient(
          (request) async => (rewriteHandler ?? (_) => jsonOk({'query': 'x'}))(
            request,
          ),
        ),
      ),
      preferences: SessionSearchPreferences(preferences),
      connectionIdentity: 'conn-1',
      loadModelOptions:
          loadModelOptions ?? () async => {'providers': <dynamic>[]},
    );
  }

  test('defaults to local search and does not hit the network', () async {
    final controller = buildController();

    expect(controller.mode, SessionSearchMode.local);
    expect(controller.isServerMode, isFalse);
    expect(controller.isAiMode, isFalse);
  });

  test('restores a persisted server mode for the same connection', () async {
    final prefs = SessionSearchPreferences(preferences);
    await prefs.saveMode(
      connectionIdentity: 'conn-1',
      mode: SessionSearchMode.server,
    );

    final controller = buildController();
    controller.restore();

    expect(controller.mode, SessionSearchMode.server);
    expect(controller.isServerMode, isTrue);
  });

  test('server mode searches the query verbatim', () async {
    late String capturedQuery;
    final controller = buildController(
      searchHandler: (request) {
        capturedQuery = request.url.queryParameters['q']!;
        return jsonOk({
          'results': [
            {'id': 's1', 'title': 'Tuk-tuk'},
          ],
        });
      },
    );
    await controller.setMode(SessionSearchMode.server);

    final result = await controller.resolve('tuk tuk');

    expect(capturedQuery, 'tuk tuk');
    expect(result.hits.single.session.id, 's1');
    expect(result.rewrittenQuery, isNull);
  });

  test('AI mode rewrites the query before the full-text search', () async {
    late String rewriteBody;
    late String searchQuery;
    final controller = buildController(
      rewriteHandler: (request) {
        rewriteBody = request.body;
        return jsonOk({'query': 'electric vehicle ethiopia'});
      },
      searchHandler: (request) {
        searchQuery = request.url.queryParameters['q']!;
        return jsonOk({'results': []});
      },
    );
    await controller.setMode(SessionSearchMode.ai);
    await controller.setAiModel(
      const AiSearchModel(provider: 'openrouter', model: 'gpt-oss-20b'),
    );

    final result = await controller.resolve('my tuk-tuk project');

    expect(rewriteBody, contains('tuk-tuk'));
    expect(searchQuery, 'electric vehicle ethiopia');
    expect(result.rewrittenQuery, 'electric vehicle ethiopia');
  });

  test('AI mode without a selected model fails loudly', () async {
    final controller = buildController();
    await controller.setMode(SessionSearchMode.ai);

    await expectLater(
      controller.resolve('anything'),
      throwsA(isA<AiSearchRewriteException>()),
    );
  });

  test('offers only authenticated models with the recommendation first', () async {
    final controller = buildController(
      loadModelOptions: () async => {
        'providers': [
          {
            'slug': 'other',
            'authenticated': true,
            'models': ['big-model'],
          },
          {
            'slug': 'openrouter',
            'authenticated': true,
            'models': ['gpt-oss-20b'],
          },
          {
            'slug': 'locked',
            'authenticated': false,
            'models': ['secret-model'],
          },
        ],
      },
    );

    final models = await controller.availableModels();

    expect(models.map((m) => m.model), ['gpt-oss-20b', 'big-model']);
    expect(models.first.isRecommended, isTrue);
  });
}

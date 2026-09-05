import '../models/session_search_hit.dart';
import 'ai_search_query_rewriter.dart';
import 'connection_manager.dart';
import 'session_search_client.dart';
import 'session_search_preferences.dart';

/// The result of a network search: the matching sessions plus, in AI mode,
/// the rewritten query so the UI can show *what* the model actually searched
/// for instead of leaving the user wondering why those chats matched.
class SessionSearchResult {
  final List<SessionSearchHit> hits;

  /// The effective query after AI rewriting, when AI mode was used.
  final String? rewrittenQuery;

  const SessionSearchResult({required this.hits, this.rewrittenQuery});
}

/// Orchestrates the three chat-search modes for one saved connection.
///
/// Local search is handled by the caller (it filters the in-memory list
/// without touching the network); this controller owns the two network modes:
/// server full-text search and AI-assisted query rewriting. Keeping that
/// orchestration out of the widget layer lets it be unit-tested against a
/// mocked HTTP client without pumping a screen.
class SessionSearchController {
  SessionSearchController({
    required SessionSearchClient client,
    required AiSearchQueryRewriter rewriter,
    required SessionSearchPreferences preferences,
    required String connectionIdentity,
    required Future<Map<String, dynamic>> Function() loadModelOptions,
  }) : _searchClient = client,
       _aiRewriter = rewriter,
       _searchPreferences = preferences,
       _identity = connectionIdentity,
       _modelOptionsLoader = loadModelOptions;

  final SessionSearchClient _searchClient;
  final AiSearchQueryRewriter _aiRewriter;
  final SessionSearchPreferences _searchPreferences;
  final String _identity;
  final Future<Map<String, dynamic>> Function() _modelOptionsLoader;

  SessionSearchMode _mode = SessionSearchMode.local;
  AiSearchModel? _aiModel;

  SessionSearchMode get mode => _mode;
  AiSearchModel? get aiModel => _aiModel;
  bool get isServerMode => _mode != SessionSearchMode.local;
  bool get isAiMode => _mode == SessionSearchMode.ai;

  /// Restores the persisted mode and AI model for this connection. Local is
  /// the default when nothing was saved, so an upgrade never changes search
  /// behaviour until the user opts in.
  void restore() {
    _mode = _searchPreferences.readMode(connectionIdentity: _identity);
    _aiModel = _searchPreferences.readAiModel(connectionIdentity: _identity);
  }

  Future<void> setMode(SessionSearchMode mode) async {
    _mode = mode;
    await _searchPreferences.saveMode(
      connectionIdentity: _identity,
      mode: mode,
    );
  }

  Future<void> setAiModel(AiSearchModel model) async {
    _aiModel = model;
    await _searchPreferences.saveAiModel(
      connectionIdentity: _identity,
      selection: model,
    );
  }

  /// The authenticated provider/model pairs the user may pick for AI search,
  /// with the inexpensive GPT-OSS recommendation first.
  Future<List<AiSearchModel>> availableModels() async {
    final options = await _modelOptionsLoader();
    return AiSearchModel.configuredFromOptions(options);
  }

  /// Runs a network search for [query], honouring the current mode.
  ///
  /// AI mode first rewrites the query through the inexpensive model and then
  /// full-text searches the rewritten query; server mode searches the query
  /// verbatim. Throws [AiSearchRewriteException] when AI mode is selected
  /// without a model, and [SessionSearchException] on transport/auth failures —
  /// the caller decides whether to degrade to local search.
  Future<SessionSearchResult> resolve(String query) async {
    if (_mode != SessionSearchMode.ai) {
      return SessionSearchResult(hits: await _searchClient.search(query));
    }
    final model = _aiModel;
    if (model == null) {
      throw const AiSearchRewriteException(
        'Choose an AI search model before using AI search.',
      );
    }
    final rewritten = await _aiRewriter.rewrite(
      query: query,
      provider: model.provider,
      model: model.model,
    );
    return SessionSearchResult(
      hits: await _searchClient.search(rewritten),
      rewrittenQuery: rewritten,
    );
  }

  /// Builds a controller wired to one saved connection.
  ///
  /// The full-text client targets the connection's dashboard (which exposes
  /// `GET /api/sessions/search`); the AI rewriter targets the gateway's
  /// lightweight `/v1/search/rewrite` endpoint with the saved API key; and the
  /// model list comes from the gateway's model options.
  static Future<SessionSearchController> fromConnection(
    SavedConnection connection,
  ) async {
    final preferences = await SessionSearchPreferences.open();
    final dashboard = DashboardClient(
      host: connection.host,
      port: connection.dashboardPort,
      useHttps: connection.useHttps,
      pathPrefix: connection.dashboardPrefix ?? '',
      proxied: connection.dashboardProxied,
      username: connection.dashboardUsername,
      password: connection.dashboardPassword,
    );
    final api = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      pathPrefix: connection.gatewayPrefix ?? '',
    );
    final identity = '${connection.baseUrl}|'
        '${connection.gatewayPrefix ?? ''}|'
        '${connection.desktopGatewayUrl ?? ''}';
    return SessionSearchController(
      client: SessionSearchClient(
        baseUrl: dashboard.baseUrl,
        headers: dashboard.authHeaders,
      ),
      rewriter: AiSearchQueryRewriter(
        baseUrl: connection.baseUrl,
        pathPrefix: connection.gatewayPrefix ?? '',
        apiKey: connection.apiKey,
      ),
      preferences: preferences,
      connectionIdentity: identity,
      loadModelOptions: api.getModelOptions,
    );
  }
}

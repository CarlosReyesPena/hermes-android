import '../models/connection.dart';

/// A compact, portable representation of one saved connection.
///
/// The Add-connection dialog asks for a label, host, port, API key and up to
/// five dashboard fields. On a phone that is a lot of typing, and it is exactly
/// what "point the app at a new Hermes install" asks the user to do. This
/// codec turns a connection into a single paste-able `hermes://` URI and back,
/// so a fresh install can be configured from one string instead of eight fields.
///
/// The string carries secrets (the API key and dashboard password), so it is
/// treated like a shared password: only ever shown to the user for them to
/// copy, never logged or written to disk.
class ConnectionConfigString {
  static const String scheme = 'hermes';
  static const String _authority = 'connect';

  /// Builds the portable string for [connection].
  static String encode(SavedConnection connection) {
    final query = <String, String>{};
    if (connection.label.isNotEmpty) query['label'] = connection.label;
    if (connection.apiKey.isNotEmpty) query['key'] = connection.apiKey;
    if (connection.useHttps) query['https'] = 'true';
    if (connection.gatewayPrefix?.isNotEmpty == true) {
      query['gateway_prefix'] = connection.gatewayPrefix!;
    }
    if (connection.dashboardPrefix?.isNotEmpty == true) {
      query['dashboard_prefix'] = connection.dashboardPrefix!;
    }
    if (connection.dashboardProxied) query['dashboard_proxied'] = 'true';
    if (connection.desktopGatewayUrl?.isNotEmpty == true) {
      query['desktop_gateway_url'] = connection.desktopGatewayUrl!;
    }
    if (connection.dashboardPortOverride != null) {
      query['dashboard_port'] = '${connection.dashboardPortOverride}';
    }
    if (connection.dashboardUsername?.isNotEmpty == true) {
      query['dashboard_username'] = connection.dashboardUsername!;
    }
    if (connection.dashboardPassword?.isNotEmpty == true) {
      query['dashboard_password'] = connection.dashboardPassword!;
    }

    final uri = Uri(
      scheme: scheme,
      host: connection.host,
      port: connection.port,
      path: _authority,
      queryParameters: query.isEmpty ? null : query,
    );
    return uri.toString();
  }

  /// Parses a string produced by [encode].
  ///
  /// Returns null when the string is not a Hermes connection config at all, so
  /// the caller can say "that isn't a connection" instead of guessing. A string
  /// with a recognisable scheme but a missing host or port throws
  /// [FormatException], so a malformed config never silently produces a
  /// half-built connection.
  static SavedConnection? decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (_) {
      return null;
    }

    if (uri.scheme != scheme) return null;
    if (uri.host.isEmpty) {
      throw const FormatException('A Hermes connection needs a host.');
    }
    final port = uri.hasPort && uri.port > 0 ? uri.port : 8642;
    final query = uri.queryParameters;

    return SavedConnection(
      id: '',
      label: (query['label'] ?? '').trim().isEmpty
          ? 'Hermes'
          : query['label']!.trim(),
      host: uri.host,
      port: port,
      apiKey: query['key'] ?? '',
      useHttps: (query['https'] ?? '') == 'true' || uri.scheme == 'https',
      gatewayPrefix: _nonEmpty(query['gateway_prefix']),
      dashboardPrefix: _nonEmpty(query['dashboard_prefix']),
      dashboardProxied: (query['dashboard_proxied'] ?? '') == 'true',
      desktopGatewayUrl: _nonEmpty(query['desktop_gateway_url']),
      dashboardPortOverride: int.tryParse(query['dashboard_port'] ?? ''),
      dashboardUsername: _nonEmpty(query['dashboard_username']),
      dashboardPassword: _nonEmpty(query['dashboard_password']),
    );
  }

  static String? _nonEmpty(String? value) {
    final text = value?.trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}

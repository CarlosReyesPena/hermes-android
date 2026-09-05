import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_config_string.dart';

SavedConnection _connection({
  String label = 'Miniserver',
  String host = 'hermes-miniserver.example.ts.net',
  int port = 8642,
  String apiKey = 'secret-key',
  bool useHttps = false,
  String? gatewayPrefix,
  String? dashboardPrefix,
  bool dashboardProxied = false,
  String? desktopGatewayUrl,
  int? dashboardPortOverride,
  String? dashboardUsername,
  String? dashboardPassword,
}) => SavedConnection(
  id: 'c1',
  label: label,
  host: host,
  port: port,
  apiKey: apiKey,
  useHttps: useHttps,
  gatewayPrefix: gatewayPrefix,
  dashboardPrefix: dashboardPrefix,
  dashboardProxied: dashboardProxied,
  desktopGatewayUrl: desktopGatewayUrl,
  dashboardPortOverride: dashboardPortOverride,
  dashboardUsername: dashboardUsername,
  dashboardPassword: dashboardPassword,
);

void main() {
  test('round-trips every connection field through one string', () {
    final original = _connection(
      label: 'Miniserver',
      host: 'hermes-miniserver.example.ts.net',
      port: 8642,
      apiKey: 'abc/+=123',
      gatewayPrefix: '/gateway',
      dashboardPrefix: '/dash',
      dashboardProxied: true,
      desktopGatewayUrl: 'http://hermes-miniserver.example.ts.net:9120',
      dashboardPortOverride: 9120,
      dashboardUsername: 'carlos',
      dashboardPassword: 'pw!@#',
    );

    final encoded = ConnectionConfigString.encode(original);
    final decoded = ConnectionConfigString.decode(encoded);

    expect(decoded, isNotNull);
    expect(decoded!.host, original.host);
    expect(decoded.port, original.port);
    expect(decoded.label, original.label);
    expect(decoded.apiKey, original.apiKey);
    expect(decoded.gatewayPrefix, original.gatewayPrefix);
    expect(decoded.dashboardPrefix, original.dashboardPrefix);
    expect(decoded.dashboardProxied, original.dashboardProxied);
    expect(decoded.desktopGatewayUrl, original.desktopGatewayUrl);
    expect(decoded.dashboardPortOverride, original.dashboardPortOverride);
    expect(decoded.dashboardUsername, original.dashboardUsername);
    expect(decoded.dashboardPassword, original.dashboardPassword);
  });

  test('keeps the API key intact across the URL-encoding boundary', () {
    final key = 'K3y+with/special&=chars?and spaces';
    final encoded = ConnectionConfigString.encode(_connection(apiKey: key));
    final decoded = ConnectionConfigString.decode(encoded);
    expect(decoded!.apiKey, key);
  });

  test('returns null for a non-Hermes string', () {
    expect(ConnectionConfigString.decode('https://example.com'), isNull);
    expect(ConnectionConfigString.decode(''), isNull);
    expect(ConnectionConfigString.decode('not a uri'), isNull);
  });

  test('throws a FormatException when the host is missing', () {
    expect(
      () => ConnectionConfigString.decode('hermes:///connect?key=x'),
      throwsFormatException,
    );
  });

  test('defaults the port to 8642 when omitted', () {
    final decoded = ConnectionConfigString.decode('hermes://host/connect');
    expect(decoded!.port, 8642);
  });

  test('a blank label falls back to Hermes', () {
    final decoded = ConnectionConfigString.decode('hermes://host/connect');
    expect(decoded!.label, 'Hermes');
  });

  test('useHttps is derived from the https flag', () {
    final decoded = ConnectionConfigString.decode(
      'hermes://host/connect?https=true',
    );
    expect(decoded!.useHttps, isTrue);
  });
}

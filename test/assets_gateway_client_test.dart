/// The Assets gateway client: a thin typed wrapper over the `assets.list`
/// JSON-RPC method, mirroring `ProjectsGatewayClient` so an older gateway
/// degrades to a labelled compatibility notice instead of an error screen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/assets_gateway_client.dart';
import 'package:hermes_android/core/services/capability_registry.dart';
import 'package:hermes_android/core/services/ws_client.dart';

/// Records the JSON-RPC calls a test makes and replays canned envelopes.
class _RecordingRpc {
  final List<({String method, Map<String, dynamic> params})> calls = [];
  final List<Map<String, dynamic>> responses;

  _RecordingRpc(this.responses);

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method: method, params: params));
    if (responses.isEmpty) {
      throw StateError('no canned response for $method');
    }
    return responses.removeAt(0);
  }
}

Map<String, dynamic> _ok(Map<String, dynamic> result) => {
  'jsonrpc': '2.0',
  'id': 1,
  'result': result,
};

Map<String, dynamic> _error(int code, String message) => {
  'jsonrpc': '2.0',
  'id': 1,
  'error': {'code': code, 'message': message},
};

Map<String, dynamic> _asset({
  String name = 'shot.png',
  String path = '/home/carlos/.hermes/media/shot.png',
  String kind = 'image',
  String mimeType = 'image/png',
}) => {
  'name': name,
  'path': path,
  'kind': kind,
  'mime_type': mimeType,
  'size': 24,
  'modified_at': 1750000000,
  'project_id': null,
};

void main() {
  group('AssetsGatewayClient', () {
    test('lists global assets through the native assets.list RPC', () async {
      final rpc = _RecordingRpc([
        _ok({
          'assets': [_asset()],
          'project_id': null,
        }),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      final view = await client.list();

      expect(rpc.calls.single.method, 'assets.list');
      expect(rpc.calls.single.params, isEmpty);
      expect(view.assets.single.name, 'shot.png');
      expect(view.projectId, isNull);
    });

    test('scopes the listing to one project', () async {
      final rpc = _RecordingRpc([
        _ok({
          'assets': [_asset()],
          'project_id': 'p1',
        }),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      final view = await client.list(projectId: 'p1');

      expect(rpc.calls.single.params, {'project_id': 'p1'});
      expect(view.projectId, 'p1');
    });

    test('forwards a limit when given', () async {
      final rpc = _RecordingRpc([
        _ok({'assets': const [], 'project_id': null}),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      await client.list(limit: 25);

      expect(rpc.calls.single.params, {'limit': 25});
    });

    test('reports an unsupported gateway instead of crashing', () async {
      final rpc = _RecordingRpc([
        _error(-32601, 'unknown method: assets.list'),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      await expectLater(
        client.list(),
        throwsA(isA<AssetsUnsupportedException>()),
      );
    });

    test(
      'caches the unsupported verdict without repeating the probe',
      () async {
        final rpc = _RecordingRpc([
          _error(-32601, 'unknown method: assets.list'),
        ]);
        final client = AssetsGatewayClient(rpc.call);

        await expectLater(
          client.list(),
          throwsA(isA<AssetsUnsupportedException>()),
        );
        await expectLater(
          client.list(),
          throwsA(isA<AssetsUnsupportedException>()),
        );
        expect(rpc.calls, hasLength(1));
      },
    );

    test('surfaces a real assets error as a JsonRpcError', () async {
      final rpc = _RecordingRpc([_error(5062, 'no such project')]);
      final client = AssetsGatewayClient(rpc.call);

      await expectLater(
        client.list(projectId: 'missing'),
        throwsA(
          isA<JsonRpcError>()
              .having((e) => e.code, 'code', 5062)
              .having((e) => e.method, 'method', 'assets.list'),
        ),
      );
    });

    test('a transport failure is not treated as unsupported', () async {
      var calls = 0;
      final client = AssetsGatewayClient((method, params) async {
        calls++;
        throw JsonRpcError(
          method,
          'Desktop gateway connection closed',
          reason: 'connection_closed',
        );
      });

      await expectLater(client.list(), throwsA(isA<JsonRpcError>()));
      await expectLater(client.list(), throwsA(isA<JsonRpcError>()));
      expect(calls, 2);
    });

    test(
      'reports a successful call to the shared capability registry',
      () async {
        final registry = CapabilityRegistry();
        final rpc = _RecordingRpc([
          _ok({'assets': const [], 'project_id': null}),
        ]);
        final client = AssetsGatewayClient(rpc.call, capabilities: registry);

        await client.list();

        expect(registry.supportFor('assets.list'), CapabilitySupport.supported);
      },
    );

    test('works without a registry', () async {
      final rpc = _RecordingRpc([
        _ok({'assets': const [], 'project_id': null}),
      ]);
      final client = AssetsGatewayClient(rpc.call);

      await expectLater(client.list(), completes);
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';

/// Contract for the write half of the file explorer: create folder, import
/// (upload), delete, rename/move and copy.
void main() {
  DashboardClient dashboardWith(
    Future<http.Response> Function(http.Request request) handler,
  ) => DashboardClient(
    host: 'hermes.local',
    port: 9119,
    proxied: true,
    httpClient: MockClient(handler),
  );

  test('creates a directory at the requested path', () async {
    Map<String, dynamic>? sent;
    final dashboard = dashboardWith((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/fs/mkdir');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'ok': true, 'path': '/srv/project/notes'}),
        200,
      );
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await client.createDirectory('/srv/project/notes');

    expect(sent!['path'], '/srv/project/notes');
    client.close();
  });

  test('uploads bytes as a base64 data URL', () async {
    Map<String, dynamic>? sent;
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/upload');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await client.uploadFile('/srv/project/photo.png', const [
      1,
      2,
      3,
    ], mimeType: 'image/png');

    expect(sent!['path'], '/srv/project/photo.png');
    expect(
      sent!['data_url'],
      'data:image/png;base64,${base64Encode(const [1, 2, 3])}',
    );
    client.close();
  });

  test('deletes a directory recursively', () async {
    Map<String, dynamic>? sent;
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/delete');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await client.deleteEntry('/srv/project/build', recursive: true);

    expect(sent!['path'], '/srv/project/build');
    expect(sent!['recursive'], isTrue);
    client.close();
  });

  test('renames an entry by moving it within its parent directory', () async {
    Map<String, dynamic>? sent;
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/move');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await client.rename('/srv/project/old.txt', 'new.txt');

    expect(sent!['source'], '/srv/project/old.txt');
    expect(sent!['destination'], '/srv/project/new.txt');
    client.close();
  });

  test('moves an entry into a destination directory', () async {
    Map<String, dynamic>? sent;
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/move');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await client.moveInto('/srv/project/a/note.txt', '/srv/project/b');

    expect(sent!['source'], '/srv/project/a/note.txt');
    expect(sent!['destination'], '/srv/project/b/note.txt');
    client.close();
  });

  test('copies an entry into a destination directory', () async {
    Map<String, dynamic>? sent;
    final dashboard = dashboardWith((request) async {
      expect(request.url.path, '/api/fs/copy');
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await client.copyInto('/srv/project/a/note.txt', '/srv/project/b');

    expect(sent!['source'], '/srv/project/a/note.txt');
    expect(sent!['destination'], '/srv/project/b/note.txt');
    client.close();
  });

  test('surfaces a readable error when the server rejects a write', () async {
    final dashboard = dashboardWith((request) async {
      return http.Response(jsonEncode({'detail': 'File already exists'}), 409);
    });
    final client = RemoteFilesClient(dashboard: dashboard);

    await expectLater(
      client.createDirectory('/srv/project/notes'),
      throwsA(isA<Exception>()),
    );
    client.close();
  });
}

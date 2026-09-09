import 'dart:convert';
import 'dart:typed_data';

import 'connection_manager.dart';
import 'desktop_gateway_client.dart';

class RemoteDirectory {
  final String path;
  final String? branch;

  const RemoteDirectory({required this.path, this.branch});
}

class RemoteFileEntry {
  final String name;
  final String path;
  final bool isDirectory;

  /// Byte size for files; 0 for directories.
  final int size;

  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
  });

  factory RemoteFileEntry.fromJson(Map<String, dynamic> json) =>
      RemoteFileEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isDirectory: json['isDirectory'] == true,
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

class RemoteTextPreview {
  final String path;
  final String text;
  final String language;
  final String mimeType;
  final int byteSize;
  final bool binary;
  final bool truncated;

  const RemoteTextPreview({
    required this.path,
    required this.text,
    required this.language,
    required this.mimeType,
    required this.byteSize,
    required this.binary,
    required this.truncated,
  });

  factory RemoteTextPreview.fromJson(Map<String, dynamic> json) =>
      RemoteTextPreview(
        path: json['path'] as String? ?? '',
        text: json['text'] as String? ?? '',
        language: json['language'] as String? ?? 'text',
        mimeType: json['mimeType'] as String? ?? 'text/plain',
        byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
        binary: json['binary'] == true,
        truncated: json['truncated'] == true,
      );
}

class RemoteFileDownload {
  final String filename;
  final Uint8List bytes;

  RemoteFileDownload({required this.filename, required List<int> bytes})
    : bytes = Uint8List.fromList(bytes);
}

/// Joins a parent directory and a child name without doubling separators.
String remoteJoin(String directory, String name) {
  final base = directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  return '$base/$name';
}

/// Returns the parent directory of [path] (the path itself when it is a root).
String remoteParentOf(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return index == 0 ? '/' : trimmed;
  return trimmed.substring(0, index);
}

/// Returns the final segment of [path].
String remoteBasename(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf('/');
  return index < 0 ? trimmed : trimmed.substring(index + 1);
}

abstract class RemoteFilesDataSource {
  Future<RemoteDirectory> defaultDirectory();
  Future<List<RemoteFileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  });
  Future<RemoteTextPreview> readText(String path);
  Future<RemoteFileDownload> download(String path);
}

/// Optional write capability. Read-only sources remain valid; the Files UI
/// exposes mutation actions only when its source implements this contract.
abstract class RemoteFilesWritableDataSource {
  Future<void> createDirectory(String path);
  Future<void> uploadFile(
    String path,
    List<int> bytes, {
    String mimeType,
    bool overwrite,
  });
  Future<void> deleteEntry(String path, {bool recursive});
  Future<void> rename(String path, String newName);
  Future<void> moveInto(String source, String destinationDirectory);
  Future<void> copyInto(String source, String destinationDirectory);
}

class RemoteFilesClient
    implements RemoteFilesDataSource, RemoteFilesWritableDataSource {
  final DashboardClient dashboard;

  RemoteFilesClient({required this.dashboard});

  factory RemoteFilesClient.fromConnection(SavedConnection connection) {
    final baseUri = Uri.parse(
      DesktopGatewayClient.normalizedGatewayBaseUrl(connection),
    );
    return RemoteFilesClient(
      dashboard: DashboardClient(
        host: baseUri.host,
        port: baseUri.port,
        useHttps: baseUri.scheme == 'https',
        pathPrefix: baseUri.path == '/' ? '' : baseUri.path,
        username: connection.dashboardUsername,
        password: connection.dashboardPassword,
      ),
    );
  }

  @override
  Future<RemoteDirectory> defaultDirectory() async {
    final data = await dashboard.apiGet('fs/default-cwd');
    return RemoteDirectory(
      path: data['cwd'] as String? ?? '/',
      branch: data['branch'] as String?,
    );
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  }) async {
    final data = await dashboard.apiGet(
      'fs/list',
      queryParameters: {'path': path},
    );
    final error = data['error'] as String?;
    if (error != null && error.isNotEmpty) {
      throw Exception('Could not read directory: $error');
    }
    final entries = (data['entries'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RemoteFileEntry.fromJson)
        .where((entry) => showHidden || !entry.name.startsWith('.'))
        .toList();
    entries.sort(
      (left, right) => left.isDirectory == right.isDirectory
          ? left.name.toLowerCase().compareTo(right.name.toLowerCase())
          : left.isDirectory
          ? -1
          : 1,
    );
    return entries;
  }

  @override
  Future<RemoteTextPreview> readText(String path) async {
    final data = await dashboard.apiGet(
      'fs/read-text',
      queryParameters: {'path': path},
    );
    return RemoteTextPreview.fromJson(data);
  }

  @override
  Future<RemoteFileDownload> download(String path) async {
    final response = await dashboard.apiGetBytes(
      'fs/download',
      queryParameters: {'path': path},
    );
    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp(
      r'''filename\*?=(?:UTF-8''|["'])?([^"';]+)''',
      caseSensitive: false,
    ).firstMatch(disposition);
    return RemoteFileDownload(
      filename: match?.group(1)?.trim() ?? path.split('/').last,
      bytes: response.bodyBytes,
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    await dashboard.apiPost('fs/mkdir', body: {'path': path});
  }

  @override
  Future<void> uploadFile(
    String path,
    List<int> bytes, {
    String mimeType = 'application/octet-stream',
    bool overwrite = false,
  }) async {
    await dashboard.apiPost(
      'fs/upload',
      body: {
        'path': path,
        'data_url': 'data:$mimeType;base64,${base64Encode(bytes)}',
        'overwrite': overwrite,
      },
    );
  }

  @override
  Future<void> deleteEntry(String path, {bool recursive = false}) async {
    await dashboard.apiPost(
      'fs/delete',
      body: {'path': path, 'recursive': recursive},
    );
  }

  @override
  Future<void> rename(String path, String newName) async {
    await dashboard.apiPost(
      'fs/move',
      body: {
        'source': path,
        'destination': remoteJoin(remoteParentOf(path), newName),
      },
    );
  }

  @override
  Future<void> moveInto(String source, String destinationDirectory) async {
    await dashboard.apiPost(
      'fs/move',
      body: {
        'source': source,
        'destination': remoteJoin(destinationDirectory, remoteBasename(source)),
      },
    );
  }

  @override
  Future<void> copyInto(String source, String destinationDirectory) async {
    await dashboard.apiPost(
      'fs/copy',
      body: {
        'source': source,
        'destination': remoteJoin(destinationDirectory, remoteBasename(source)),
      },
    );
  }

  void close() => dashboard.close();
}

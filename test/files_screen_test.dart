import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/files_screen.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

class _FakeFilesDataSource implements RemoteFilesDataSource {
  Object? listError;
  final openedDirectories = <String>[];

  @override
  Future<RemoteDirectory> defaultDirectory() async =>
      const RemoteDirectory(path: '/srv/project', branch: 'main');

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    openedDirectories.add(path);
    if (listError != null) throw listError!;
    if (path == '/srv/project/lib') {
      return const [
        RemoteFileEntry(
          name: 'main.dart',
          path: '/srv/project/lib/main.dart',
          isDirectory: false,
        ),
      ];
    }
    return const [
      RemoteFileEntry(name: 'lib', path: '/srv/project/lib', isDirectory: true),
      RemoteFileEntry(
        name: 'README.md',
        path: '/srv/project/README.md',
        isDirectory: false,
      ),
    ];
  }

  @override
  Future<RemoteTextPreview> readText(String path) async => RemoteTextPreview(
    path: path,
    text: '# Hermes\nRemote preview',
    language: 'markdown',
    mimeType: 'text/markdown',
    byteSize: 23,
    binary: false,
    truncated: false,
  );

  @override
  Future<RemoteFileDownload> download(String path) async =>
      RemoteFileDownload(filename: path.split('/').last, bytes: [1, 2, 3]);
}

Future<void> _pump(
  WidgetTester tester,
  _FakeFilesDataSource source, {
  ValueChanged<String>? onAddToChat,
  Future<void> Function(RemoteFileDownload download)? onSaveDownload,
}) => tester.pumpWidget(
  MaterialApp(
    theme: hermesTheme(Brightness.dark),
    home: FilesScreen(
      files: source,
      onAddToChat: onAddToChat,
      onSaveDownload: onSaveDownload,
    ),
  ),
);

void main() {
  testWidgets('shows the server root and navigates into a directory', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    expect(find.text('Files'), findsOneWidget);
    expect(find.text('/srv/project'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);

    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();

    expect(source.openedDirectories, contains('/srv/project/lib'));
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('previews text and adds its server reference to chat', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    final references = <String>[];
    await _pump(tester, source, onAddToChat: references.add);
    await tester.pumpAndSettle();

    await tester.tap(find.text('README.md'));
    await tester.pumpAndSettle();

    expect(find.text('# Hermes\nRemote preview'), findsOneWidget);
    expect(find.text('markdown'), findsOneWidget);
    await tester.tap(find.text('Add to chat'));
    await tester.pumpAndSettle();

    expect(references, ['/srv/project/README.md']);
  });

  testWidgets('downloads the selected file through the platform seam', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    final downloads = <RemoteFileDownload>[];
    await _pump(
      tester,
      source,
      onSaveDownload: (download) async => downloads.add(download),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('README.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(downloads.single.filename, 'README.md');
    expect(downloads.single.bytes, [1, 2, 3]);
  });

  testWidgets('opens directly at an initial path, skipping the default cwd', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await tester.pumpWidget(
      MaterialApp(
        theme: hermesTheme(Brightness.dark),
        home: FilesScreen(files: source, initialPath: '/srv/project/lib'),
      ),
    );
    await tester.pumpAndSettle();

    // It must not ask for the default cwd, and must list the initial folder.
    expect(source.openedDirectories, isNot(contains('/srv/project')));
    expect(source.openedDirectories, contains('/srv/project/lib'));
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('shows a retryable error when the directory cannot load', (
    tester,
  ) async {
    final source = _FakeFilesDataSource()..listError = Exception('offline');
    await _pump(tester, source);
    await tester.pumpAndSettle();

    expect(find.text('Could not load files'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('renders an inline image preview for image files', (
    tester,
  ) async {
    final source = _ImageFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.tap(find.text('screenshot.png'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    // The binary "download to open" fallback must not appear for images.
    expect(find.textContaining('Binary preview is unavailable'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('keeps the download affordance for non-image binaries', (
    tester,
  ) async {
    final source = _BinaryFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.tap(find.text('archive.bin'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Binary preview is unavailable'),
      findsOneWidget,
    );
    expect(find.text('Download'), findsOneWidget);
  });
}

class _ImageFilesDataSource extends _FakeFilesDataSource {
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => const [
    RemoteFileEntry(
      name: 'screenshot.png',
      path: '/srv/project/screenshot.png',
      isDirectory: false,
    ),
  ];

  @override
  Future<RemoteTextPreview> readText(String path) async => RemoteTextPreview(
    path: path,
    text: '',
    language: 'image',
    mimeType: 'image/png',
    byteSize: 68,
    binary: true,
    truncated: false,
  );
}

class _BinaryFilesDataSource extends _FakeFilesDataSource {
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => const [
    RemoteFileEntry(
      name: 'archive.bin',
      path: '/srv/project/archive.bin',
      isDirectory: false,
    ),
  ];

  @override
  Future<RemoteTextPreview> readText(String path) async => RemoteTextPreview(
    path: path,
    text: '',
    language: 'binary',
    mimeType: 'application/octet-stream',
    byteSize: 12,
    binary: true,
    truncated: false,
  );
}

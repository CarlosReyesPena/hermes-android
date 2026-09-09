import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/files_screen.dart';
import 'package:hermes_android/core/services/remote_files_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

class _FakeFilesDataSource
    implements RemoteFilesDataSource, RemoteFilesWritableDataSource {
  Object? listError;
  final openedDirectories = <String>[];
  final createdDirectories = <String>[];
  final deletedEntries = <String>[];
  final renamedEntries = <(String, String)>[];
  final movedEntries = <(String, String)>[];
  final copiedEntries = <(String, String)>[];
  final uploadedEntries = <(String, List<int>, String)>[];

  @override
  Future<void> createDirectory(String path) async =>
      createdDirectories.add(path);

  @override
  Future<void> deleteEntry(String path, {bool recursive = false}) async =>
      deletedEntries.add(path);

  @override
  Future<void> rename(String path, String newName) async =>
      renamedEntries.add((path, newName));

  @override
  Future<void> moveInto(String source, String destinationDirectory) async =>
      movedEntries.add((source, destinationDirectory));

  @override
  Future<void> copyInto(String source, String destinationDirectory) async =>
      copiedEntries.add((source, destinationDirectory));

  @override
  Future<void> uploadFile(
    String path,
    List<int> bytes, {
    String mimeType = 'application/octet-stream',
    bool overwrite = false,
  }) async => uploadedEntries.add((path, bytes, mimeType));

  @override
  Future<RemoteDirectory> defaultDirectory() async =>
      const RemoteDirectory(path: '/srv/project', branch: 'main');

  @override
  Future<List<RemoteFileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  }) async {
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
  Future<void> Function(RemoteFileDownload download)? onShareDownload,
  Future<List<LocalUpload>> Function()? onPickUploads,
}) => tester.pumpWidget(
  MaterialApp(
    theme: hermesTheme(Brightness.dark),
    home: FilesScreen(
      files: source,
      onAddToChat: onAddToChat,
      onSaveDownload: onSaveDownload,
      onShareDownload: onShareDownload,
      onPickUploads: onPickUploads,
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

  testWidgets('offers file actions directly from the directory row', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    final downloads = <RemoteFileDownload>[];
    final shares = <RemoteFileDownload>[];
    final references = <String>[];
    await _pump(
      tester,
      source,
      onAddToChat: references.add,
      onSaveDownload: (download) async => downloads.add(download),
      onShareDownload: (download) async => shares.add(download),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('file-actions-/srv/project/README.md')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Add to chat'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(shares.single.filename, 'README.md');

    await tester.tap(
      find.byKey(const Key('file-actions-/srv/project/README.md')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to chat'));
    await tester.pumpAndSettle();
    expect(references, ['/srv/project/README.md']);

    await tester.tap(
      find.byKey(const Key('file-actions-/srv/project/README.md')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(downloads.single.filename, 'README.md');
  });

  testWidgets('folder rows do not offer file-only actions', (tester) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('file-actions-/srv/project/lib')),
      findsNothing,
    );
  });

  testWidgets('toggles hidden files with the visibility button', (
    tester,
  ) async {
    final source = _HiddenFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    // Hidden entries are filtered out by default.
    expect(find.text('.secret'), findsNothing);
    expect(find.text('README.md'), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle-hidden')));
    await tester.pumpAndSettle();

    expect(find.text('.secret'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
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

  testWidgets('creates a folder in the current directory', (tester) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Invoices');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(source.createdDirectories, ['/srv/project/Invoices']);
  });

  testWidgets('imports multiple local files into the current directory', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await _pump(
      tester,
      source,
      onPickUploads: () async => const [
        LocalUpload(name: 'one.txt', bytes: [1], mimeType: 'text/plain'),
        LocalUpload(name: 'two.jpg', bytes: [2], mimeType: 'image/jpeg'),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Import files'));
    await tester.pumpAndSettle();

    expect(source.uploadedEntries.map((upload) => upload.$1), [
      '/srv/project/one.txt',
      '/srv/project/two.jpg',
    ]);
    expect(source.uploadedEntries.map((upload) => upload.$2.single), [1, 2]);
    expect(source.uploadedEntries.map((upload) => upload.$3), [
      'text/plain',
      'image/jpeg',
    ]);
  });

  testWidgets('long press enters multi-selection for folders and files', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('lib'));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(find.byTooltip('Cut'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);

    await tester.tap(find.text('README.md'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('deletes every selected file or folder after confirmation', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('lib'));
    await tester.tap(find.text('README.md'));
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete 2 items?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(
      source.deletedEntries,
      containsAll(['/srv/project/lib', '/srv/project/README.md']),
    );
  });

  testWidgets('renames the single selected entry', (tester) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('README.md'));
    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'GUIDE.md');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(source.renamedEntries, [('/srv/project/README.md', 'GUIDE.md')]);
  });

  testWidgets('copies a selected entry into a navigated destination folder', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('README.md'));
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Paste here'), findsOneWidget);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Paste here'));
    await tester.pumpAndSettle();

    expect(source.copiedEntries, [
      ('/srv/project/README.md', '/srv/project/lib'),
    ]);
  });

  testWidgets('cuts a selected entry into a navigated destination folder', (
    tester,
  ) async {
    final source = _FakeFilesDataSource();
    await _pump(tester, source);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('README.md'));
    await tester.tap(find.byTooltip('Cut'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Paste here'));
    await tester.pumpAndSettle();

    expect(source.movedEntries, [
      ('/srv/project/README.md', '/srv/project/lib'),
    ]);
    expect(find.byTooltip('Paste here'), findsNothing);
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
  Future<List<RemoteFileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  }) async => const [
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
  Future<List<RemoteFileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  }) async => const [
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

class _HiddenFilesDataSource extends _FakeFilesDataSource {
  @override
  Future<List<RemoteFileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  }) async {
    final all = const [
      RemoteFileEntry(
        name: '.secret',
        path: '/srv/project/.secret',
        isDirectory: false,
      ),
      RemoteFileEntry(
        name: 'README.md',
        path: '/srv/project/README.md',
        isDirectory: false,
      ),
    ];
    if (showHidden) return all;
    return all.where((e) => !e.name.startsWith('.')).toList();
  }
}

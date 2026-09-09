import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:share_plus/share_plus.dart';

import '../services/remote_files_client.dart';
import '../theme/hermes_theme.dart';
import '../widgets/hermes_components.dart';

class LocalUpload {
  final String name;
  final List<int> bytes;
  final String mimeType;

  const LocalUpload({
    required this.name,
    required this.bytes,
    this.mimeType = 'application/octet-stream',
  });
}

class FilesScreen extends StatefulWidget {
  final RemoteFilesDataSource files;
  final ValueChanged<String>? onAddToChat;
  final Future<void> Function(RemoteFileDownload download)? onSaveDownload;
  final Future<void> Function(RemoteFileDownload download)? onShareDownload;
  final Future<List<LocalUpload>> Function()? onPickUploads;

  /// When set, the browser opens directly at this directory instead of the
  /// server's default working directory. Used to jump into a Project's folder
  /// from the Project detail Files tab.
  final String? initialPath;

  const FilesScreen({
    required this.files,
    this.onAddToChat,
    this.onSaveDownload,
    this.onShareDownload,
    this.onPickUploads,
    this.initialPath,
    super.key,
  });

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  RemoteDirectory? _root;
  String? _path;
  List<RemoteFileEntry> _entries = const [];
  RemoteFileEntry? _selected;
  RemoteTextPreview? _preview;
  RemoteFileDownload? _imageDownload;
  Object? _error;
  bool _loading = true;
  bool _downloading = false;
  bool _showHidden = false;
  final Set<String> _selectedPaths = {};
  List<RemoteFileEntry> _clipboard = const [];
  bool _clipboardCut = false;

  RemoteFilesWritableDataSource? get _writer =>
      widget.files is RemoteFilesWritableDataSource
      ? widget.files as RemoteFilesWritableDataSource
      : null;

  bool get _selectionMode => _selectedPaths.isNotEmpty;
  bool _validEntryName(String name) =>
      name.isNotEmpty && name != '.' && name != '..' && !name.contains('/');

  List<RemoteFileEntry> get _selectedEntries => _entries
      .where((entry) => _selectedPaths.contains(entry.path))
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    unawaited(_loadRoot());
  }

  Future<void> _loadRoot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final initialPath = widget.initialPath?.trim();
      if (initialPath != null && initialPath.isNotEmpty) {
        _root = RemoteDirectory(path: initialPath);
        await _openDirectory(initialPath);
        return;
      }
      final root = await widget.files.defaultDirectory();
      if (!mounted) return;
      _root = root;
      await _openDirectory(root.path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _openDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
      _preview = null;
    });
    try {
      final entries = await widget.files.listDirectory(
        path,
        showHidden: _showHidden,
      );
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _path = path;
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _openFile(RemoteFileEntry entry) async {
    setState(() {
      _selected = entry;
      _preview = null;
      _imageDownload = null;
      _loading = true;
      _error = null;
    });
    try {
      final preview = await widget.files.readText(entry.path);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
      if (_isImageMime(preview.mimeType)) {
        final download = await widget.files.download(entry.path);
        if (!mounted) return;
        setState(() => _imageDownload = download);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  bool _isImageMime(String mimeType) => mimeType.startsWith('image/');

  String? get _parentPath {
    final path = _path;
    final root = _root?.path;
    if (path == null || root == null || path == root) return null;
    final separator = path.lastIndexOf('/');
    if (separator <= 0) return '/';
    return path.substring(0, separator);
  }

  Future<void> _toggleHidden() async {
    setState(() => _showHidden = !_showHidden);
    final path = _path;
    if (path != null) {
      await _openDirectory(path);
    }
  }

  void _back() {
    if (_selected != null) {
      setState(() {
        _selected = null;
        _preview = null;
        _error = null;
      });
      return;
    }
    final parent = _parentPath;
    if (parent != null) {
      unawaited(_openDirectory(parent));
      return;
    }
    Navigator.maybePop(context);
  }

  Future<void> _saveEntry(RemoteFileEntry entry) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final download = await widget.files.download(entry.path);
      final saver = widget.onSaveDownload;
      if (saver != null) {
        await saver(download);
      } else {
        await FilePicker.platform.saveFile(
          dialogTitle: 'Save ${download.filename}',
          fileName: download.filename,
          bytes: download.bytes,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${download.filename} downloaded')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $error')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _shareEntry(RemoteFileEntry entry) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final download = await widget.files.download(entry.path);
      final sharer = widget.onShareDownload;
      if (sharer != null) {
        await sharer(download);
      } else {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(download.bytes, name: download.filename)],
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Share failed: $error')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _download() async {
    final selected = _selected;
    if (selected != null) await _saveEntry(selected);
  }

  void _addEntryToChat(RemoteFileEntry entry) {
    widget.onAddToChat?.call(entry.path);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File reference added to chat')),
    );
  }

  void _handleFileAction(String action, RemoteFileEntry entry) {
    switch (action) {
      case 'download':
        unawaited(_saveEntry(entry));
      case 'add':
        _addEntryToChat(entry);
      case 'share':
        unawaited(_shareEntry(entry));
    }
  }

  void _toggleSelection(RemoteFileEntry entry) {
    if (_writer == null) return;
    setState(() {
      if (!_selectedPaths.add(entry.path)) _selectedPaths.remove(entry.path);
    });
  }

  void _clearSelection() => setState(_selectedPaths.clear);

  void _copySelection({required bool cut}) {
    final selected = _selectedEntries;
    if (selected.isEmpty) return;
    setState(() {
      _clipboard = List.unmodifiable(selected);
      _clipboardCut = cut;
      _selectedPaths.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${selected.length} item${selected.length == 1 ? '' : 's'} ready to ${cut ? 'move' : 'copy'}',
        ),
      ),
    );
  }

  Future<void> _pasteHere() async {
    final writer = _writer;
    final path = _path;
    if (writer == null || path == null || _clipboard.isEmpty) return;
    setState(() => _loading = true);
    try {
      for (final entry in _clipboard) {
        if (_clipboardCut) {
          await writer.moveInto(entry.path, path);
        } else {
          await writer.copyInto(entry.path, path);
        }
      }
      if (_clipboardCut) _clipboard = const [];
      if (!mounted) return;
      await _openDirectory(path);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Paste complete')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not paste: $error')));
    }
  }

  Future<void> _createFolder() async {
    final writer = _writer;
    final path = _path;
    if (writer == null || path == null) return;
    var proposedName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => proposedName = value,
          decoration: const InputDecoration(labelText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, proposedName.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || !_validEntryName(name)) return;
    try {
      await writer.createDirectory(remoteJoin(path, name));
      await _openDirectory(path);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create folder: $error')),
      );
    }
  }

  Future<List<LocalUpload>> _pickUploads() async {
    final injected = widget.onPickUploads;
    if (injected != null) return injected();
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return const [];
    return [
      for (final file in result.files)
        if (file.bytes != null)
          LocalUpload(
            name: file.name,
            bytes: file.bytes!,
            mimeType: lookupMimeType(file.name) ?? 'application/octet-stream',
          ),
    ];
  }

  Future<void> _importFiles() async {
    final writer = _writer;
    final path = _path;
    if (writer == null || path == null) return;
    try {
      final uploads = await _pickUploads();
      if (uploads.isEmpty || !mounted) return;
      setState(() => _loading = true);
      for (final upload in uploads) {
        await writer.uploadFile(
          remoteJoin(path, upload.name),
          upload.bytes,
          mimeType: upload.mimeType,
        );
      }
      if (!mounted) return;
      await _openDirectory(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${uploads.length} file${uploads.length == 1 ? '' : 's'} imported',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }

  Future<void> _deleteSelection() async {
    final writer = _writer;
    final selected = _selectedEntries;
    if (writer == null || selected.isEmpty) return;
    final count = selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count item${count == 1 ? '' : 's'}?'),
        content: const Text(
          'Selected files and folders will be permanently deleted. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      for (final entry in selected) {
        await writer.deleteEntry(entry.path, recursive: entry.isDirectory);
      }
      _selectedPaths.clear();
      await _openDirectory(_path!);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete: $error')));
    }
  }

  Future<void> _renameSelection() async {
    final writer = _writer;
    final selected = _selectedEntries;
    if (writer == null || selected.length != 1) return;
    final entry = selected.single;
    var proposedName = entry.name;
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename item'),
        content: TextFormField(
          initialValue: entry.name,
          autofocus: true,
          onChanged: (value) => proposedName = value,
          decoration: const InputDecoration(labelText: 'New name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, proposedName.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName == null || !_validEntryName(newName) || newName == entry.name) {
      return;
    }
    try {
      await writer.rename(entry.path, newName);
      _selectedPaths.clear();
      await _openDirectory(_path!);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not rename: $error')));
    }
  }

  Widget _directoryBody() {
    if (_entries.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: Icons.folder_open_outlined,
          title: 'Folder is empty',
          message: 'There are no visible files in this server folder.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _openDirectory(_path!),
      child: ListView.separated(
        padding: const EdgeInsets.all(HermesSpacing.lg),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: HermesSpacing.sm),
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final selected = _selectedPaths.contains(entry.path);
          return HermesCard(
            key: Key('file-entry-${entry.path}'),
            status: selected ? HermesStatus.running : null,
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpacing.lg,
              vertical: HermesSpacing.md,
            ),
            onLongPress: _writer == null ? null : () => _toggleSelection(entry),
            onTap: () {
              if (_selectionMode) {
                _toggleSelection(entry);
              } else if (entry.isDirectory) {
                unawaited(_openDirectory(entry.path));
              } else {
                unawaited(_openFile(entry));
              }
            },
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  if (_selectionMode) ...[
                    Checkbox(
                      value: selected,
                      onChanged: (_) => _toggleSelection(entry),
                    ),
                    const SizedBox(width: HermesSpacing.sm),
                  ],
                  SizedBox(
                    key: Key('file-leading-${entry.path}'),
                    width: 48,
                    height: 48,
                    child: Icon(
                      entry.isDirectory
                          ? Icons.folder_outlined
                          : Icons.description_outlined,
                      color: HermesTokens.of(context).accent,
                    ),
                  ),
                  const SizedBox(width: HermesSpacing.md),
                  Expanded(child: Text(entry.name)),
                  if (!entry.isDirectory)
                    PopupMenuButton<String>(
                      key: Key('file-actions-${entry.path}'),
                      tooltip: 'File actions',
                      onSelected: (action) => _handleFileAction(action, entry),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'download',
                          child: ListTile(
                            leading: Icon(Icons.download_outlined),
                            title: Text('Download'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        if (widget.onAddToChat != null)
                          const PopupMenuItem(
                            value: 'add',
                            child: ListTile(
                              leading: Icon(Icons.add_comment_outlined),
                              title: Text('Add to chat'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'share',
                          child: ListTile(
                            leading: Icon(Icons.share_outlined),
                            title: Text('Share'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    )
                  else
                    const Icon(Icons.chevron_right),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _previewBody() {
    final selected = _selected!;
    final preview = _preview;
    final tokens = HermesTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(HermesSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(selected.name, style: tokens.typography.section),
          const SizedBox(height: HermesSpacing.sm),
          Wrap(
            spacing: HermesSpacing.sm,
            runSpacing: HermesSpacing.sm,
            children: [
              if (preview != null)
                StatusChip(status: HermesStatus.idle, label: preview.language),
              if (preview?.truncated == true)
                const StatusChip(
                  status: HermesStatus.blocked,
                  label: 'Preview truncated',
                ),
            ],
          ),
          const SizedBox(height: HermesSpacing.lg),
          Expanded(
            child: HermesCard(
              child: _imageDownload != null
                  ? InteractiveViewer(
                      child: Center(
                        child: Image.memory(
                          _imageDownload!.bytes,
                          errorBuilder: (context, error, stack) =>
                              const SelectableText(
                                'Image preview failed. Download the file to open it.',
                              ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        preview?.binary == true
                            ? 'Binary preview is unavailable. Download the file to open it.'
                            : preview?.text ?? 'Preview unavailable',
                        style: tokens.typography.body.copyWith(
                          fontFamily: 'monospace',
                          color: tokens.onSurface,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: HermesSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _downloading ? null : _download,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Download'),
                ),
              ),
              if (widget.onAddToChat != null) ...[
                const SizedBox(width: HermesSpacing.md),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      widget.onAddToChat!(selected.path);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('File reference added to chat'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add_comment_outlined),
                    label: const Text('Add to chat'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const LoadingSkeleton(rows: 6);
    if (_error != null) {
      return Center(
        child: ErrorState(
          title: _selected == null
              ? 'Could not load files'
              : 'Could not preview file',
          message: 'Check the Dashboard connection and try again.',
          onRetry: _selected == null
              ? () => unawaited(
                  _path == null ? _loadRoot() : _openDirectory(_path!),
                )
              : () => unawaited(_openFile(_selected!)),
        ),
      );
    }
    return _selected == null ? _directoryBody() : _previewBody();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        onPressed: _selectionMode ? _clearSelection : _back,
        icon: Icon(_selectionMode ? Icons.close : Icons.arrow_back),
      ),
      title: Text(
        _selectionMode ? '${_selectedPaths.length} selected' : 'Files',
      ),
      actions: _selectionMode
          ? [
              if (_selectedPaths.length == 1)
                IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(Icons.drive_file_rename_outline),
                  onPressed: () => unawaited(_renameSelection()),
                ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () => _copySelection(cut: false),
              ),
              IconButton(
                tooltip: 'Cut',
                icon: const Icon(Icons.content_cut),
                onPressed: () => _copySelection(cut: true),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(_deleteSelection()),
              ),
            ]
          : [
              if (_clipboard.isNotEmpty && _selected == null)
                IconButton(
                  tooltip: 'Paste here',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () => unawaited(_pasteHere()),
                ),
              if (_writer != null && _selected == null)
                IconButton(
                  tooltip: 'New folder',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () => unawaited(_createFolder()),
                ),
              if (_writer != null && _selected == null)
                IconButton(
                  tooltip: 'Import files',
                  icon: const Icon(Icons.upload_file_outlined),
                  onPressed: () => unawaited(_importFiles()),
                ),
              IconButton(
                key: const Key('toggle-hidden'),
                tooltip: _showHidden
                    ? 'Hide hidden files'
                    : 'Show hidden files',
                icon: Icon(
                  _showHidden
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: _selected == null ? _toggleHidden : null,
              ),
            ],
      bottom: !_selectionMode && _selected == null && _path != null
          ? PreferredSize(
              preferredSize: const Size.fromHeight(42),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpacing.lg,
                  0,
                  HermesSpacing.lg,
                  HermesSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _path!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_root?.branch != null &&
                        _root!.branch!.trim().isNotEmpty)
                      StatusChip(
                        status: HermesStatus.idle,
                        label: _root!.branch,
                      ),
                  ],
                ),
              ),
            )
          : null,
    ),
    body: _body(),
  );
}

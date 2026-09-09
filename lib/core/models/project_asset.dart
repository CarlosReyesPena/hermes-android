/// Server-authoritative project assets: generated artifacts, attachments, and
/// media, as returned by the Gateway `assets.list` RPC.
///
/// The server walks media roots (global) or a project's folders (scoped) and
/// returns a flat, newest-first list. Each entry carries just enough for the
/// mobile gallery to render a preview tile and drive Download / Add-to-chat /
/// Share without guessing at the file's type.
library;

/// One generated artifact, attachment, or media output on the server.
class ProjectAsset {
  /// The filename, without directories.
  final String name;

  /// The absolute server path the download/add-to-chat operations need.
  final String path;

  /// Broad category (`image`, `video`, `audio`, `document`, `other`), used to
  /// pick the tile icon and preview affordance.
  final String kind;

  /// The concrete MIME type, when the server knows it.
  final String mimeType;

  final int size;

  /// Seconds since the Unix epoch.
  final num modifiedAt;

  /// The owning Project on a scoped listing, or null on a global listing.
  final String? projectId;

  const ProjectAsset({
    required this.name,
    required this.path,
    required this.kind,
    required this.mimeType,
    required this.size,
    required this.modifiedAt,
    this.projectId,
  });

  factory ProjectAsset.fromJson(Map<String, dynamic> json) {
    final name = _trimmedString(json['name']);
    if (name == null) {
      throw const FormatException('An asset entry requires a name');
    }
    final path = _trimmedString(json['path']);
    if (path == null) {
      throw const FormatException('An asset entry requires a path');
    }
    final kind = _trimmedString(json['kind']) ?? _kindForName(name);
    return ProjectAsset(
      name: name,
      path: path,
      kind: kind,
      mimeType: _trimmedString(json['mime_type']) ?? 'application/octet-stream',
      size: _asInt(json['size']) ?? 0,
      modifiedAt: _asNum(json['modified_at']) ?? 0,
      projectId: _trimmedString(json['project_id']),
    );
  }

  /// Whether the entry is a media type the gallery can try to preview inline.
  bool get isPreviewable =>
      kind == 'image' || kind == 'video' || kind == 'audio';

  /// A stable label for accessibility and tests.
  String get label => name;

  static String _kindForName(String name) {
    final suffix = _extensionOf(name);
    switch (suffix) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
      case '.svg':
      case '.bmp':
        return 'image';
      case '.mp4':
      case '.mov':
      case '.webm':
      case '.mkv':
      case '.avi':
        return 'video';
      case '.mp3':
      case '.wav':
      case '.flac':
      case '.m4a':
      case '.ogg':
        return 'audio';
      case '.pdf':
      case '.doc':
      case '.docx':
      case '.xls':
      case '.xlsx':
      case '.ppt':
      case '.pptx':
      case '.md':
      case '.txt':
      case '.csv':
      case '.json':
      case '.zip':
      case '.apk':
        return 'document';
      default:
        return 'other';
    }
  }

  static String _extensionOf(String name) {
    final index = name.lastIndexOf('.');
    return index < 0 ? '' : name.substring(index).toLowerCase();
  }
}

/// The `assets.list` response: every asset plus the project it was scoped to.
class AssetsView {
  final List<ProjectAsset> assets;

  /// Non-null only when the listing was scoped to one project.
  final String? projectId;

  const AssetsView({this.assets = const [], this.projectId});

  factory AssetsView.fromJson(Map<String, dynamic> json) {
    final raw = json['assets'];
    return AssetsView(
      assets: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (entry) =>
                      ProjectAsset.fromJson(Map<String, dynamic>.from(entry)),
                )
                .toList(growable: false)
          : const [],
      projectId: _trimmedString(json['project_id']),
    );
  }

  static const empty = AssetsView();

  bool get isEmpty => assets.isEmpty;
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

num? _asNum(Object? value) {
  if (value is num) return value;
  return null;
}

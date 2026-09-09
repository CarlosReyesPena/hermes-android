/// The Assets contract: server-authoritative artifacts, attachments, and
/// generated media as the `assets.list` RPC returns them.
///
/// The server walks media roots (global) or a project's folders (scoped) and
/// returns a flat, newest-first list. Each entry carries just enough for the
/// mobile gallery to render a preview tile and drive Download / Add-to-chat /
/// Share without guessing at the file's type.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_asset.dart';

Map<String, dynamic> _asset({
  String name = 'shot.png',
  String path = '/home/carlos/.hermes/media/shot.png',
  String kind = 'image',
  String mimeType = 'image/png',
  int size = 24,
  num modifiedAt = 1750000000,
  String? projectId,
}) => {
  'name': name,
  'path': path,
  'kind': kind,
  'mime_type': mimeType,
  'size': size,
  'modified_at': modifiedAt,
  'project_id': projectId,
};

void main() {
  group('ProjectAsset', () {
    test('parses the assets.list entry shape', () {
      final asset = ProjectAsset.fromJson(_asset());

      expect(asset.name, 'shot.png');
      expect(asset.path, '/home/carlos/.hermes/media/shot.png');
      expect(asset.kind, 'image');
      expect(asset.mimeType, 'image/png');
      expect(asset.size, 24);
      expect(asset.modifiedAt, 1750000000);
      expect(asset.projectId, isNull);
    });

    test('tolerates a minimal record with only the required identity', () {
      final asset = ProjectAsset.fromJson({
        'name': 'mystery.xyz',
        'path': '/tmp/mystery.xyz',
      });

      expect(asset.name, 'mystery.xyz');
      expect(asset.path, '/tmp/mystery.xyz');
      expect(asset.kind, 'other');
      expect(asset.mimeType, 'application/octet-stream');
      expect(asset.size, 0);
      expect(asset.projectId, isNull);
    });

    test('carries the project id on a scoped entry', () {
      final asset = ProjectAsset.fromJson(_asset(projectId: 'p1'));

      expect(asset.projectId, 'p1');
    });

    test('rejects an entry without a name', () {
      expect(
        () => ProjectAsset.fromJson({'path': '/tmp/x.png'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an entry without a path', () {
      expect(
        () => ProjectAsset.fromJson({'name': 'x.png'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('classifies the kind from the extension', () {
      ProjectAsset classify(String name) =>
          ProjectAsset.fromJson({'name': name, 'path': '/x/$name'});

      expect(classify('clip.mp4').kind, 'video');
      expect(classify('audio.mp3').kind, 'audio');
      expect(classify('doc.pdf').kind, 'document');
      expect(classify('notes.md').kind, 'document');
      expect(classify('unknown.xyz').kind, 'other');
    });
  });

  group('AssetsView', () {
    test('parses the assets.list envelope', () {
      final view = AssetsView.fromJson({
        'assets': [_asset(), _asset(name: 'clip.mp4', kind: 'video')],
        'project_id': 'p1',
      });

      expect(view.assets, hasLength(2));
      expect(view.projectId, 'p1');
      expect(view.assets.first.name, 'shot.png');
    });

    test('parses an empty envelope', () {
      final view = AssetsView.fromJson({'assets': [], 'project_id': null});

      expect(view.assets, isEmpty);
      expect(view.projectId, isNull);
      expect(view.isEmpty, isTrue);
    });
  });
}

/// The Assets screen: the project's generated artifacts, attachments, and
/// media as the server-authoritative `assets.list` index reports them.
///
/// Designed so it can be driven by a fake in tests, and so it degrades to a
/// calm compatibility notice (never an error) when the gateway predates the
/// index.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:async';
import 'package:hermes_android/core/models/project_asset.dart';
import 'package:hermes_android/core/services/assets_gateway_client.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/assets_screen.dart';
import 'package:hermes_android/core/widgets/hermes_components.dart';

ProjectAsset _asset({
  String name = 'shot.png',
  String path = '/home/carlos/.hermes/media/shot.png',
  String kind = 'image',
  String mimeType = 'image/png',
}) => ProjectAsset(
  name: name,
  path: path,
  kind: kind,
  mimeType: mimeType,
  size: 24,
  modifiedAt: 1750000000,
);

Future<void> _pump(
  WidgetTester tester, {
  required Future<AssetsView> Function() load,
  ValueChanged<ProjectAsset>? onOpen,
  ValueChanged<ProjectAsset>? onAddToChat,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: hermesTheme(Brightness.dark),
      home: AssetsScreen(load: load, onOpen: onOpen, onAddToChat: onAddToChat),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

void main() {
  testWidgets('holds a skeleton until the first read lands', (tester) async {
    final gate = Completer<AssetsView>();
    await _pump(tester, load: () => gate.future, settle: false);
    await tester.pump();

    expect(find.byType(LoadingSkeleton), findsOneWidget);

    gate.complete(AssetsView.empty);
    await tester.pumpAndSettle();
  });

  testWidgets('renders the asset tiles with name and kind', (tester) async {
    await _pump(
      tester,
      load: () async => AssetsView(
        assets: [
          _asset(),
          _asset(name: 'clip.mp4', kind: 'video', mimeType: 'video/mp4'),
        ],
      ),
    );

    expect(find.text('shot.png'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
  });

  testWidgets('an empty index shows an empty state, not an error', (
    tester,
  ) async {
    await _pump(tester, load: () async => AssetsView.empty);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.byType(ErrorState), findsNothing);
  });

  testWidgets('an older gateway explains itself instead of erroring', (
    tester,
  ) async {
    await _pump(
      tester,
      load: () async => throw const AssetsUnsupportedException(
        'assets.list',
        'This gateway does not support assets.list',
      ),
    );

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.textContaining('does not support'), findsOneWidget);
  });

  testWidgets('a transport failure is retryable', (tester) async {
    var attempts = 0;
    await _pump(
      tester,
      load: () async {
        attempts++;
        if (attempts == 1) throw Exception('offline');
        return AssetsView(assets: [_asset()]);
      },
    );

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('shot.png'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('tapping a tile reports the asset', (tester) async {
    ProjectAsset? opened;
    await _pump(
      tester,
      load: () async => AssetsView(assets: [_asset()]),
      onOpen: (asset) => opened = asset,
    );

    await tester.tap(find.text('shot.png'));
    await tester.pumpAndSettle();

    expect(opened, isNotNull);
    expect(opened!.name, 'shot.png');
  });

  testWidgets('Add to chat reports the asset path', (tester) async {
    ProjectAsset? added;
    await _pump(
      tester,
      load: () async => AssetsView(assets: [_asset()]),
      onAddToChat: (asset) => added = asset,
    );

    await tester.tap(find.byKey(const Key('asset-add-shot.png')));
    await tester.pumpAndSettle();

    expect(added, isNotNull);
    expect(added!.path, '/home/carlos/.hermes/media/shot.png');
  });

  testWidgets('no Add to chat affordance when the callback is absent', (
    tester,
  ) async {
    await _pump(tester, load: () async => AssetsView(assets: [_asset()]));

    expect(find.byKey(const Key('asset-add-shot.png')), findsNothing);
  });

  testWidgets('pull to refresh forces a live read', (tester) async {
    var reads = 0;
    await _pump(
      tester,
      load: () async {
        reads++;
        return AssetsView(assets: [_asset()]);
      },
    );

    expect(reads, 1);

    await tester.fling(find.byType(Scrollable), const Offset(0, 400), 800);
    await tester.pumpAndSettle();

    expect(reads, 2);
  });
}

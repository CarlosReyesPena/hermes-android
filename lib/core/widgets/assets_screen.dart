/// The Assets surface: generated artifacts, attachments, and media, rendered
/// from the server-authoritative `assets.list` index.
///
/// Two decisions worth stating because they are easy to get wrong later:
///
/// * **The index is the source of truth.** The gallery never scans the device
///   or invents a second registry; it renders exactly what the gateway served,
///   newest first.
/// * **An older gateway is not an error the user caused.** A missing
///   `assets.*` family renders a calm compatibility notice, and a transport
///   failure is retryable — never a blank screen or a crash.
///
/// [AssetsScreen] wraps [AssetsGallery] in a Scaffold for the standalone More
/// destination; the Project detail screen embeds [AssetsGallery] directly into
/// its Assets tab so the two surfaces share one implementation.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/project_asset.dart';
import '../services/assets_gateway_client.dart';
import '../theme/hermes_theme.dart';
import 'hermes_components.dart';

/// Reads the asset index, so the screen can be driven by a fake in tests.
typedef AssetsLoader = Future<AssetsView> Function();

/// A distinct key per asset for tests and stable tooltips.
Key assetTileKey(ProjectAsset asset) => Key('asset-tile-${asset.name}');

Key assetAddToChatKey(ProjectAsset asset) => Key('asset-add-${asset.name}');

/// The standalone Assets screen (More destination).
class AssetsScreen extends StatelessWidget {
  final AssetsLoader load;
  final ValueChanged<ProjectAsset>? onOpen;
  final ValueChanged<ProjectAsset>? onAddToChat;

  const AssetsScreen({
    required this.load,
    this.onOpen,
    this.onAddToChat,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Assets')),
    body: AssetsGallery(load: load, onOpen: onOpen, onAddToChat: onAddToChat),
  );
}

/// The Assets gallery body, reusable standalone and inside a Project tab.
class AssetsGallery extends StatefulWidget {
  final AssetsLoader load;
  final ValueChanged<ProjectAsset>? onOpen;
  final ValueChanged<ProjectAsset>? onAddToChat;

  const AssetsGallery({
    required this.load,
    this.onOpen,
    this.onAddToChat,
    super.key,
  });

  @override
  State<AssetsGallery> createState() => _AssetsGalleryState();
}

class _AssetsGalleryState extends State<AssetsGallery> {
  AssetsView? _view;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final view = await widget.load();
      if (!mounted) return;
      setState(() {
        _view = view;
        _loading = false;
      });
    } on AssetsUnsupportedException {
      if (!mounted) return;
      setState(() {
        _view = null;
        _loading = false;
        _error = const _UnsupportedAssets();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Widget _body() {
    if (_loading) return const LoadingSkeleton(rows: 6);

    if (_error is _UnsupportedAssets) {
      return const ErrorState.unsupported(
        title: 'Assets unavailable',
        message:
            'This Hermes gateway does not support a server Assets index yet. '
            'Update Hermes on the server to browse generated artifacts and '
            'media from your phone.',
      );
    }

    if (_error != null) {
      return ErrorState(
        title: 'Could not load assets',
        message: 'Check the gateway connection and try again.',
        onRetry: () => unawaited(_load()),
      );
    }

    final assets = _view?.assets ?? const <ProjectAsset>[];
    if (assets.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            Padding(
              padding: EdgeInsets.only(top: HermesSpacing.xl),
              child: EmptyState(
                icon: Icons.image_outlined,
                title: 'No assets yet',
                message:
                    'Generated artifacts, attachments, and media will appear '
                    'here once Hermes produces them.',
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(HermesSpacing.lg),
        itemCount: assets.length,
        separatorBuilder: (_, _) => const SizedBox(height: HermesSpacing.sm),
        itemBuilder: (context, index) => _AssetTile(
          asset: assets[index],
          onTap: widget.onOpen == null
              ? null
              : () => widget.onOpen!(assets[index]),
          onAddToChat: widget.onAddToChat == null
              ? null
              : () => widget.onAddToChat!(assets[index]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _body();
}

/// Marker for the "older gateway" compatibility notice.
class _UnsupportedAssets {
  const _UnsupportedAssets();
}

class _AssetTile extends StatelessWidget {
  final ProjectAsset asset;
  final VoidCallback? onTap;
  final VoidCallback? onAddToChat;

  const _AssetTile({required this.asset, this.onTap, this.onAddToChat});

  IconData get _icon {
    switch (asset.kind) {
      case 'image':
        return Icons.image_outlined;
      case 'video':
        return Icons.videocam_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'document':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return HermesCard(
      key: assetTileKey(asset),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpacing.lg,
        vertical: HermesSpacing.md,
      ),
      child: Row(
        children: [
          Icon(_icon, color: tokens.accent),
          const SizedBox(width: HermesSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.typography.body,
                ),
                Text(
                  asset.kind,
                  style: tokens.typography.label.copyWith(color: tokens.muted),
                ),
              ],
            ),
          ),
          if (onAddToChat != null)
            IconButton(
              key: assetAddToChatKey(asset),
              tooltip: 'Add to chat',
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: onAddToChat,
            ),
          if (onTap != null) Icon(Icons.chevron_right, color: tokens.muted),
        ],
      ),
    );
  }
}

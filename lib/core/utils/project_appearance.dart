import 'package:flutter/material.dart';

/// Converts the server-owned CSS hex color into a Flutter color.
///
/// Projects may be written by a newer Desktop client, so malformed or future
/// values must degrade to the local theme accent rather than breaking a card.
Color projectDisplayColor(String? value, {required Color fallback}) {
  if (value == null) return fallback;
  final match = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').firstMatch(value);
  if (match == null) return fallback;
  final hex = match.group(1)!;
  final argb = hex.length == 6 ? 'FF$hex' : hex;
  return Color(int.parse(argb, radix: 16));
}

/// A compact mobile subset of the Desktop swatches, using the same wire values.
const projectColorChoices = <String>[
  '#2F81F7',
  '#A371F7',
  '#F778BA',
  '#F85149',
  '#D29922',
  '#3FB950',
  '#39C5CF',
  '#8B949E',
];

/// Material equivalents for the curated Codicons offered by Hermes Desktop.
const projectIconChoices = <String, IconData>{
  'folder-library': Icons.folder_rounded,
  'repo': Icons.account_tree_rounded,
  'rocket': Icons.rocket_launch_rounded,
  'beaker': Icons.science_rounded,
  'flame': Icons.local_fire_department_rounded,
  'star-full': Icons.star_rounded,
  'heart': Icons.favorite_rounded,
  'zap': Icons.bolt_rounded,
  'target': Icons.adjust_rounded,
  'lightbulb': Icons.lightbulb_rounded,
  'tools': Icons.build_rounded,
  'device-desktop': Icons.desktop_windows_rounded,
  'device-mobile': Icons.phone_android_rounded,
  'terminal': Icons.terminal_rounded,
  'dashboard': Icons.dashboard_rounded,
  'globe': Icons.public_rounded,
  'broadcast': Icons.cell_tower_rounded,
  'cloud': Icons.cloud_rounded,
  'database': Icons.storage_rounded,
  'package': Icons.inventory_2_rounded,
  'book': Icons.menu_book_rounded,
  'organization': Icons.account_tree_rounded,
  'bug': Icons.bug_report_rounded,
  'shield': Icons.shield_rounded,
  'key': Icons.key_rounded,
  'gift': Icons.card_giftcard_rounded,
  'telescope': Icons.travel_explore_rounded,
  'home': Icons.home_rounded,
};

IconData projectDisplayIcon(String? value) =>
    projectIconChoices[value] ?? Icons.folder_rounded;

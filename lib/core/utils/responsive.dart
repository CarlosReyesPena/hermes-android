// Responsive layout helpers.
// Single source of truth for the app's responsive thresholds.
import 'package:flutter/material.dart';

class Responsive {
  /// 600dp breakpoint — the Material Design standard for phone/tablet.
  /// Used by grid and column layouts (see [gridColumns]).
  static const double tabletBreakpoint = 600;

  /// 720dp breakpoint — the width at which the navigation shell switches from
  /// a bottom bar to a side rail. Wider than [tabletBreakpoint] because a
  /// labelled rail needs more horizontal room than a two-column grid.
  static const double railBreakpoint = 720;

  /// Whether the current screen is wide enough for tablet layout.
  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= tabletBreakpoint;

  /// Returns appropriate cross-axis count for grid layouts.
  static int gridColumns(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 1200) return 4;
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }
}

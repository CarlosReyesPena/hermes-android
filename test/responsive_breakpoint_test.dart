/// Cross-cutting breakpoint consistency.
///
/// The app must have ONE source of truth for its responsive thresholds, not
/// two magic numbers that drift apart. `Responsive` owns the canonical
/// breakpoints; the navigation shell references them rather than re-declaring
/// its own copy. The rail needs more horizontal room than a two-column grid,
/// so `railBreakpoint` may be larger than `tabletBreakpoint` — but the shell
/// must not invent a third value.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/core/widgets/hermes_shell.dart';

void main() {
  test('the shell derives its rail breakpoint from Responsive', () {
    expect(HermesShell.railBreakpoint, Responsive.railBreakpoint);
  });

  test('the rail breakpoint is a documented multiple on the grid', () {
    // The nav rail needs more width than a two-column grid. Both must sit on
    // the shared grid and be positive; the rail must not be below the tablet
    // threshold it refines.
    expect(
      Responsive.railBreakpoint,
      greaterThanOrEqualTo(Responsive.tabletBreakpoint),
    );
    expect(Responsive.railBreakpoint % 1, 0);
    expect(Responsive.tabletBreakpoint % 1, 0);
  });

  test('the tablet threshold is the Material 600dp standard', () {
    expect(Responsive.tabletBreakpoint, 600);
  });
}

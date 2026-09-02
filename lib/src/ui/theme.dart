// lib/src/ui/theme.dart
//
// A dark, low-chroma chrome. Not a style preference: the panels surround the
// photograph, and any colour in them shifts how its colours are judged. Grey
// at a few percent lightness is the standard viewing surround for exactly
// that reason.

import 'package:flutter/material.dart';

abstract final class Chrome {
  static const Color canvas = Color(0xFF141416);
  static const Color panel = Color(0xFF1C1C20);
  static const Color panelRaised = Color(0xFF25252A);
  static const Color divider = Color(0xFF2E2E34);
  static const Color accent = Color(0xFF7C6BF0);
  static const Color text = Color(0xFFE6E6EA);
  static const Color textDim = Color(0xFF9A9AA4);
  static const Color warn = Color(0xFFE0A33A);

  static const TextStyle label = TextStyle(
    fontSize: 11.5,
    color: textDim,
    letterSpacing: 0.3,
  );

  static const TextStyle value = TextStyle(
    fontSize: 11.5,
    color: text,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle heading = TextStyle(
    fontSize: 10.5,
    color: textDim,
    letterSpacing: 1.1,
    fontWeight: FontWeight.w600,
  );
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Chrome.accent,
    surface: Chrome.panel,
    onSurface: Chrome.text,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Chrome.canvas,
    dividerColor: Chrome.divider,
    sliderTheme: const SliderThemeData(
      trackHeight: 2.5,
      activeTrackColor: Chrome.accent,
      inactiveTrackColor: Chrome.divider,
      thumbColor: Chrome.text,
      overlayColor: Color(0x227C6BF0),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6.5),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      showValueIndicator: ShowValueIndicator.never,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 600),
    ),
    // Material 3 fills a selected segment with `secondaryContainer`, which
    // for a dark scheme derives to a bright teal that has nothing to do with
    // the rest of the chrome. Point it at the accent instead.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Chrome.accent
                : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.white
                : Chrome.textDim),
        side: const WidgetStatePropertyAll(
            BorderSide(color: Chrome.divider)),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12.5)),
      ),
    ),
  );
}

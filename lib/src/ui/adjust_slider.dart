// lib/src/ui/adjust_slider.dart
//
// One labelled slider. Every adjustment in the panel is one of these, so the
// affordances live here once: the value is always visible, the label is a
// reset button, and a drag reports continuously so the canvas can follow it.

import 'package:flutter/material.dart';

import 'theme.dart';

class AdjustSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final double neutral;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  /// Called once when a drag ends, for callers that want to do something
  /// heavier than the live update.
  final VoidCallback? onChangeEnd;

  final bool enabled;

  /// Shown under the slider when there is something to say about the value —
  /// which method produced a colour temperature, that a zone adjustment has
  /// been scaled back.
  final String? note;

  const AdjustSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.neutral = 0,
    this.format = _defaultFormat,
    this.onChangeEnd,
    this.enabled = true,
    this.note,
  });

  static String _defaultFormat(double v) =>
      '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(2)}';

  bool get _modified => (value - neutral).abs() > 1e-9;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // The label doubles as the reset: double-clicking a control to
              // return it to neutral is the convention every editor uses, and
              // a row of reset buttons would double the panel's visual noise.
              Expanded(
                child: MouseRegion(
                  cursor: _modified && enabled
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
                  child: GestureDetector(
                    onDoubleTap:
                        enabled && _modified ? () => onChanged(neutral) : null,
                    child: Tooltip(
                      message: _modified
                          ? 'Double-click to reset'
                          : '',
                      child: Text(
                        label,
                        style: Chrome.label.copyWith(
                          color: enabled
                              ? (_modified ? Chrome.text : Chrome.textDim)
                              : Chrome.textDim.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Text(
                format(value),
                style: Chrome.value.copyWith(
                  color: enabled
                      ? (_modified ? Chrome.accent : Chrome.textDim)
                      : Chrome.textDim.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 22,
            // A focused Slider handles the arrow keys itself. That would make
            // "left is the previous image" work only until the first time you
            // touched a slider, and then quietly stop — the worst kind of
            // keyboard binding. Excluding these from focus reserves the arrows
            // for navigation; the sliders are still fully mouse-operable.
            child: ExcludeFocus(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: enabled ? onChanged : null,
                onChangeEnd: (_) => onChangeEnd?.call(),
              ),
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(note!,
                  style: Chrome.label.copyWith(fontSize: 10, height: 1.3)),
            ),
        ],
      ),
    );
  }
}

/// A section heading in the control stack.
class PanelSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  const PanelSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Row(
            children: [
              Text(title.toUpperCase(), style: Chrome.heading),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// Keyboard-focusable text that reads as a link. Used for the small inline
/// actions — "as shot", "reset all" — that would be too heavy as buttons.
class InlineAction extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const InlineAction({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onPressed,
        child: Text(
          label,
          style: Chrome.label.copyWith(
            fontSize: 10.5,
            color: on ? Chrome.accent : Chrome.textDim.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

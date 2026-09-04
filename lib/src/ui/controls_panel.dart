// lib/src/ui/controls_panel.dart
//
// The control stack: which image, what it contains, and the adjustments.
//
// The order is the order the pipeline applies them in, top to bottom — white
// balance, then the scene-referred tone controls, then the display-referred
// ones. A panel laid out in pipeline order teaches the pipeline, and stops the
// question "why does contrast behave differently after I move the highlights"
// before it is asked.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../model/edit.dart';
import '../pipeline/processor.dart';
import '../ria/ria.dart';
import 'adjust_slider.dart';
import 'histogram_view.dart';
import 'theme.dart';

class ControlsPanel extends StatelessWidget {
  final FrameInfo? frame;
  final Edit edit;
  final Histogram? histogram;
  final double softLimitFactor;
  final ValueChanged<Edit> onChanged;

  const ControlsPanel({
    super.key,
    required this.frame,
    required this.edit,
    required this.histogram,
    required this.softLimitFactor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final f = frame;
    if (f == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No frame open.',
              textAlign: TextAlign.center, style: Chrome.label),
        ),
      );
    }

    final hist = histogram;
    final temperature = edit.temperatureK ?? f.asShot.kelvin;

    return ListView(
      // Keyed on the frame, so opening a different one starts at the top.
      // Without this the panel keeps the previous frame's scroll offset and
      // the new image's name — the first thing you want to see — is scrolled
      // off the top.
      key: ValueKey(f.path),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        _Identity(frame: f),
        const SizedBox(height: 14),
        if (hist != null)
          HistogramView(histogram: hist)
        else
          const HistogramPlaceholder(),

        // ── White balance ────────────────────────────────────────────────
        PanelSection(
          title: 'White balance',
          trailing: InlineAction(
            label: 'as shot',
            onPressed: edit.temperatureK == null
                ? null
                : () => onChanged(edit.copyWith(clearTemperature: true)),
          ),
          children: [
            AdjustSlider(
              label: 'Colour temperature',
              value: temperature,
              min: f.minKelvin,
              max: f.maxKelvin,
              neutral: f.asShot.kelvin,
              format: (v) => '${v.round()} K',
              onChanged: (v) => onChanged(edit.copyWith(temperatureK: v)),
              enabled: f.asShot.reliable,
              note: _temperatureNote(f, temperature),
            ),
          ],
        ),

        // ── Exposure ─────────────────────────────────────────────────────
        PanelSection(
          title: 'Exposure',
          trailing: InlineAction(
            label: 'reset',
            onPressed: _zonesModified
                ? () => onChanged(edit.copyWith(
                    blackEv: 0, shadowEv: 0, highlightEv: 0, whiteEv: 0))
                : null,
          ),
          children: [
            AdjustSlider(
              label: 'Black level',
              value: edit.blackEv,
              min: -evRange,
              max: evRange,
              format: _ev,
              onChanged: (v) => onChanged(edit.copyWith(blackEv: v)),
            ),
            AdjustSlider(
              label: 'Shadow',
              value: edit.shadowEv,
              min: -evRange,
              max: evRange,
              format: _ev,
              onChanged: (v) => onChanged(edit.copyWith(shadowEv: v)),
            ),
            AdjustSlider(
              label: 'Highlight',
              value: edit.highlightEv,
              min: -evRange,
              max: evRange,
              format: _ev,
              onChanged: (v) => onChanged(edit.copyWith(highlightEv: v)),
            ),
            AdjustSlider(
              label: 'White level',
              value: edit.whiteEv,
              min: -evRange,
              max: evRange,
              format: _ev,
              onChanged: (v) => onChanged(edit.copyWith(whiteEv: v)),
            ),
            _SoftLimitNote(factor: softLimitFactor),
            _RolloffToggle(
              value: edit.highlightRolloff,
              onChanged: (v) => onChanged(edit.copyWith(highlightRolloff: v)),
            ),
          ],
        ),

        // ── Tone ─────────────────────────────────────────────────────────
        PanelSection(
          title: 'Tone',
          children: [
            AdjustSlider(
              label: 'Brightness',
              value: edit.brightnessEv,
              min: -evRange,
              max: evRange,
              format: _ev,
              onChanged: (v) => onChanged(edit.copyWith(brightnessEv: v)),
              note: 'Midtone placement — moves the grey point, leaving black '
                  'and white anchored.',
            ),
            AdjustSlider(
              label: 'Contrast',
              value: edit.contrastEv,
              min: -evRange,
              max: evRange,
              format: _ev,
              onChanged: (v) => onChanged(edit.copyWith(contrastEv: v)),
              note: _contrastNote(edit.contrastEv),
            ),
          ],
        ),

        // ── Colour ───────────────────────────────────────────────────────
        PanelSection(
          title: 'Colour',
          children: [
            AdjustSlider(
              label: 'Saturation',
              value: edit.saturation,
              min: -saturationRange,
              max: saturationRange,
              format: _saturation,
              onChanged: (v) => onChanged(edit.copyWith(saturation: v)),
              note: 'Contrast acts on luminance only, so hue never moves — '
                  'and the colour it leaves behind can read flat. This is the '
                  'remedy: every channel\'s distance from the pixel\'s own '
                  'luma, scaled. It runs after the display transform, so it '
                  'is independent of the highlight rolloff.',
            ),
          ],
        ),

        // ── Detail ───────────────────────────────────────────────────────
        PanelSection(
          title: 'Detail',
          children: [
            AdjustSlider(
              label: 'Sharpness',
              value: edit.sharpness,
              min: 0,
              max: 1.5,
              format: (v) => v.toStringAsFixed(2),
              onChanged: (v) => onChanged(edit.copyWith(sharpness: v)),
              note: 'Unsharp mask, applied last — after the image is in the '
                  'display domain, which is where sharpening belongs.',
            ),
          ],
        ),

        const SizedBox(height: 18),
        Row(
          children: [
            InlineAction(
              label: 'Reset all adjustments',
              onPressed:
                  edit.isNeutral ? null : () => onChanged(Edit.neutral),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Adjustments are held in memory only. The RAW file is opened '
          'read-only and is never written to.',
          style: TextStyle(fontSize: 10, color: Chrome.textDim, height: 1.4),
        ),
      ],
    );
  }

  bool get _zonesModified =>
      edit.blackEv != 0 ||
      edit.shadowEv != 0 ||
      edit.highlightEv != 0 ||
      edit.whiteEv != 0;

  static String _ev(double v) {
    if (v == 0) return '0.00 EV';
    return '${v > 0 ? '+' : '−'}${v.abs().toStringAsFixed(2)} EV';
  }

  /// A position on a scale, not a quantity: no unit, and no decimals, which
  /// over a hundred-unit range would be three digits of noise.
  static String _saturation(double v) {
    if (v == 0) return '0';
    return '${v > 0 ? '+' : '−'}${v.abs().round()}';
  }

  static String? _contrastNote(double c) {
    if (c == 0) return null;
    // slope = 2^(c/3), so the note states the thing the number means rather
    // than repeating the number.
    final slope = math.pow(2.0, c / 3);
    return 'Slope ×${slope.toStringAsFixed(2)} about the midtone. Acts on '
        'luminance only, so hue does not shift.';
  }

  static String _temperatureNote(FrameInfo f, double current) {
    if (!f.asShot.reliable) {
      return 'This body\'s white balance sits too far off the Planckian locus '
          'for a Kelvin figure to describe it, so the control is disabled '
          'rather than showing a number that means nothing.';
    }
    final shot = f.asShot;
    final delta = current - shot.kelvin;
    final base = 'As shot ${shot.kelvin.round()} K, ${shot.tintLabel} '
        '(${shot.sourceLabel}).';
    if (delta.abs() < 1) return base;
    // The chromatic adaptation is exact for the pixels that survived the
    // decode; what it cannot do is rebuild a channel that clipped in camera
    // space. Over a few hundred Kelvin that is invisible, and past a couple of
    // thousand it is not.
    final far = delta.abs() > 1500;
    return '$base${far ? ' Large shifts cannot rebuild highlights that '
        'clipped during the decode — export re-decodes, so the file is '
        'closer to exact than this preview.' : ''}';
  }

}

class _Identity extends StatelessWidget {
  final FrameInfo frame;

  const _Identity({required this.frame});

  @override
  Widget build(BuildContext context) {
    final m = frame.metadata;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p.basename(frame.path),
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: Chrome.text),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(m.camera, style: Chrome.label, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(
          '${m.sizeText}  ·  ${m.focalText}  ·  ${m.apertureText}  ·  '
          '${m.shutterText}  ·  ${m.isoText}',
          style: Chrome.label.copyWith(fontSize: 10),
        ),
        const SizedBox(height: 2),
        Text(
          'scene median ${frame.medianEv.toStringAsFixed(2)} EV below '
          'saturation',
          style: Chrome.label.copyWith(fontSize: 10),
        ),
      ],
    );
  }
}

/// Says so when the zone controls have been scaled back.
///
/// approach.md §7: adjacent zones pulled in opposite directions drive the
/// tone curve slope negative, which solarises the image, and that is reachable
/// inside the ±3 EV the sliders offer. The engine scales all four by one
/// common factor until the curve is monotonic again — preserving the shape
/// asked for rather than clamping one control — and this is where that gets
/// admitted instead of the sliders silently doing less than they say.
class _SoftLimitNote extends StatelessWidget {
  final double factor;

  const _SoftLimitNote({required this.factor});

  @override
  Widget build(BuildContext context) {
    if (factor >= 0.999) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 13, color: Chrome.warn),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Zones scaled to ${(factor * 100).round()}% — pulled further '
              'apart the tone curve folds over and the image solarises.',
              style: Chrome.label.copyWith(
                  fontSize: 10, color: Chrome.warn, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _RolloffToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _RolloffToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Highlight rolloff',
                    style: Chrome.label.copyWith(
                        color: value ? Chrome.text : Chrome.textDim)),
              ),
              SizedBox(
                height: 22,
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Text(
              value
                  ? 'Extended Reinhard shoulder: everything above display '
                      'white is compressed in rather than clipped.'
                  : 'Off — the top clips at white, which is what a plain '
                      'decode does.',
              style: Chrome.label.copyWith(fontSize: 10, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

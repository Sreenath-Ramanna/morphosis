// lib/src/model/edit.dart
//
// The edit: one immutable value describing every adjustment applied to a
// frame. It is the only thing an adjustment changes — the RAW file on disk is
// opened read-only and never written, and the decoded scene-referred buffer is
// never modified in place. Everything the viewer sees is regenerated from
// those two inputs on every change.

import 'dart:math' as math;

/// The full ±3 EV range approach.md specifies for every EV-denominated
/// control.
const double evRange = 3.0;

class Edit {
  /// Target colour temperature in Kelvin. Null means "as shot" — held as null
  /// rather than as a number so that reopening the same frame reproduces
  /// exactly what the camera recorded, whatever the slider was last dragged
  /// to.
  final double? temperatureK;

  /// Zone adjustments, −3 … +3 EV. Scene-referred, applied as a
  /// luminance-preserving gain.
  final double blackEv;
  final double shadowEv;
  final double highlightEv;
  final double whiteEv;

  /// Midtone placement, −3 … +3 EV. Drives the display transform's grey
  /// point; see the note in tone.dart on why this is not a second exposure.
  final double brightnessEv;

  /// Slope of the tone curve in log space, −3 … +3 EV; `2^(c/3)`, so +3
  /// doubles the number of stops between any two tones and −3 halves it.
  final double contrastEv;

  /// Unsharp mask amount, 0 … 1.5. Display-referred, applied last.
  final double sharpness;

  /// Roll the highlights off with the extended-Reinhard shoulder instead of
  /// clipping them. Off reproduces what a plain decode does.
  final bool highlightRolloff;

  const Edit({
    this.temperatureK,
    this.blackEv = 0,
    this.shadowEv = 0,
    this.highlightEv = 0,
    this.whiteEv = 0,
    this.brightnessEv = 0,
    this.contrastEv = 0,
    this.sharpness = 0,
    this.highlightRolloff = false,
  });

  static const Edit neutral = Edit();

  bool get isNeutral =>
      temperatureK == null &&
      blackEv == 0 &&
      shadowEv == 0 &&
      highlightEv == 0 &&
      whiteEv == 0 &&
      brightnessEv == 0 &&
      contrastEv == 0 &&
      sharpness == 0 &&
      !highlightRolloff;

  Edit copyWith({
    double? temperatureK,
    bool clearTemperature = false,
    double? blackEv,
    double? shadowEv,
    double? highlightEv,
    double? whiteEv,
    double? brightnessEv,
    double? contrastEv,
    double? sharpness,
    bool? highlightRolloff,
  }) =>
      Edit(
        temperatureK:
            clearTemperature ? null : (temperatureK ?? this.temperatureK),
        blackEv: blackEv ?? this.blackEv,
        shadowEv: shadowEv ?? this.shadowEv,
        highlightEv: highlightEv ?? this.highlightEv,
        whiteEv: whiteEv ?? this.whiteEv,
        brightnessEv: brightnessEv ?? this.brightnessEv,
        contrastEv: contrastEv ?? this.contrastEv,
        sharpness: sharpness ?? this.sharpness,
        highlightRolloff: highlightRolloff ?? this.highlightRolloff,
      );

  /// The grey point this edit implies, given the frame's automatic starting
  /// point. Halving the grey point brightens by one stop.
  double greyPointFrom(double autoGreyPoint) =>
      autoGreyPoint / math.pow(2.0, brightnessEv);

  @override
  bool operator ==(Object other) =>
      other is Edit &&
      other.temperatureK == temperatureK &&
      other.blackEv == blackEv &&
      other.shadowEv == shadowEv &&
      other.highlightEv == highlightEv &&
      other.whiteEv == whiteEv &&
      other.brightnessEv == brightnessEv &&
      other.contrastEv == contrastEv &&
      other.sharpness == sharpness &&
      other.highlightRolloff == highlightRolloff;

  @override
  int get hashCode => Object.hash(temperatureK, blackEv, shadowEv, highlightEv,
      whiteEv, brightnessEv, contrastEv, sharpness, highlightRolloff);
}

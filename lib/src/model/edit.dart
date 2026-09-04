// lib/src/model/edit.dart
//
// The edit: one immutable value describing every adjustment applied to a
// frame. It is the only thing an adjustment changes — the RAW file on disk is
// opened read-only and never written, and the decoded scene-referred buffer is
// never modified in place. Everything the viewer sees is regenerated from
// those two inputs on every change.

import 'dart:math' as math;

import 'geometry.dart';

/// The full ±3 EV range approach.md specifies for every EV-denominated
/// control.
const double evRange = 3.0;

/// The full −50 … +50 range of the saturation control.
const double saturationRange = 50.0;

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

  /// Saturation, −50 … +50. Display-referred: it scales each channel's
  /// distance from the pixel's luma by `f = 1 + s / saturationRange`, so −50
  /// is exactly greyscale and +50 doubles the distance. `s / saturationRange`
  /// is numerically `ria_adjustments.saturation`, so the Dart loop and any
  /// future native path agree by construction.
  final double saturation;

  /// Roll the highlights off with the extended-Reinhard shoulder instead of
  /// clipping them. Off reproduces what a plain decode does.
  final bool highlightRolloff;

  /// Rotation and crop. Applied to the scene-referred buffer before anything
  /// else, so the histogram and the automatic grey point describe the crop.
  final Geometry geometry;

  const Edit({
    this.temperatureK,
    this.blackEv = 0,
    this.shadowEv = 0,
    this.highlightEv = 0,
    this.whiteEv = 0,
    this.brightnessEv = 0,
    this.contrastEv = 0,
    this.sharpness = 0,
    this.saturation = 0,
    this.highlightRolloff = false,
    this.geometry = Geometry.identity,
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
      saturation == 0 &&
      !highlightRolloff &&
      geometry.isIdentity;

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
    double? saturation,
    bool? highlightRolloff,
    Geometry? geometry,
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
        saturation: saturation ?? this.saturation,
        highlightRolloff: highlightRolloff ?? this.highlightRolloff,
        geometry: geometry ?? this.geometry,
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
      other.saturation == saturation &&
      other.highlightRolloff == highlightRolloff &&
      other.geometry == geometry;

  @override
  int get hashCode => Object.hash(temperatureK, blackEv, shadowEv, highlightEv,
      whiteEv, brightnessEv, contrastEv, sharpness, saturation,
      highlightRolloff, geometry);

  /// True when only the tonal controls differ, so a re-render can reuse the
  /// cached geometry-applied buffer instead of resampling again.
  bool sameGeometryAs(Edit other) => other.geometry == geometry;

  // ── Serialisation ───────────────────────────────────────────────────────
  //
  // An edit outlives the build that made it, which is what the version is for.
  // Three rules, from PLAN.md section 6:
  //
  //   Every document carries `v`. It is the whole reason a stored edit
  //   survives the app changing.
  //
  //   Absent means default, never zero. A field added in v2 is missing from
  //   every v1 document, so `fromJson` fills from this class's own defaults —
  //   an old document reads as an old edit rather than as one with a black
  //   point of zero the photographer never chose.
  //
  //   Only what the photographer chose. No derived values: not the automatic
  //   grey point, not the render time, not the preview size. Those are
  //   properties of the decode and will be recomputed.

  /// The version this build writes. Bump it when a field changes meaning —
  /// not when one is merely added, which the default rule already covers.
  static const int jsonVersion = 1;

  Map<String, Object?> toJson() => {
        'v': jsonVersion,
        // Omitted entirely when null, because null is "as shot" and absent
        // means default: writing it as a number would freeze whatever the
        // camera happened to record into a choice the photographer never made.
        if (temperatureK != null) 'temperatureK': temperatureK,
        'blackEv': blackEv,
        'shadowEv': shadowEv,
        'highlightEv': highlightEv,
        'whiteEv': whiteEv,
        'brightnessEv': brightnessEv,
        'contrastEv': contrastEv,
        'sharpness': sharpness,
        'saturation': saturation,
        'highlightRolloff': highlightRolloff,
        'geometry': geometry.toJson(),
      };

  /// Rebuild a stored edit.
  ///
  /// Accepts every version this build has ever written. A document from a
  /// *newer* build throws instead: an older reader refusing a newer document
  /// is better than one silently misreading it, which is the same reasoning
  /// PLAN.md section 5 applies to the schema.
  factory Edit.fromJson(Map<String, Object?> json) {
    final v = (json['v'] as num?)?.toInt();
    if (v == null) {
      throw const FormatException('A stored edit has no version.');
    }
    if (v > jsonVersion) {
      throw FormatException(
          'A stored edit is version $v; this build reads up to $jsonVersion.');
    }

    // Every read goes through a default. Unknown keys are ignored rather than
    // rejected, so a v1 build survives meeting a document a v2 build wrote.
    const defaults = Edit.neutral;
    double d(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;

    final geometry = json['geometry'];
    return Edit(
      temperatureK: (json['temperatureK'] as num?)?.toDouble(),
      blackEv: d('blackEv', defaults.blackEv),
      shadowEv: d('shadowEv', defaults.shadowEv),
      highlightEv: d('highlightEv', defaults.highlightEv),
      whiteEv: d('whiteEv', defaults.whiteEv),
      brightnessEv: d('brightnessEv', defaults.brightnessEv),
      contrastEv: d('contrastEv', defaults.contrastEv),
      sharpness: d('sharpness', defaults.sharpness),
      saturation: d('saturation', defaults.saturation),
      highlightRolloff:
          json['highlightRolloff'] as bool? ?? defaults.highlightRolloff,
      geometry: geometry is Map<String, Object?>
          ? Geometry.fromJson(geometry)
          : defaults.geometry,
    );
  }
}

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

/// The vibrance control's range. Deliberately the same as saturation's, so the
/// two sliders in the Colour section read on one scale and +50 means the same
/// strength of boost on both.
const double vibranceRange = 50.0;

/// An opt-in look, applied on top of every control rather than instead of one.
///
/// An enum rather than a boolean because a second look should be a value, not a
/// migration of every stored document (PLAN.md section 6). Serialised by
/// **name**, so inserting a value here cannot reinterpret an edit already on
/// disk.
enum CameraLook {
  /// No look. Sliders at zero mean the scene-referred neutral render, and the
  /// output is byte-identical to a build that has never heard of this enum.
  none(gain: 1.0, saturationBoost: 0.0),

  /// A fixed base curve plus the colour that goes with it. Reproduces a plain
  /// LibRaw decode's tonality; see tone.dart for the curve.
  camera(gain: 1.431, saturationBoost: 20.0);

  const CameraLook({required this.gain, required this.saturationBoost});

  /// `k` in `base(v) = srgbDecode(dcrawEncode(k * v))`.
  ///
  /// Only read when the look is not [none]. `none` carries 1.0 to keep the row
  /// complete, and [isNone] short-circuits before the curve is ever evaluated —
  /// `k = 1` is *not* the identity, because the curve is still dcraw's.
  final double gain;

  /// What the look contributes, in the units of [Edit.saturation]. Composed
  /// multiplicatively with the slider, which stays at zero.
  final double saturationBoost;

  bool get isNone => this == CameraLook.none;
}

/// Read a stored look by name.
///
/// `CameraLook.values.byName` throws on an unknown name; a catalogue row is not
/// the place for that. Anything unrecognised — a look a later build wrote, or a
/// value that is not a string at all — falls back to the default.
CameraLook _cameraLook(Object? raw, CameraLook fallback) {
  if (raw is String) {
    for (final look in CameraLook.values) {
      if (look.name == raw) return look;
    }
  }
  return fallback;
}

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

  /// Vibrance, −50 … +50. Saturation weighted by how flat the pixel already
  /// is: `1 + (v / vibranceRange) × (1 − current)`, so it lifts washed-out
  /// colour and leaves an already-vivid sky alone. `v / vibranceRange` is
  /// numerically `ria_adjustments.vibrance`.
  final double vibrance;

  /// Roll the highlights off with the extended-Reinhard shoulder instead of
  /// clipping them. Off reproduces what a plain decode does.
  final bool highlightRolloff;

  /// Ask LibRaw to reconstruct the highlights that clipped in camera space,
  /// rather than clipping them at the decode.
  ///
  /// Changing it re-decodes the file, which is why it lives on the `Edit`
  /// rather than beside the display controls. LibRaw rescales the whole frame
  /// when it reconstructs; the library reports that scale and every EV
  /// computation divides by it, so flipping this does not move the exposure —
  /// it only puts detail back where there was a flat white patch.
  final bool highlightRecovery;

  /// An opt-in fixed look: a base curve in the gain table plus the saturation
  /// that goes with it, applied on top of every control. [CameraLook.none] is
  /// the scene-referred neutral render, byte for byte.
  final CameraLook cameraLook;

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
    this.vibrance = 0,
    this.highlightRolloff = false,
    this.highlightRecovery = false,
    this.cameraLook = CameraLook.none,
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
      vibrance == 0 &&
      !highlightRolloff &&
      !highlightRecovery &&
      cameraLook.isNone &&
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
    double? vibrance,
    bool? highlightRolloff,
    bool? highlightRecovery,
    CameraLook? cameraLook,
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
        vibrance: vibrance ?? this.vibrance,
        highlightRolloff: highlightRolloff ?? this.highlightRolloff,
        highlightRecovery: highlightRecovery ?? this.highlightRecovery,
        cameraLook: cameraLook ?? this.cameraLook,
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
      other.vibrance == vibrance &&
      other.highlightRolloff == highlightRolloff &&
      other.highlightRecovery == highlightRecovery &&
      other.cameraLook == cameraLook &&
      other.geometry == geometry;

  @override
  int get hashCode => Object.hash(temperatureK, blackEv, shadowEv, highlightEv,
      whiteEv, brightnessEv, contrastEv, sharpness, saturation, vibrance,
      highlightRolloff, highlightRecovery, cameraLook, geometry);

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
        'vibrance': vibrance,
        'highlightRolloff': highlightRolloff,
        'highlightRecovery': highlightRecovery,
        // By name, never by ordinal: inserting a value into the enum later
        // must not reinterpret every edit already on disk.
        'cameraLook': cameraLook.name,
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
      vibrance: d('vibrance', defaults.vibrance),
      highlightRolloff:
          json['highlightRolloff'] as bool? ?? defaults.highlightRolloff,
      // No `jsonVersion` bump: "absent means default" already covers a field
      // that is merely added, and every document written before this build
      // reads back as recovery off — which is what it was rendered with.
      highlightRecovery:
          json['highlightRecovery'] as bool? ?? defaults.highlightRecovery,
      // By name, and tolerant: absent covers every document written before this
      // build, and an unrecognised name covers a look this build has never
      // heard of. The version guard above already refuses a higher `v`, so that
      // can only arise within one version — and rendering a known-neutral frame
      // beats throwing on a catalogue row.
      cameraLook: _cameraLook(json['cameraLook'], defaults.cameraLook),
      geometry: geometry is Map<String, Object?>
          ? Geometry.fromJson(geometry)
          : defaults.geometry,
    );
  }
}

# Morphosis

A non-destructive camera RAW editor for Linux desktop, built on
[raw_images_api](../raw_images_api).

Browse to a folder, pick a frame, and adjust colour temperature, four
exposure zones, brightness, contrast and sharpness with the canvas following
each slider. Export to 16-bit TIFF or JPEG.

**The RAW file is never written to.** It is opened read-only, the adjustments
live in memory, and an export decodes the file again and writes a new one at a
path you choose. `tool/pipeline_check.dart` asserts the source is
byte-identical after a full edit-and-export cycle.

---

## Build and run

```bash
scripts/setup.sh                 # system packages + flutter pub get
flutter run -d linux             # or: flutter build linux --release
```

`raw_images_api` is expected beside this checkout and is built from source as
part of the Flutter Linux build. To use a checkout elsewhere:

```bash
RAW_IMAGES_API_DIR=/path/to/raw_images_api flutter build linux --release
```

The resulting bundle loads `lib/libraw_images_api.so` from beside its own
executable, so it relocates as a unit.

A folder can be passed on the command line, which skips the browse step:

```bash
./build/linux/x64/release/bundle/morphosis ~/photos/2026-09-02
```

## Checks

```bash
flutter test                                    # unit, widget and golden
dart run tool/pipeline_check.dart /tmp/out ~/photos/*.NEF
```

`pipeline_check` is the end-to-end one: it decodes real camera files, reads
their colour temperature, times each stage, exports both formats, and verifies
the source RAW is unchanged. It loads the release bundle's library, so
`flutter build linux --release` has to have run first.

Measured on a 24 MP NEF and a 33 MP CR3, release build:

| stage | time |
|---|---|
| open + read metadata and colour data | 1–2 ms |
| scene-linear decode to a 1600 px preview | 1.9 s |
| fused render pass (1.7 MP) | 60–70 ms |
| unsharp mask | 60 ms |
| histogram | 3–4 ms |
| full-resolution TIFF export | 5–7 s |
| full-resolution JPEG export | 10–14 s |

## Design

[raw_images_api's approach.md](../raw_images_api/approach.md) is the design
this implements. The short version, and the three places this app deviates
from it — each deviation is argued at the point it happens in the source.

### Two domains, and one fused pass between them

Decoding uses `ria_decode_options_scene_linear` unchanged: gamma 1.0, 16-bit,
no auto-brightness, highlights clipped. That preset is what makes 1.0 mean
sensor saturation on every file, and therefore what makes "−2 EV" mean the
same thing on two different frames. The default display-referred decode clips
1.4–2.3% of the frame before any adjustment is applied and folds in a
scene-dependent +1.7 EV of auto-brightness — neither of which a control
calibrated in stops can survive.

Everything specified in EV happens on that linear data:

```
  RAW file
     │  ria_raw_decode, scene-linear preset          ria_fit_within → preview
     ▼
  ┌──────────────────────────────────────────────┐
  │  SCENE-REFERRED   1.0 = sensor saturation    │
  │    white balance / colour temperature        │  colour_temp.dart
  │    zone EV: black, shadow, highlight, white  │  tone.dart
  │    contrast                                  │
  │    analysis: EV histogram, auto grey point   │  render.dart
  └──────────────────────────────────────────────┘
     │  display transform: grey point, shoulder, sRGB
     ▼
  ┌──────────────────────────────────────────────┐
  │  DISPLAY-REFERRED   8 or 16-bit encoded      │
  │    unsharp mask            ria_unsharp_mask  │
  │    256-bin histogram   ria_compute_histogram │
  └──────────────────────────────────────────────┘
     ▼  screen, JPEG, TIFF
```

The two boxes are **never materialised separately**. `renderRgb8` computes
luminance, looks up the tone gain, scales, applies the shoulder, encodes and
quantises — all in local variables. A pixel the tone engine pushes to 4.0 is
held in a register, rolled off, and lands inside [0,1] before anything is
stored. Written to a 16-bit buffer in between it would clamp at 1.0 first and
the shoulder would have nothing left to compress, which produces a
plausible-looking image with flat highlights and no error anywhere. That is a
correctness requirement, not an optimisation, and `test/tone_test.dart` has
the test approach.md §11 specifies for catching it.

### Where the controls live

| control | domain | what it is |
|---|---|---|
| Colour temperature | scene | per-channel scale in camera space, as a 3×3 on the decoded frame |
| Black / Shadow / Highlight / White | scene | zone EV, applied as a luminance-preserving gain |
| Brightness | display | the transform's grey point — a midtone placement |
| Contrast | scene | slope `2^(c/3)` about the midtone, on luminance only |
| Sharpness | display | `ria_unsharp_mask`, applied last |

Brightness is the grey point rather than a second exposure control, following
approach.md §8: a linear scale *is* exposure, and offering both would be two
sliders doing one job. What is left over — a midtone lift with the endpoints
anchored — is exactly what a display grey point does.

Contrast acts on luminance, not per channel, so hue never moves. That is the
predictable choice and it costs some apparent colourfulness; the remedy, if
you want it, is saturation, which is a separate control this app does not yet
expose.

### Deviation 1 — the zone controls are anchored to display white

approach.md §6 places the zone knots at (−8, −4, −1.5, 0) EV **relative to
sensor saturation**. The numbers are right and the anchor is not: a
scene-linear decode leaves the 99.5th percentile around −1.8 EV, so anchored to
saturation the top zone sits above anything the display ever shows, and a
"white level" control acts entirely on range the viewer cannot see.

Anchored to display white instead — `centre + log2(greyPoint / 0.18)` — the
same numbers land where Lightroom's regions land, around 12%, 30%, 75% and 95%
of the output. The controls then act on the tonal regions their labels name.

The grey point that anchors them is itself measured per frame: the 99.5th
percentile of scene luminance mapped to display white. This is the job
LibRaw's auto-brightness normally does invisibly; the scene-linear preset
turns it off precisely so it can be done in one visible place. It comes out at
+1.77 EV on the Nikon test frame and +1.32 EV on the Canon, bracketing the
+1.7 EV that approach.md §0 measured LibRaw applying.

### Deviation 2 — overlapping zone basis functions

approach.md §6 specifies smoothstep ramps between knots, so exactly two
weights are non-zero anywhere. §7 then shows why that cannot stand: smoothstep's
derivative peaks at `1.5 / span`, so two adjacent controls pulled apart by
more than about `span / 1.5` drive the tone curve slope negative and solarise
the image. Measured on that basis, *shadows +1.5, highlights −1.0* — the most
ordinary edit there is — was already being scaled back to 76% of what the
sliders claimed.

§7's third remedy is taken instead: each zone is a Gaussian normalised against
the other three. Still a partition of unity, so the analysis and the
adjustment cannot disagree about what a shadow is; C-infinity rather than
C-one, so no setting leaves a crease; and the peak derivative drops by roughly
a factor of three, which moves the first fold-over out past 4 EV of
opposition. The cost, which §7 names: at its own centre a zone carries about
70% of the weight rather than all of it, so the controls are less independent.

`softLimitFactor` is still there for the extremes — it scales all four zone
deltas by one common factor until the curve is monotonic again, preserving the
shape asked for rather than clamping one control — and the panel says so
rather than letting the sliders silently under-deliver.

### Deviation 3 — sRGB encoding rather than LibRaw's curve

`ria_display_transform` defaults to LibRaw's own output curve, a power of
2.222 with a 4.5 toe, and reproducing it exactly is what makes
`RIA_DISPLAY_CLIP` match a plain decode. This app encodes sRGB. Flutter
composites the canvas as sRGB and every viewer that opens an exported file
assumes sRGB, so encoding anything else leaves the preview and the export each
slightly wrong in the same direction with nothing to say so. The two curves
differ only in the toe.

### Colour temperature

`ria_raw_color_data` — added to the library for this app — returns the raw
materials and stops there, which is the position PLAN.md §1 argues for: LibRaw
gives the inputs, never the answer. Two routes, and the panel says which one
produced the number:

- **Camera table**, when the body wrote one. Canon does (15 rows, 2400–10900 K
  on the EOS R7); Nikon does not. Interpolated in *mired*, because the tables
  are near-uniform in mired and wildly non-uniform in Kelvin — interpolating in
  Kelvin biases every result warm.
- **Colorimetric**, always available. Camera neutral → `cam_xyz⁻¹` → XYZ → xy →
  nearest point on the Planckian locus, by ternary search in mired. The
  perpendicular distance falls out of the same search and *is* the tint.

Checked against the R7's own table: the colorimetric route puts the as-shot
temperature at 5591 K where the camera says 5786 K, and reproduces the table's
red multipliers to within 2.5% across the whole range. A single Kelvin figure
cannot describe that frame's white balance — its red ratio implies above
6000 K while its blue ratio implies below 5600 K — so the Duv is reported
beside it rather than averaged away, and the control disables itself entirely
when the illuminant is too far off the locus for a Kelvin figure to mean
anything.

Adjusting is approach.md §5's Mode B, made exact rather than approximate. The
decode produced `P = rgb_cam · diag(m₀) · raw`, so re-balancing is

```
P' = rgb_cam · diag(m/m₀) · rgb_cam⁻¹ · P
```

with `rgb_cam` rebuilt the way dcraw builds it. Any global normalisation
LibRaw folded in cancels in the ratio, and the per-channel scale happens in
camera space, where a white balance is defined. What it cannot do is rebuild a
channel that clipped in camera space during the decode; over the few hundred
Kelvin a slider is normally dragged that is invisible, and past a couple of
thousand the panel says so. Export re-decodes at full resolution, so the
written file is closer to exact than the preview was.

## Layout

```
lib/
  main.dart                    entry point; optional folder argument
  src/
    model/edit.dart            the edit — one immutable value
    ria/
      bindings.dart            dart:ffi declarations, mirroring raw_images_api.h
      ria.dart                 open, decode, sharpen, measure
    pipeline/
      colour_temp.dart         CCT, tint, and the re-balancing matrix
      tone.dart                zone basis, tone curve, display table
      render.dart              the fused pass, and the EV histogram
      export.dart              TIFF writer, JPEG encoder, the one file write
      processor.dart           the worker isolate and the export isolate
    ui/
      editor_screen.dart       state: opening files, coalescing renders
      editor_layout.dart       arrangement, as a function of that state
      controls_panel.dart      the control stack, in pipeline order
      histogram_view.dart      three additive channel curves
      photo_list.dart          the folder, with embedded-JPEG thumbnails
      adjust_slider.dart       one slider, and the panel's small parts
      export_dialog.dart       format and quality
tool/
  make_icon.py                 the app icon, from icons/butterfly-image.png
  pipeline_check.dart          end-to-end check against real camera files
```

Two isolates behind the UI. A long-lived worker owns the decoded
scene-referred buffer, the native display buffer and the FFI handle — the
buffer is 100–200 MB and would otherwise be copied on every slider frame.
Export runs on its own throwaway isolate, because a full-resolution decode is
seconds of work and several hundred megabytes that should not stall the
preview or stay resident afterwards.

Renders are coalesced: at most one pass in flight, with the most recent edit
queued behind it. A slider drag emits far more changes than a 65 ms pass can
absorb, and queuing them all would leave the canvas seconds behind the thumb.

## Library changes

One addition to `raw_images_api`, `ria_raw_color_data` — purely additive, no
existing ABI touched, all 304 library tests still pass. It exposes
`cam_mul`, `pre_mul`, `cam_xyz` and the camera's `WBCT_Coeffs` table, which
are the four inputs a colour temperature is derived from and the only ones
LibRaw does not surface through the existing API. The derivation stays in
Dart, in `colour_temp.dart`, because it is a matter of judgement — which
locus, which method, and whether the answer is meaningful at all — and
PLAN.md §5 leaves that judgement open.

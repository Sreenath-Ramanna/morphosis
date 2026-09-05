# Morphosis

A non-destructive camera RAW editor for Linux desktop, built on
[raw_images_api](https://github.com/Sreenath-Ramanna/raw_images_api).

Browse to a folder, pick a frame, and adjust colour temperature, four
exposure zones, brightness, contrast, saturation, vibrance and sharpness with
the canvas following each slider. Export to 16-bit TIFF or JPEG.

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

The GNOME header bar is restyled to 32 px — the window buttons and nothing
else, in the application's own colours. The name and the icon live in the
toolbar immediately below it, so repeating them above bought nothing and cost
most of the height. See `apply_compact_titlebar_css` in
`linux/runner/my_application.cc`.

## The three tabs

**Colour** holds every tonal control: white balance, the four exposure zones,
brightness, contrast, saturation, vibrance and sharpness, with the histogram
above them.

**Crop** holds rotation in quarter turns, a straighten slider, and the aspect
constraints; the rectangle itself is dragged on the canvas, where pan and zoom
are switched off so the two gestures cannot be confused and the whole frame
stays visible.

**Masks** is a placeholder. It will hold selections that confine an adjustment
to part of the frame — a sky, a face, a shadow — and it says so rather than
being hidden, since a tab strip that grows an entry later moves the others
under the cursor.

## The catalogue

Morphosis remembers the frames it has worked on: what they were called, when
they were taken, what keywords you gave them, and what adjustments you made.
The keyword editor is the bottom of the left column.

**A photograph is identified by its content, not by its path.** The key is a
SHA-256 digest of the file, so keywords and adjustments follow a frame that is
copied to a NAS, moved, renamed or restored from a backup. They do not follow a
conversion to DNG, or a file another program has written XMP into — those are
different bytes, and the digest is honest about that rather than guessing.

Hashing costs about a third of a second for a 30 MB frame, against a second and
a half to decode it, and the two run together. A folder is never hashed on
open: listing three hundred frames would be ninety seconds of it. Files are
looked up by path, size and modification time, and only hashed when actually
opened.

Reopening a frame puts its adjustments back and says so, with one click to
revert. Adjustments are written two seconds after you stop moving a slider —
once per drag, not once per frame of it — and at once when you type a keyword,
export, or leave the frame.

The catalogue lives at
`~/.local/share/com.morphosis.morphosis/catalog.db`. It is SQLite behind an
interface that does not mention SQL, so it can be replaced without touching
anything that uses it. Deleting the file loses the keywords and the stored
edits; it never touches a photograph. **No RAW file is ever written to.**

### Where geometry happens

Rotation and crop are applied to the **scene-referred buffer, before the tone
engine**, and the result is cached until the geometry changes again. Three
things follow, and all three are the reason for the ordering:

- Resampling is an average of neighbouring pixels, and an average only means
  anything where the values are proportional to light. Averaging
  gamma-encoded values darkens every edge it touches by an amount that depends
  on the local contrast — the same argument that puts exposure in the
  scene-referred domain puts rotation there.
- The histogram and the automatic grey point are measured from the cropped
  buffer, so both describe what the viewer is looking at rather than the frame
  it was cut from. Cropping to a bright corner re-exposes the image, which is
  what an editor is expected to do.
- The tone pass is unchanged and still runs its fast path, because the
  geometry has already been resolved by the time it sees the pixels.

The crop is stored as fractions of the frame rather than pixels, so it means
the same thing on the 1600 px preview and on the full-resolution export. That
is asserted end to end: `tool/pipeline_check.dart` exports a turned,
straightened, cropped frame and checks the file's own dimensions against what
the geometry predicts.

Straightening leaves wedges of nothing at the corners, so the crop is pulled
in to the largest rectangle that fits entirely inside the turned frame. A crop
placed before the frame was levelled is fitted inside those new bounds rather
than being allowed to reveal black.

## Keyboard

| key | |
|---|---|
| `←` `→` | previous / next frame in the folder |
| `=` `-` | zoom in / out, about the centre of the view |

Zoom steps by a quarter each press, between 0.5× and 8× — the same bounds a
pinch is held to — and returns to fit-the-window when a new frame is opened.
`+` and the numeric keypad's `+` and `-` do the same as `=` and `-`.

Navigation clamps at the ends of the folder rather than wrapping, and is
ignored while a decode is in flight, so holding a key does not queue up a
second and a half of work per repeat.

The sliders are deliberately excluded from keyboard focus. A focused Flutter
`Slider` handles the arrow keys itself, which would make "left is the previous
frame" work until the first time you touched a slider and then quietly stop.

A folder can be passed on the command line, which skips the browse step:

```bash
./build/linux/x64/release/bundle/morphosis ~/photos/2026-09-02
```

## Install

```bash
scripts/install.sh              # build the release bundle, then install
scripts/install.sh --no-build   # install what is already built
scripts/install.sh --uninstall
```

No root is needed. The bundle is **copied** to `~/.local/lib/morphosis/`
rather than linked, because a `.desktop` Exec records an absolute path and
pointing it into `build/` means a `flutter clean` silently breaks the menu
entry. A `morphosis` symlink goes in `~/.local/bin`.

| | |
|---|---|
| `~/.local/lib/morphosis/` | the bundle — deleted and rewritten on every install |
| `~/.local/share/com.morphosis.morphosis/` | the catalogue — user data, never installed over |
| `~/.local/bin/morphosis` | symlink onto the bundle |

The two directories are deliberately apart. Installing begins by deleting the
bundle prefix, so sharing one directory with the catalogue would discard every
keyword and every stored edit on each install, silently. `install.sh` refuses
to run if it finds a `catalog.db` in the prefix.

Installing is what makes the icon appear under Wayland at all. A compositor
ignores the icon a process sets on its own window and instead matches the
window's **app id** against a `.desktop` file, taking the icon from there. So
three strings have to agree, and a mismatch fails silently with nothing
logged:

| | |
|---|---|
| `APPLICATION_ID` in `linux/CMakeLists.txt` | `com.morphosis.morphosis` |
| `linux/packaging/…desktop` basename, `Icon=`, `StartupWMClass=` | `com.morphosis.morphosis` |
| installed icons, `hicolor/*/apps/….png` | `com.morphosis.morphosis` |

That the window really reports it is measured rather than assumed — `xprop`
gives `WM_CLASS = "com.morphosis.morphosis", "Com.morphosis.morphosis"`.

The entry declares RAW MIME types and `inode/directory`, so opening a RAW file
from a file manager opens the folder that holds it with that frame selected.

## Checks

```bash
flutter test                                    # unit, widget and golden
./scripts/check-ffi.sh                          # stamp, enum values, symbols
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
| the same pass with saturation or vibrance off zero | 90–115 ms |
| unsharp mask | 60 ms |
| histogram | 3–4 ms |
| full-resolution TIFF export | 19–20 s |
| full-resolution JPEG export | 22–23 s |

The two export figures are dominated by the decode, and are deliberate. Export
demosaics with AAHD where the preview uses the library's default PPG: it
resolves the most fine detail of the seven algorithms LibRaw offers, for about
11 s more on a 33 MP frame. Morphosis produces images for print and
presentation, and export is the one path where that is settled, so it buys the
best reconstruction available. The preview does not, because it is resampled to
1600 px and the differences between these algorithms do not survive that.

[PLAN.md](PLAN.md) covers the catalogue, which is planned and not yet built.

## Design

[raw_images_api's approach.md](https://github.com/Sreenath-Ramanna/raw_images_api/blob/master/approach.md) is the design
this implements. The short version, and the four places this app deviates
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
  │    saturation, vibrance                      │  render.dart
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
| Camera look | scene → display | an opt-in fixed base curve in the gain table, plus saturation +20 — every slider stays at zero |
| Contrast | scene | slope `2^(c/3)` about the midtone, on luminance only |
| Saturation | display | distance from luma × (1 + s/50), limited per pixel so no channel leaves range |
| Vibrance | display | the same, weighted by 1 − how saturated the pixel already is |
| Sharpness | display | `ria_unsharp_mask`, applied last |

Brightness is the grey point rather than a second exposure control, following
approach.md §8: a linear scale *is* exposure, and offering both would be two
sliders doing one job. What is left over — a midtone lift with the endpoints
anchored — is exactly what a display grey point does.

Contrast acts on luminance, not per channel, so hue never moves. That is the
predictable choice and it costs some apparent colourfulness; the remedy, if
you want it, is Saturation, in the Colour section — a separate control, on
purpose, so that restoring colourfulness is something you ask for rather than
something the contrast slider does behind you. Camera look is those two
together with the values chosen rather than dragged: a fixed base curve —
`srgbDecode(dcrawEncode(1.431·v))`, LibRaw's own output curve re-expressed as a
remap of linear light — composed into the gain table after everything else, and
the saturation lift of +20 that goes with it. The sliders still read 0.00 and
still act relative to it.

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

### Deviation 4 — saturation is gamut-limited, not clamped

The operation is the library's: `c' = y + (c − y)·f`, with `y` the Rec.709
luma of the encoded values and `f = 1 + s/50`, so the slider value divided by
50 is numerically `ria_adjustments.saturation` and the two implementations
agree by construction on the arithmetic. Vibrance multiplies a second factor
into the same `f` — `1 + (v/50)·(1 − current)`, where `current` is
`(max − min) / max`, how saturated the pixel already is — which is again the
library's own definition, and again on the same 1:1 scale. One factor reaches
the pixel, so the two controls compose without a second pass or a second
rounding step.

They part company at the gamut edge. `saturate()`
(`raw_images_api/src/ria_adjust.c:134-154`) clamps each channel independently
after scaling. Clamping one channel and not the others changes the ratios
between them, which is what hue *is* — so a blue sky boosted past the edge
comes back purple, and the failure grows with the setting exactly where the
photographer is looking.

Morphosis reduces `f` per pixel instead, to the largest value that keeps all
three channels inside the output range, and applies that one number to all
three distances. A pixel already at the edge takes as much of the boost as it
can and no more; its hue direction never moves. The two agree exactly on every
in-gamut pixel and differ only where the C version would have clipped.

The price is that a saturated pixel stops responding to the slider before an
unsaturated one does. That is the honest behaviour: the display has nowhere to
put the colour being asked for, and rotating the hue to fake it is not an
answer. `test/render_test.dart`'s `group('saturation')` holds this as
properties — luma preserved at every setting, the channel order never
reordered, and the hue direction held on both an in-gamut pixel and one at the
edge.

### Colour temperature

`ria_raw_color_data` — added to the library for this app — returns the raw
materials and stops there, which is the position [raw_images_api's
PLAN.md](https://github.com/Sreenath-Ramanna/raw_images_api/blob/master/PLAN.md) §1 argues for: LibRaw
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
    model/geometry.dart        rotation and crop, as a value
    ria/
      bindings.dart            dart:ffi declarations, mirroring raw_images_api.h
      ria.dart                 open, decode, sharpen, measure
    pipeline/
      colour_temp.dart         CCT, tint, and the re-balancing matrix
      tone.dart                zone basis, tone curve, display table
      geometry_ops.dart        rotation and crop, on scene-referred pixels
      render.dart              the fused pass, and the EV histogram
      export.dart              TIFF writer, JPEG encoder, the one file write
      processor.dart           the worker isolate and the export isolate
    ui/
      editor_screen.dart       state: opening files, coalescing renders
      editor_layout.dart       arrangement, as a function of that state
      controls_panel.dart      the control stack, in pipeline order
      canvas_zoom.dart         the canvas transform, driveable from a key
      right_panel.dart         the tab strip, and the masks placeholder
      crop_panel.dart          rotate, straighten and aspect controls
      crop_overlay.dart        the crop rectangle, dragged on the canvas
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
[raw_images_api's PLAN.md](https://github.com/Sreenath-Ramanna/raw_images_api/blob/master/PLAN.md) §5 leaves that judgement open.

## Licence

MIT — see [LICENSE](LICENSE).

### Third-party

The MIT licence covers this repository's own source. A built application also
contains, and is governed by the terms of:

| component | licence |
|---|---|
| [LibRaw](https://www.libraw.org/) | LGPL-2.1-only **or** CDDL-1.0, with parts BSD-3-Clause |
| [raw_images_api](https://github.com/Sreenath-Ramanna/raw_images_api) | MIT |
| Flutter, `package:ffi`, `package:path` | BSD-3-Clause |
| `package:image`, `package:file_picker`, `package:sqlite3` | MIT |
| `package:crypto` | BSD-3-Clause |
| SQLite | public domain |

LibRaw is the one with conditions attached. It is **dynamically linked** — the
bundle loads `lib/libraw_images_api.so`, which in turn resolves `libraw_r.so`
from the system — so a recipient can replace it, which is what LGPL-2.1 §6
asks of anyone distributing binaries. Distribute a build and that obligation
is yours to honour; publishing source carries none of it.

The RAW processing algorithms here are reimplemented from published
descriptions — the Planckian locus, Robertson's method, Bradford adaptation,
extended Reinhard. No code is taken from darktable or RawTherapee, which are
GPL applications.

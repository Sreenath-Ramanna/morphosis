// lib/src/ui/editor_layout.dart
//
// The editor's arrangement, as a pure function of state.
//
// Split out from EditorScreen so that everything on screen can be built from
// plain values, with no isolate, no FFI handle and no decoded frame behind
// it. That is what makes the layout testable — `test/layout_golden_test.dart`
// renders this at window size against synthetic data — and it keeps the
// stateful half to what it is actually about: opening files and coalescing
// renders.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog/catalog.dart';
import '../model/edit.dart';
import '../model/geometry.dart';
import '../pipeline/processor.dart';
import '../ria/ria.dart';
import 'canvas_zoom.dart';
import 'controls_panel.dart';
import 'crop_overlay.dart';
import 'crop_panel.dart';
import 'keyword_panel.dart';
import 'photo_list.dart';
import 'right_panel.dart';
import 'theme.dart';

/// Everything the arrangement needs to know.
class EditorViewState {
  final String? folder;
  final List<PhotoEntry> photos;
  final Map<String, Uint8List?> thumbnails;
  final int selected;

  final FrameInfo? frame;
  final ui.Image? image;
  final Histogram? histogram;
  final Edit edit;
  final double softLimitFactor;

  /// Which right-hand tab is open. The canvas reads it too: crop mode shows
  /// the whole straightened frame with a rectangle over it, and switches pan
  /// and zoom off.
  final EditorTab tab;

  final bool loading;
  final bool exporting;
  final String? status;
  final String? error;
  final int renderMillis;

  /// What the catalogue holds for the frame on screen. Null when there is no
  /// frame, or no catalogue — the editor works without one.
  final CatalogEntry? entry;

  /// Every keyword used so far, for autocomplete.
  final List<KeywordCount> knownKeywords;

  /// Set when the adjustments on screen were restored from the catalogue
  /// rather than made in this session. Drives the banner, and is cleared by
  /// the first slider move.
  final DateTime? restoredFrom;

  const EditorViewState({
    this.folder,
    this.photos = const [],
    this.thumbnails = const {},
    this.selected = -1,
    this.frame,
    this.image,
    this.histogram,
    this.edit = Edit.neutral,
    this.softLimitFactor = 1.0,
    this.tab = EditorTab.colour,
    this.loading = false,
    this.exporting = false,
    this.status,
    this.error,
    this.renderMillis = 0,
    this.entry,
    this.knownKeywords = const [],
    this.restoredFrom,
  });
}

// ── Keyboard ──────────────────────────────────────────────────────────────

class PreviousImageIntent extends Intent {
  const PreviousImageIntent();
}

class NextImageIntent extends Intent {
  const NextImageIntent();
}

class ZoomInIntent extends Intent {
  const ZoomInIntent();
}

class ZoomOutIntent extends Intent {
  const ZoomOutIntent();
}

/// The bindings, resolved from the focused node upwards.
///
/// `equal` and `minus` are the unshifted keys asked for. The three extra
/// activators are the same gesture on different hardware rather than extra
/// features: shift+equal is what a `+` physically is on a US layout, and a
/// numeric keypad sends its own logical keys for `+` and `-`.
const Map<ShortcutActivator, Intent> editorShortcuts = {
  SingleActivator(LogicalKeyboardKey.arrowLeft): PreviousImageIntent(),
  SingleActivator(LogicalKeyboardKey.arrowRight): NextImageIntent(),

  SingleActivator(LogicalKeyboardKey.equal): ZoomInIntent(),
  SingleActivator(LogicalKeyboardKey.equal, shift: true): ZoomInIntent(),
  SingleActivator(LogicalKeyboardKey.add): ZoomInIntent(),
  SingleActivator(LogicalKeyboardKey.numpadAdd): ZoomInIntent(),

  SingleActivator(LogicalKeyboardKey.minus): ZoomOutIntent(),
  SingleActivator(LogicalKeyboardKey.numpadSubtract): ZoomOutIntent(),
};

class EditorLayout extends StatelessWidget {
  final EditorViewState state;
  final VoidCallback? onBrowse;
  final VoidCallback? onExport;
  final ValueChanged<int> onSelect;
  final ValueChanged<Edit> onEditChanged;

  /// Step to the adjacent frame. Null leaves the binding inert.
  final VoidCallback? onPreviousImage;
  final VoidCallback? onNextImage;

  final ValueChanged<EditorTab>? onTabChanged;

  /// Null leaves the keyword control disabled — no frame, or no catalogue.
  final ValueChanged<KeywordSet>? onKeywordsChanged;

  /// Discard the restored adjustments and go back to neutral.
  final VoidCallback? onRevertEdit;
  final ValueChanged<Geometry>? onGeometryChanged;

  /// The canvas transform, shared so the keyboard and the mouse drive the same
  /// state. Null gives the canvas its own private one, which is what the
  /// layout tests want.
  final CanvasZoom? zoom;

  const EditorLayout({
    super.key,
    required this.state,
    required this.onBrowse,
    required this.onExport,
    required this.onSelect,
    required this.onEditChanged,
    this.onPreviousImage,
    this.onNextImage,
    this.onTabChanged,
    this.onKeywordsChanged,
    this.onRevertEdit,
    this.onGeometryChanged,
    this.zoom,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: editorShortcuts,
      child: Actions(
        actions: {
          PreviousImageIntent: CallbackAction<PreviousImageIntent>(
              onInvoke: (_) => onPreviousImage?.call()),
          NextImageIntent: CallbackAction<NextImageIntent>(
              onInvoke: (_) => onNextImage?.call()),
          ZoomInIntent:
              CallbackAction<ZoomInIntent>(onInvoke: (_) => zoom?.zoomIn()),
          ZoomOutIntent:
              CallbackAction<ZoomOutIntent>(onInvoke: (_) => zoom?.zoomOut()),
        },
        // Autofocus so the bindings answer on a freshly opened window, before
        // anything has been clicked.
        child: Focus(autofocus: true, child: _body()),
      ),
    );
  }

  Widget _body() {
    return Scaffold(
      body: Column(
        children: [
          _Toolbar(
            folder: state.folder,
            onBrowse: onBrowse,
            onExport: onExport,
            exporting: state.exporting,
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  // Widened from 210. That was chosen for a filename and a
                  // thumbnail; a keyword field in it wraps after one short
                  // word. PLAN.md section 9.
                  width: 260,
                  child: ColoredBox(
                    color: Chrome.panel,
                    child: Column(
                      children: [
                        Expanded(
                          child: PhotoList(
                            photos: state.photos,
                            selected: state.selected,
                            thumbnails: state.thumbnails,
                            onSelect: onSelect,
                          ),
                        ),
                        const Divider(height: 1),
                        SizedBox(
                          // About a third of a typical window, and never less
                          // than the chips and the field need.
                          height: 210,
                          child: KeywordPanel(
                            keywords: state.entry?.keywords ??
                                KeywordSet.empty,
                            known: state.knownKeywords,
                            onChanged:
                                state.entry == null ? null : onKeywordsChanged,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _Canvas(
                    state: state,
                    zoom: zoom,
                    onGeometryChanged: onGeometryChanged,
                  ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: 320,
                  child: ColoredBox(
                    color: Chrome.panel,
                    child: Column(
                      children: [
                        TabStrip(
                          active: state.tab,
                          onChanged: onTabChanged ?? (_) {},
                          disabled: const {EditorTab.masks},
                        ),
                        Expanded(child: _tabBody()),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _StatusBar(state: state),
        ],
      ),
    );
  }

  Widget _tabBody() {
    switch (state.tab) {
      case EditorTab.colour:
        final controls = ControlsPanel(
          frame: state.frame,
          edit: state.edit,
          histogram: state.histogram,
          softLimitFactor: state.softLimitFactor,
          onChanged: onEditChanged,
        );
        final restored = state.restoredFrom;
        if (restored == null) return controls;
        // Storing adjustments and then applying them silently would surprise:
        // frames used to open neutral. So it says what it did, and offers the
        // one click back. PLAN.md section 11.
        return Column(
          children: [
            RestoredBanner(when: restored, onRevert: onRevertEdit),
            Expanded(child: controls),
          ],
        );
      case EditorTab.crop:
        return CropPanel(
          frame: state.frame,
          geometry: state.edit.geometry,
          onChanged: onGeometryChanged ?? (_) {},
        );
      case EditorTab.masks:
        return const MasksPanel();
    }
  }
}

/// "edited 2 September · revert" — what the editor says when it has put back
/// adjustments the photographer made in an earlier session.
class RestoredBanner extends StatelessWidget {
  final DateTime when;
  final VoidCallback? onRevert;

  const RestoredBanner({super.key, required this.when, this.onRevert});

  static const List<String> _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// The catalogue holds UTC; this is the one place it becomes local.
  /// PLAN.md section 12: converting in more than one place produces dates that
  /// are right for most of the year.
  static String describe(DateTime utc) {
    final local = utc.toLocal();
    return '${local.day} ${_months[local.month - 1]}';
  }

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        color: Chrome.panelRaised,
        child: Row(
          children: [
            Expanded(
              child: Text('Edited ${describe(when)} · restored',
                  style: Chrome.label),
            ),
            TextButton(
              onPressed: onRevert,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 28),
                foregroundColor: Chrome.accent,
                textStyle: const TextStyle(fontSize: 11.5),
              ),
              child: const Text('Revert'),
            ),
          ],
        ),
      );
}

/// Shown when the decoding library could not be loaded at all, which is a
/// packaging problem rather than a user error — so it says where it looked.
class LibraryMissingScreen extends StatelessWidget {
  final String detail;

  const LibraryMissingScreen({super.key, required this.detail});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off, size: 32, color: Chrome.warn),
                const SizedBox(height: 12),
                const Text('Could not load the RAW decoding library.',
                    style: TextStyle(fontSize: 15)),
                const SizedBox(height: 8),
                Text(detail,
                    textAlign: TextAlign.center, style: Chrome.label),
              ],
            ),
          ),
        ),
      );
}

class _Canvas extends StatelessWidget {
  final EditorViewState state;
  final CanvasZoom? zoom;
  final ValueChanged<Geometry>? onGeometryChanged;

  const _Canvas({
    required this.state,
    this.zoom,
    this.onGeometryChanged,
  });

  @override
  Widget build(BuildContext context) {
    final image = state.image;
    return ColoredBox(
      color: Chrome.canvas,
      child: Stack(
        children: [
          if (image != null && state.tab == EditorTab.crop)
            Positioned.fill(
              child: CropCanvas(
                image: image,
                geometry: state.edit.geometry,
                onChanged: onGeometryChanged ?? (_) {},
              ),
            )
          else if (image != null)
            Positioned.fill(
              // The zoom controller has to know how large the view is, or a
              // keyboard zoom has no centre to scale about.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  zoom?.viewport = constraints.biggest;
                  return InteractiveViewer(
                    transformationController: zoom?.transform,
                    maxScale: CanvasZoom.maxScale,
                    minScale: CanvasZoom.minScale,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: RawImage(
                        image: image,
                        fit: BoxFit.contain,
                        // The preview is a downsample of the frame, so it is
                        // almost always being scaled again to fit the canvas.
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  );
                },
              ),
            )
          else if (!state.loading)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_open_outlined,
                      size: 34, color: Chrome.textDim),
                  const SizedBox(height: 14),
                  Text(
                    state.photos.isEmpty
                        ? 'Browse to a folder of RAW files to begin.'
                        : 'Choose a frame.',
                    style: Chrome.label,
                  ),
                ],
              ),
            ),
          if (state.loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x88141416),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final String? folder;
  final VoidCallback? onBrowse;
  final VoidCallback? onExport;
  final bool exporting;

  const _Toolbar({
    required this.folder,
    required this.onBrowse,
    required this.onExport,
    required this.exporting,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      color: Chrome.panel,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Image.asset('assets/icon/app_icon_32.png', width: 20, height: 20),
          const SizedBox(width: 10),
          const Text('Morphosis',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)),
          const SizedBox(width: 18),
          OutlinedButton.icon(
            onPressed: onBrowse,
            icon: const Icon(Icons.folder_open, size: 15),
            label: const Text('Browse folder'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Chrome.text,
              side: const BorderSide(color: Chrome.divider),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              folder ?? 'No folder',
              overflow: TextOverflow.ellipsis,
              style: Chrome.label,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onExport,
            icon: exporting
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.8, color: Colors.white))
                : const Icon(Icons.download, size: 15),
            label: Text(exporting ? 'Exporting…' : 'Export'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final EditorViewState state;

  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final f = state.frame;
    return Container(
      height: 24,
      color: Chrome.panel,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              state.error ?? state.status ?? '',
              overflow: TextOverflow.ellipsis,
              style: Chrome.label.copyWith(
                  color: state.error != null ? Chrome.warn : Chrome.textDim),
            ),
          ),
          if (f != null) ...[
            Text(
              'preview ${f.previewWidth}×${f.previewHeight} '
              'of ${f.fullWidth}×${f.fullHeight}',
              style: Chrome.label.copyWith(fontSize: 10),
            ),
            const SizedBox(width: 14),
            Text('${state.renderMillis} ms',
                style: Chrome.value.copyWith(fontSize: 10)),
          ],
        ],
      ),
    );
  }
}

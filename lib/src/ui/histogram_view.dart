// lib/src/ui/histogram_view.dart
//
// The 256-bin histogram of the displayed image, drawn as three additive
// channel curves.
//
// Display-referred by construction, and that is the right domain for it: the
// widget answers "what does the image I am looking at contain", which is a
// statement about delivered code values. The scene-referred EV distribution
// that the exposure controls are anchored to is a different question with a
// different answer — the same frame reads a median of −3.1 EV linear and
// −0.7 EV encoded — and is reported separately as the median EV readout.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ria/ria.dart';
import 'theme.dart';

class HistogramView extends StatelessWidget {
  final Histogram histogram;
  final double height;

  const HistogramView({
    super.key,
    required this.histogram,
    this.height = 96,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF0E0E10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Chrome.divider),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: CustomPaint(painter: _HistogramPainter(histogram)),
          ),
        ),
        const SizedBox(height: 4),
        // Flexible on both sides: the panel is a fixed 320 px and these are
        // the only two pieces of text in it whose length is data-dependent.
        Row(
          children: [
            Flexible(
              child: _ClipBadge(
                label: 'clipped black',
                fraction: histogram.clippedBlack,
                align: TextAlign.left,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: _ClipBadge(
                label: 'white',
                fraction: histogram.clippedWhite,
                align: TextAlign.right,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ClipBadge extends StatelessWidget {
  final String label;
  final double fraction;
  final TextAlign align;

  const _ClipBadge({
    required this.label,
    required this.fraction,
    required this.align,
  });

  @override
  Widget build(BuildContext context) {
    // A tenth of a percent is where clipping starts to be visible as a flat
    // patch rather than as a few specular pixels.
    final hot = fraction > 0.001;
    return Text(
      '$label ${(fraction * 100).toStringAsFixed(2)}%',
      textAlign: align,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Chrome.label.copyWith(
        color: hot ? Chrome.warn : Chrome.textDim,
        fontSize: 10,
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final Histogram histogram;

  /// Computed once per histogram rather than per paint: it sorts 768 values,
  /// and a paint happens on every frame of a window resize.
  final double peak;

  _HistogramPainter(this.histogram) : peak = _scalePeak(histogram);

  @override
  void paint(Canvas canvas, Size size) {
    final bins = histogram.luma.length;

    // Scale to a high percentile of the bin counts rather than to the maximum.
    // A single spike — a blown sky, a black frame edge — is often ten times
    // the next bin, and normalising to it flattens everything else into the
    // baseline.
    if (peak <= 0) return;

    final grid = Paint()
      ..color = Chrome.divider.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    // Plus lighter, so overlapping channels build toward white the way the
    // pixels themselves do — a grey image reads as one white curve rather than
    // three curves hiding each other.
    canvas.saveLayer(Offset.zero & size, Paint());
    _drawChannel(canvas, size, histogram.red, peak, const Color(0xFFE05A5A));
    _drawChannel(canvas, size, histogram.green, peak, const Color(0xFF5AE07A));
    _drawChannel(canvas, size, histogram.blue, peak, const Color(0xFF5A8AE0));
    canvas.restore();

    _drawOutline(canvas, size, histogram.luma, peak);

    // The bin count is fixed by the library at 256; drawing it as a smooth
    // path rather than 256 bars keeps it legible at panel width.
    assert(bins == 256);
  }

  static double _scalePeak(Histogram histogram) {
    final all = <int>[
      ...histogram.red,
      ...histogram.green,
      ...histogram.blue,
    ]..sort();
    if (all.isEmpty) return 0;
    final idx = (all.length * 0.995).floor().clamp(0, all.length - 1);
    final p = all[idx].toDouble();
    return p > 0 ? p : all.last.toDouble();
  }

  Path _pathFor(Size size, List<int> bins, double peak) {
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < bins.length; i++) {
      final x = size.width * i / (bins.length - 1);
      final v = math.min(1.0, bins[i] / peak);
      // Square root, so a bin with a hundredth of the peak is still a visible
      // fifth of the height. A linear histogram of a photograph is almost
      // always one spike and a flat line.
      final y = size.height * (1 - math.sqrt(v));
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    return path;
  }

  void _drawChannel(
      Canvas canvas, Size size, List<int> bins, double peak, Color color) {
    canvas.drawPath(
      _pathFor(size, bins, peak),
      Paint()
        ..color = color.withValues(alpha: 0.62)
        ..blendMode = BlendMode.plus,
    );
  }

  void _drawOutline(Canvas canvas, Size size, List<int> bins, double peak) {
    canvas.drawPath(
      _pathFor(size, bins, peak),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Chrome.text.withValues(alpha: 0.45),
    );
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.histogram != histogram;
}

/// Placeholder shown before the first render completes.
class HistogramPlaceholder extends StatelessWidget {
  final double height;

  const HistogramPlaceholder({super.key, this.height = 96});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF0E0E10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Chrome.divider),
        ),
      );
}

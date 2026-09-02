// lib/src/ui/crop_panel.dart
//
// The crop and rotate controls. The rectangle itself is dragged on the canvas
// — see crop_overlay.dart — so this panel holds the things a rectangle cannot
// express: which way is up, how far off level, and what shape to constrain to.

import 'package:flutter/material.dart';

import '../model/geometry.dart';
import '../pipeline/processor.dart';
import 'adjust_slider.dart';
import 'theme.dart';

class CropPanel extends StatelessWidget {
  final FrameInfo? frame;
  final Geometry geometry;
  final ValueChanged<Geometry> onChanged;

  const CropPanel({
    super.key,
    required this.frame,
    required this.geometry,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (frame == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No frame open.',
              textAlign: TextAlign.center, style: Chrome.label),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        PanelSection(
          title: 'Rotate',
          children: [
            Row(
              children: [
                Expanded(
                  child: _RotateButton(
                    icon: Icons.rotate_90_degrees_ccw_outlined,
                    label: 'Left',
                    onPressed: () => onChanged(geometry.rotatedAnticlockwise()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _RotateButton(
                    icon: Icons.rotate_90_degrees_cw_outlined,
                    label: 'Right',
                    onPressed: () => onChanged(geometry.rotatedClockwise()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              geometry.quarterTurns == 0
                  ? 'Upright, as the camera recorded it.'
                  : 'Turned ${geometry.quarterTurns * 90}° clockwise.',
              style: Chrome.label.copyWith(fontSize: 10, height: 1.35),
            ),
            const SizedBox(height: 14),
            AdjustSlider(
              label: 'Straighten',
              value: geometry.straightenDegrees,
              min: -maxStraightenDegrees,
              max: maxStraightenDegrees,
              format: (v) => v == 0
                  ? '0.0°'
                  : '${v > 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)}°',
              onChanged: (v) =>
                  onChanged(geometry.copyWith(straightenDegrees: v)),
              note: 'Resampled on linear light, before the tone engine. The '
                  'crop is pulled in to the largest rectangle that still fits '
                  'inside the turned frame, so no blank corner appears.',
            ),
          ],
        ),
        PanelSection(
          title: 'Aspect ratio',
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final option in AspectOption.all)
                  _AspectChip(
                    option: option,
                    selected: option == geometry.aspect,
                    onTap: () => onChanged(geometry.copyWith(aspect: option)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              geometry.aspect == AspectOption.free
                  ? 'Drag any edge or corner of the rectangle on the canvas.'
                  : 'The rectangle keeps this shape as you drag it. Changing '
                      'the constraint does not rewrite a crop you already '
                      'placed — it applies from the next drag.',
              style: Chrome.label.copyWith(fontSize: 10, height: 1.35),
            ),
          ],
        ),
        PanelSection(
          title: 'Crop',
          trailing: InlineAction(
            label: 'reset',
            onPressed: geometry.crop.isFull
                ? null
                : () => onChanged(geometry.copyWith(crop: CropRect.full)),
          ),
          children: [
            _CropReadout(frame: frame!, geometry: geometry),
          ],
        ),
        const SizedBox(height: 18),
        InlineAction(
          label: 'Reset rotation and crop',
          onPressed: geometry.isIdentity
              ? null
              : () => onChanged(Geometry.identity),
        ),
        const SizedBox(height: 10),
        const Text(
          'Applied to the scene-referred buffer before anything else, so the '
          'histogram and the automatic exposure describe the crop rather than '
          'the whole frame.',
          style: TextStyle(fontSize: 10, color: Chrome.textDim, height: 1.4),
        ),
      ],
    );
  }
}

class _RotateButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _RotateButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: Chrome.text,
          side: const BorderSide(color: Chrome.divider),
          padding: const EdgeInsets.symmetric(vertical: 10),
          textStyle: const TextStyle(fontSize: 11.5),
        ),
      );
}

class _AspectChip extends StatelessWidget {
  final AspectOption option;
  final bool selected;
  final VoidCallback onTap;

  const _AspectChip({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Chrome.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: selected ? Chrome.accent : Chrome.divider),
        ),
        child: Text(
          option.label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : Chrome.textDim,
          ),
        ),
      ),
    );
  }
}

/// The crop in pixels of the exported file, which is the number that decides
/// whether a crop is still worth printing.
class _CropReadout extends StatelessWidget {
  final FrameInfo frame;
  final Geometry geometry;

  const _CropReadout({required this.frame, required this.geometry});

  @override
  Widget build(BuildContext context) {
    final (w, h) = geometry.outputSize(frame.fullWidth, frame.fullHeight);
    final mp = w * h / 1e6;
    final full = frame.fullWidth * frame.fullHeight;
    final kept = full == 0 ? 0.0 : (w * h) / full;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Exported size', style: Chrome.label),
            const Spacer(),
            Text('$w × $h', style: Chrome.value),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text('${mp.toStringAsFixed(1)} MP', style: Chrome.label),
            const Spacer(),
            Text('${(kept * 100).round()}% of the frame',
                style: Chrome.label.copyWith(
                    color: kept < 0.25 ? Chrome.warn : Chrome.textDim)),
          ],
        ),
      ],
    );
  }
}

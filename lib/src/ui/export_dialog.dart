// lib/src/ui/export_dialog.dart

import 'package:flutter/material.dart';

import '../pipeline/export.dart';
import 'theme.dart';

class ExportChoice {
  final ExportFormat format;
  final int quality;

  const ExportChoice(this.format, this.quality);
}

/// Format and quality. The destination is chosen afterwards through the
/// system file dialog, which is also what guarantees an export never lands on
/// top of the RAW file it came from without the user having said so.
class ExportDialog extends StatefulWidget {
  final String sourceName;

  const ExportDialog({super.key, required this.sourceName});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  ExportFormat _format = ExportFormat.jpeg;
  double _quality = defaultJpegQuality.toDouble();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Chrome.panel,
      title: const Text('Export', style: TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.sourceName, style: Chrome.label),
            const SizedBox(height: 16),
            SegmentedButton<ExportFormat>(
              segments: const [
                ButtonSegment(
                  value: ExportFormat.jpeg,
                  label: Text('JPEG'),
                  icon: Icon(Icons.image_outlined, size: 16),
                ),
                ButtonSegment(
                  value: ExportFormat.tiff,
                  label: Text('TIFF'),
                  icon: Icon(Icons.layers_outlined, size: 16),
                ),
              ],
              selected: {_format},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _format = s.first),
            ),
            const SizedBox(height: 14),
            if (_format == ExportFormat.jpeg) ...[
              Row(
                children: [
                  const Text('Quality', style: Chrome.label),
                  const Spacer(),
                  Text('${_quality.round()}', style: Chrome.value),
                ],
              ),
              Slider(
                value: _quality,
                min: 60,
                max: 100,
                divisions: 40,
                onChanged: (v) => setState(() => _quality = v),
              ),
              const Text(
                'Eight bits per channel, sRGB. 95 keeps compression artefacts '
                'below what a 100% view shows, at roughly half the size of '
                'quality 100 — where the extra bits go almost entirely into '
                'encoding sensor noise.',
                style: TextStyle(
                    fontSize: 10.5, color: Chrome.textDim, height: 1.4),
              ),
            ] else
              const Text(
                'Sixteen bits per channel, uncompressed, sRGB. The pipeline '
                'works at 16 bits throughout, so this is the option that '
                'keeps the shadow precision a strong lift depends on.',
                style: TextStyle(
                    fontSize: 10.5, color: Chrome.textDim, height: 1.4),
              ),
            const SizedBox(height: 8),
            const Divider(height: 20),
            const Text(
              'The RAW file is never modified. Export decodes it again at full '
              'resolution and writes a new file.',
              style:
                  TextStyle(fontSize: 10.5, color: Chrome.textDim, height: 1.4),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop(ExportChoice(_format, _quality.round())),
          child: const Text('Choose destination…'),
        ),
      ],
    );
  }
}

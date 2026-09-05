// test/pipeline/decode_options_test.dart
//
// The decode policy, not the decode. These are plain constants, so this runs
// in the `test` job, which has no raw_images_api checkout and no RAW file.
//
// The numeric values of the enums are deliberately not asserted here.
// scripts/check-ffi.sh --enums checks those against the real header in the
// `ffi` job, and a second copy of the numbers in Dart would be one more thing
// to update rather than one more check.

import 'package:flutter_test/flutter_test.dart';
import 'package:morphosis/src/pipeline/processor.dart';
import 'package:morphosis/src/ria/ria.dart';

void main() {
  group('export decode policy', () {
    test('export asks for a demosaic the library declares', () {
      const declared = <int>{
        RiaDemosaic.linear,
        RiaDemosaic.vng,
        RiaDemosaic.ppg,
        RiaDemosaic.ahd,
        RiaDemosaic.dcb,
        RiaDemosaic.dht,
        RiaDemosaic.aahd,
      };
      expect(declared, contains(exportDemosaic),
          reason: 'exportDemosaic must name a real ria_demosaic value; an '
              'unknown int is not rejected by LibRaw, it just picks a '
              'different algorithm than intended');
    });

    test('export does not decode the way the preview does', () {
      // The whole point of the constant. If these ever converge, either the
      // preview has become slow or the export has stopped buying quality.
      expect(exportDemosaic, isNot(RiaDemosaic.ppg));
    });

    test('the preview is small enough that its demosaic cannot show', () {
      // Why the preview is deliberately left on the cheap algorithm: it is
      // resampled to previewMaxEdge, well under a full frame's short edge, and
      // the differences between these algorithms are pixel-level.
      expect(previewMaxEdge, lessThan(2000));
    });
  });
}

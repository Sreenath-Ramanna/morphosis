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
import 'package:morphosis/src/pipeline/working_space.dart';
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

  group('working space and delivery policy', () {
    const declared = <int>{
      RiaColorspace.raw,
      RiaColorspace.srgb,
      RiaColorspace.adobe,
      RiaColorspace.wide,
      RiaColorspace.prophoto,
      RiaColorspace.xyz,
      RiaColorspace.aces,
    };

    test('E3 the working space is one the library declares', () {
      expect(declared, contains(workingSpace),
          reason: 'an unknown output_color is not rejected by LibRaw, it just '
              'produces different pixels');
    });

    test('E4 the working space is not sRGB', () {
      // The whole point of the change: LibRaw clips to the output gamut inside
      // dcraw_process, so an sRGB decode has already thrown the saturated
      // colour away. If this ever passes trivially the feature is reverted.
      expect(workingSpace, isNot(RiaColorspace.srgb));
      expect(workingSpace, isNot(RiaColorspace.raw));
    });

    test('E5 the delivery spaces are what was decided', () {
      expect(exportTiffSpace, workingSpace);
      expect(exportJpegSpace, RiaColorspace.srgb,
          reason: '8 bits across a wide gamut posterises in a gradient');
      expect(previewSpace, RiaColorspace.srgb);
    });

    test('E6 recovery selects LibRaw blend', () {
      // 1 unclips, 2 blends, 3+ rebuilds. All three carry the same
      // normalisation scale; 2 is the one approach.md section 0 measured.
      expect(highlightRecoveryMode, 2);
    });
  });
}

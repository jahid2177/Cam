import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'contours.dart';
import 'edge_detection.dart';
import 'models/detection_result.dart';
import 'models/quad.dart';

/// Longest edge (px) that detection runs at. Keeps the pure-Dart edge/
/// contour pipeline fast on full-resolution camera photos; the resulting
/// quad is scaled back up to the original image size before being
/// returned, since [DetectionSuccess.quad] is always in original-image
/// coordinates.
const int kDetectionMaxDimension = 760;

/// Entry point designed to be run via `compute()`. Takes the image file
/// path and returns a [DetectionResult] — never throws, so a caller can
/// always resolve the returned future without needing to guard against an
/// unhandled isolate exception.
Future<DetectionResult> detectDocumentIsolateEntry(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return const DetectionFailure('Could not decode image');
    }

    final originalWidth = decoded.width;
    final originalHeight = decoded.height;

    final longestEdge = max(originalWidth, originalHeight).toDouble();
    final workingScale =
        longestEdge > kDetectionMaxDimension ? kDetectionMaxDimension / longestEdge : 1.0;
    final workWidth = max(1, (originalWidth * workingScale).round());
    final workHeight = max(1, (originalHeight * workingScale).round());

    final rgba = _downscaleRgba(
      decoded.getBytes(order: img.ChannelOrder.rgba),
      originalWidth,
      originalHeight,
      workWidth,
      workHeight,
    );

    final gray = rgbaToGrayscale(rgba, workWidth, workHeight);
    final quad = detectQuadFromGrayscale(gray, workWidth, workHeight);
    if (quad == null) {
      return DetectionNotFound(originalWidth, originalHeight);
    }

    final scaleBackX = originalWidth / workWidth;
    final scaleBackY = originalHeight / workHeight;
    return DetectionSuccess(
      quad.scaled(scaleBackX, scaleBackY),
      originalWidth,
      originalHeight,
    );
  } catch (e) {
    return DetectionFailure(e.toString());
  }
}

/// Multipliers applied to the Otsu threshold to build several binarized
/// edge masks per frame instead of trusting a single one. Otsu recomputes
/// its threshold fresh from each frame's own gradient-magnitude histogram,
/// so it can shift slightly frame-to-frame under sensor noise/lighting
/// flicker even when the scene hasn't changed — a single mask's contour
/// search can then land on a visibly different quad purely because the
/// threshold moved. Mirrors the reference document-scanner app's approach
/// of trying multiple thresholds/channels per frame and scoring the
/// pooled results ([pickBestQuad]) instead of committing to one strategy's
/// output.
const List<double> _thresholdMultipliers = [0.58, 0.76, 1.0, 1.24, 1.46];

/// Runs the grayscale->blur->sobel->(multi-threshold)->dilate->quad
/// pipeline on an already-grayscale buffer. Pure function, no I/O —
/// shared by the file-based one-shot entry point above and the live-scan
/// persistent isolate, so the edge/contour logic only exists in one
/// place.
///
/// Unlike a single-threshold pipeline, this binarizes the Sobel magnitude
/// at several thresholds around the Otsu-computed one (see
/// [_thresholdMultipliers]), pools every valid candidate quad found across
/// all of them, and picks the best via [pickBestQuad]'s area/squareness
/// scoring — the same "try several strategies, score the pool" approach
/// the reference app's native detector uses, adapted to this pure-Dart
/// pipeline's single-channel (grayscale) input.
///
/// [previousQuad], when supplied, nudges [pickBestQuad] toward whichever
/// candidate best corresponds to it — see that function's doc comment.
/// Always null for the one-shot file-detection path above (no "previous
/// frame" concept there); the live-scan worker isolate supplies its own
/// last-seen quad.
Quad? detectQuadFromGrayscale(Uint8List gray, int width, int height,
    {Quad? previousQuad}) {
  if (width < 8 || height < 8 || gray.length != width * height) return null;

  // Two luminance views make the detector much less sensitive to lighting:
  // raw preserves naturally strong borders; normalized recovers white paper
  // on pale backgrounds and documents under uneven illumination.
  final normalized = normalizeContrast(gray, lowPercentile: 0.015, highPercentile: 0.985);
  final sources = <Uint8List>[gray];
  if (!_buffersEffectivelyEqual(gray, normalized)) sources.add(normalized);

  final candidates = <Quad>[];
  for (final source in sources) {
    final blurred = gaussianBlur3(source, width, height);
    final magnitude = sobelMagnitude(blurred, width, height);

    final otsu = otsuThreshold(magnitude).clamp(16, 220);
    final p72 = percentileThreshold(magnitude, 0.72).clamp(14, 235);
    final p82 = percentileThreshold(magnitude, 0.82).clamp(16, 245);

    // Use both histogram separation (Otsu) and strong-edge percentiles.
    // De-duplicate close thresholds so difficult frames get more strategies
    // without multiplying contour work on ordinary frames.
    final thresholds = <int>{};
    for (final multiplier in _thresholdMultipliers) {
      thresholds.add((otsu * multiplier).round().clamp(12, 245));
    }
    thresholds.add(p72);
    thresholds.add(p82);
    thresholds.add(((otsu + p72) / 2).round().clamp(12, 245));

    for (final t in thresholds) {
      final binary = threshold(magnitude, t);
      final connected = closeBinary(binary, width, height, radius: 1);
      final dilated = dilate(connected, width, height, 2);
      candidates.addAll(findDocumentQuadCandidates(dilated, width, height));
    }
  }

  return pickBestQuad(candidates, width, height, previousQuad: previousQuad);
}

bool _buffersEffectivelyEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.isEmpty) return false;
  final step = max(1, a.length ~/ 256);
  int difference = 0;
  int samples = 0;
  for (int i = 0; i < a.length; i += step) {
    difference += (a[i] - b[i]).abs();
    samples++;
  }
  return samples == 0 || difference / samples < 2.0;
}

/// Nearest-neighbor downsample of an RGBA buffer (stride 4).
Uint8List _downscaleRgba(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  if (srcW == dstW && srcH == dstH) return src;

  final dst = Uint8List(dstW * dstH * 4);
  for (int y = 0; y < dstH; y++) {
    final sy = (y * srcH / dstH).floor().clamp(0, srcH - 1);
    for (int x = 0; x < dstW; x++) {
      final sx = (x * srcW / dstW).floor().clamp(0, srcW - 1);
      final srcIdx = (sy * srcW + sx) * 4;
      final dstIdx = (y * dstW + x) * 4;
      dst[dstIdx] = src[srcIdx];
      dst[dstIdx + 1] = src[srcIdx + 1];
      dst[dstIdx + 2] = src[srcIdx + 2];
      dst[dstIdx + 3] = src[srcIdx + 3];
    }
  }
  return dst;
}

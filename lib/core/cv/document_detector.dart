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

  // Multi-view preprocessing. Raw luminance preserves naturally sharp page
  // borders; normalized luminance recovers low-contrast paper and uneven
  // lighting. Running both is similar in spirit to production scanners that
  // try several image representations and score the combined candidates.
  final normalized = normalizeContrast(
    gray,
    lowPercentile: 0.01,
    highPercentile: 0.99,
  );
  final sources = <Uint8List>[gray];
  if (!_buffersEffectivelyEqual(gray, normalized)) sources.add(normalized);

  final candidates = <Quad>[];

  // PASS 1: structural edges via a real Canny pipeline (gradients ->
  // non-max suppression -> hysteresis), not a single blunt magnitude
  // threshold. This is the fastest/highest-confidence path and handles
  // dark borders, printed paper, table contrast and perspective.
  for (final source in sources) {
    final blurred = gaussianBlur3(source, width, height);
    final gradients = sobelGradients(blurred, width, height);
    final magnitude = gradients.magnitude;
    // Thin the magnitude to single-pixel ridges once per source; every
    // threshold pair below reuses this same suppressed map.
    final suppressed = nonMaxSuppress(gradients);

    final otsu = otsuThreshold(magnitude).clamp(14, 220);
    final p74 = percentileThreshold(magnitude, 0.74).clamp(12, 235);
    final p84 = percentileThreshold(magnitude, 0.84).clamp(14, 245);

    // Each value here becomes hysteresis's *high* threshold; sweeping
    // several (rather than trusting one Otsu/percentile estimate) keeps
    // the pass robust when the page-to-background contrast is unusually
    // low or high for the frame.
    final highThresholds = <int>{
      (otsu * 0.58).round().clamp(10, 245),
      (otsu * 0.78).round().clamp(10, 245),
      otsu,
      (otsu * 1.22).round().clamp(10, 245),
      p74,
      p84,
    };

    for (final high in highThresholds) {
      // Classic Canny recommends a high:low ratio of roughly 2:1 to 3:1;
      // 0.45 sits in that band and lets hysteresis bridge the low-
      // contrast gaps a single threshold would otherwise break the
      // border at (glare, fingers, text crossing the page edge, motion
      // blur).
      final low = (high * 0.45).round().clamp(6, high - 1);
      final binary = hysteresisThreshold(suppressed, width, height, low: low, high: high);
      final connected = closeBinary(binary, width, height, radius: 2);
      final dilated = dilate(connected, width, height, 1);
      candidates.addAll(findDocumentQuadCandidates(dilated, width, height));
    }
  }

  // PASS 2: filled luminance regions. Edge-only detectors commonly fail on
  // a clean white page with a faint border. If the edge pass is uncertain,
  // segment both bright-on-dark and dark-on-bright regions at several
  // luminance cuts. A real page then becomes one large connected component
  // whose convex hull gives the four corners even if its border is weak.
  if (candidates.length < 4) {
    final regionSource = sources.length > 1 ? sources.last : gray;
    final blurred = gaussianBlur3(regionSource, width, height);
    final lumOtsu = otsuThreshold(blurred).clamp(20, 235);
    final p42 = percentileThreshold(blurred, 0.42).clamp(15, 240);
    final p58 = percentileThreshold(blurred, 0.58).clamp(15, 240);
    final p70 = percentileThreshold(blurred, 0.70).clamp(15, 245);
    final cuts = <int>{lumOtsu, p42, p58, p70};

    for (final cut in cuts) {
      final bright = closeBinary(
        threshold(blurred, cut),
        width,
        height,
        radius: 2,
      );
      candidates.addAll(findDocumentQuadCandidates(bright, width, height));

      final dark = closeBinary(
        thresholdBelow(blurred, cut),
        width,
        height,
        radius: 2,
      );
      candidates.addAll(findDocumentQuadCandidates(dark, width, height));
    }
  }

  // PASS 3: adaptive local contrast. This is the difficult-light fallback
  // for broad shadows and gradients where neither one global edge threshold
  // nor one global luminance threshold separates page from background.
  if (candidates.length < 2) {
    final source = sources.length > 1 ? sources.last : gray;
    final radius = (min(width, height) ~/ 14).clamp(6, 22).toInt();
    final local = localContrastMagnitude(
      source,
      width,
      height,
      radius: radius,
    );
    final localOtsu = otsuThreshold(local).clamp(12, 210);
    final localP72 = percentileThreshold(local, 0.72).clamp(10, 230);
    final localP82 = percentileThreshold(local, 0.82).clamp(12, 240);
    for (final t in <int>{localOtsu, localP72, localP82}) {
      final mask = dilate(
        closeBinary(threshold(local, t), width, height, radius: 2),
        width,
        height,
        1,
      );
      candidates.addAll(findDocumentQuadCandidates(mask, width, height));
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

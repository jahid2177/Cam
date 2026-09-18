import 'dart:math';
import 'dart:typed_data';

/// Pure-Dart replacements for the OpenCV grayscale/blur/edge/dilate/
/// threshold steps that used to run natively via
/// `Imgproc.cvtColor`/`GaussianBlur`/`Canny`/`dilate`/`threshold`.
///
/// All functions operate on flat byte buffers (matching the RGBA/
/// single-channel array patterns already used elsewhere in this codebase,
/// e.g. `lib/core/image_filter/utils/image_filter_utils.dart`) rather than
/// package-specific image objects, so they stay cheap to run inside an
/// isolate and easy to unit test.

/// Converts an RGBA buffer (stride 4) to a single-channel luminance buffer.
Uint8List rgbaToGrayscale(Uint8List rgba, int width, int height) {
  final gray = Uint8List(width * height);
  for (int i = 0, p = 0; p < gray.length; i += 4, p++) {
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    gray[p] = (0.2126 * r + 0.7152 * g + 0.0722 * b).round().clamp(0, 255);
  }
  return gray;
}

/// A 3x3 Gaussian blur (approximating OpenCV's `GaussianBlur(3x3)`).
Uint8List gaussianBlur3(Uint8List gray, int width, int height) {
  final out = Uint8List(width * height);
  const kernel = [1, 2, 1, 2, 4, 2, 1, 2, 1];
  const kernelSum = 16;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int sum = 0;
      int k = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final sx = (x + dx).clamp(0, width - 1);
          final sy = (y + dy).clamp(0, height - 1);
          sum += gray[sy * width + sx] * kernel[k++];
        }
      }
      out[y * width + x] = (sum / kernelSum).round().clamp(0, 255);
    }
  }
  return out;
}

/// Directional Sobel gradients plus their magnitude (clamped to 0-255, same
/// range [sobelMagnitude] used to return on its own). [gx]/[gy] are signed
/// and unclamped — needed by [nonMaxSuppress] to know each pixel's gradient
/// *direction*, not just its strength, which plain magnitude thresholding
/// throws away.
class SobelGradients {
  final Int32List gx;
  final Int32List gy;
  final Uint8List magnitude;
  final int width;
  final int height;

  const SobelGradients(this.gx, this.gy, this.magnitude, this.width, this.height);
}

/// Computes Sobel gx/gy and their magnitude in one pass. Stands in for
/// OpenCV's `Sobel(dx=1,dy=0)` / `Sobel(dx=0,dy=1)` pair, which Canny needs
/// both channels of (magnitude alone isn't enough to suppress non-maxima
/// along the gradient direction — see [nonMaxSuppress]).
SobelGradients sobelGradients(Uint8List gray, int width, int height) {
  final gx = Int32List(width * height);
  final gy = Int32List(width * height);
  final mag = Uint8List(width * height);

  int at(int x, int y) {
    final cx = x.clamp(0, width - 1);
    final cy = y.clamp(0, height - 1);
    return gray[cy * width + cx];
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final gxv = -at(x - 1, y - 1) -
          2 * at(x - 1, y) -
          at(x - 1, y + 1) +
          at(x + 1, y - 1) +
          2 * at(x + 1, y) +
          at(x + 1, y + 1);
      final gyv = -at(x - 1, y - 1) -
          2 * at(x, y - 1) -
          at(x + 1, y - 1) +
          at(x - 1, y + 1) +
          2 * at(x, y + 1) +
          at(x + 1, y + 1);
      final idx = y * width + x;
      gx[idx] = gxv;
      gy[idx] = gyv;
      final m = sqrt((gxv * gxv + gyv * gyv).toDouble());
      mag[idx] = m.clamp(0.0, 255.0).round();
    }
  }
  return SobelGradients(gx, gy, mag, width, height);
}

/// Sobel gradient magnitude, clamped to 0-255. Kept as a thin wrapper over
/// [sobelGradients] for callers that only need magnitude.
Uint8List sobelMagnitude(Uint8List gray, int width, int height) =>
    sobelGradients(gray, width, height).magnitude;

/// Thins raw Sobel magnitude down to single-pixel-wide ridges by keeping
/// only local maxima along each pixel's gradient direction (quantized to
/// the 4 principal directions: 0°/45°/90°/135°) and zeroing everything
/// else — the non-maximum-suppression step of a real Canny detector.
///
/// This is the piece plain magnitude-thresholding skips, and the gap it
/// leaves matters: thresholding raw magnitude keeps every pixel on a
/// blurry multi-pixel-wide gradient ramp, so a document edge comes out as
/// a thick smear rather than a thin line. That smear then swallows nearby
/// detail (two close edges merge into one blob), rounds off corners after
/// [dilate]/[closeBinary], and shifts where [_convexHull]-style corner
/// extraction thinks the boundary actually is. Suppressing to the true
/// ridge first fixes all three before hysteresis ever runs.
Uint8List nonMaxSuppress(SobelGradients g) {
  final width = g.width, height = g.height;
  final out = Uint8List(width * height);

  int magAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return 0;
    return g.magnitude[y * width + x];
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final idx = y * width + x;
      final m = g.magnitude[idx];
      if (m == 0) continue;

      final gx = g.gx[idx], gy = g.gy[idx];
      // Angle of the gradient (perpendicular to the edge), quantized into
      // 4 bins spanning 180 degrees (gradient direction and its opposite
      // are the same edge orientation).
      var angle = atan2(gy, gx) * 180 / pi;
      if (angle < 0) angle += 180;

      int n1x, n1y, n2x, n2y;
      if (angle < 22.5 || angle >= 157.5) {
        // 0 degrees: horizontal gradient -> compare left/right.
        n1x = x - 1; n1y = y; n2x = x + 1; n2y = y;
      } else if (angle < 67.5) {
        // 45 degrees.
        n1x = x + 1; n1y = y - 1; n2x = x - 1; n2y = y + 1;
      } else if (angle < 112.5) {
        // 90 degrees: vertical gradient -> compare up/down.
        n1x = x; n1y = y - 1; n2x = x; n2y = y + 1;
      } else {
        // 135 degrees.
        n1x = x - 1; n1y = y - 1; n2x = x + 1; n2y = y + 1;
      }

      if (m >= magAt(n1x, n1y) && m >= magAt(n2x, n2y)) {
        out[idx] = m;
      }
    }
  }
  return out;
}

/// Canny-style double-threshold hysteresis over a non-max-suppressed
/// magnitude image. A pixel at or above [high] is a definite edge; a pixel
/// between [low] and [high] is only kept if it is 8-connected, through a
/// chain of other such pixels, to a definite edge. This is what lets a
/// real document border survive glare, a shadow crossing one side, or a
/// patch where the page-to-background contrast briefly dips — those
/// segments fall between the thresholds and get reconnected to the strong
/// edge on either side of them, instead of being dropped (too strict a
/// single threshold) or letting equally-weak noise elsewhere in the frame
/// in too (too lax a single threshold).
Uint8List hysteresisThreshold(
  Uint8List suppressed,
  int width,
  int height, {
  required int low,
  required int high,
}) {
  final out = Uint8List(width * height);
  final queue = <int>[];

  for (int i = 0; i < suppressed.length; i++) {
    if (suppressed[i] >= high) {
      out[i] = 1;
      queue.add(i);
    }
  }

  int head = 0;
  while (head < queue.length) {
    final idx = queue[head++];
    final x = idx % width;
    final y = idx ~/ width;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
        final nIdx = ny * width + nx;
        if (out[nIdx] == 0 && suppressed[nIdx] >= low) {
          out[nIdx] = 1;
          queue.add(nIdx);
        }
      }
    }
  }
  return out;
}

/// Otsu's method: picks a global threshold that best separates a bimodal
/// histogram, standing in for OpenCV's `THRESH_TRIANGLE`.
int otsuThreshold(Uint8List image) {
  final hist = List<int>.filled(256, 0);
  for (final v in image) {
    hist[v]++;
  }

  final total = image.length;
  double sum = 0;
  for (int i = 0; i < 256; i++) {
    sum += i * hist[i];
  }

  double sumB = 0;
  int wB = 0;
  double maxVariance = -1;
  int threshold = 128;

  for (int t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;

    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > maxVariance) {
      maxVariance = between;
      threshold = t;
    }
  }
  return threshold;
}


/// Returns the requested histogram percentile (0..255). Useful alongside
/// Otsu on gradient images: Otsu can become too low when a frame contains
/// lots of texture/text, while a high gradient percentile keeps the mask
/// focused on the strongest structural edges.
int percentileThreshold(Uint8List image, double percentile) {
  if (image.isEmpty) return 0;
  final p = percentile.clamp(0.0, 1.0);
  final hist = List<int>.filled(256, 0);
  for (final v in image) {
    hist[v]++;
  }
  final target = max(1, (image.length * p).round());
  int running = 0;
  for (int i = 0; i < 256; i++) {
    running += hist[i];
    if (running >= target) return i;
  }
  return 255;
}


/// Robust global contrast normalization using the 2nd and 98th percentile
/// luminance values. This avoids letting a few specular highlights or deep
/// shadows dominate the range, and improves edge visibility on white paper
/// placed on a light desk or in dim/uneven lighting.
Uint8List normalizeContrast(
  Uint8List gray, {
  double lowPercentile = 0.02,
  double highPercentile = 0.98,
}) {
  if (gray.isEmpty) return Uint8List(0);
  final hist = List<int>.filled(256, 0);
  for (final v in gray) {
    hist[v]++;
  }

  final lowTarget = (gray.length * lowPercentile).round();
  final highTarget = (gray.length * highPercentile).round();
  int running = 0;
  int low = 0;
  int high = 255;
  for (int i = 0; i < 256; i++) {
    running += hist[i];
    if (running >= lowTarget) {
      low = i;
      break;
    }
  }
  running = 0;
  for (int i = 0; i < 256; i++) {
    running += hist[i];
    if (running >= highTarget) {
      high = i;
      break;
    }
  }

  if (high - low < 12) return Uint8List.fromList(gray);
  final scale = 255.0 / (high - low);
  final out = Uint8List(gray.length);
  for (int i = 0; i < gray.length; i++) {
    out[i] = ((gray[i] - low) * scale).round().clamp(0, 255);
  }
  return out;
}

/// Binary closing (dilate then erode). It bridges small gaps in document
/// borders caused by glare, text crossing the edge, or motion blur without
/// requiring an excessively large dilation radius.
Uint8List closeBinary(
  Uint8List mask,
  int width,
  int height, {
  int radius = 1,
}) {
  return erode(dilate(mask, width, height, radius), width, height, radius);
}

/// Binary erosion, implemented as two separable min-filter passes.
Uint8List erode(Uint8List mask, int width, int height, int radius) {
  final rowPass = Uint8List(width * height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int v = 1;
      for (int dx = -radius; dx <= radius && v == 1; dx++) {
        final sx = x + dx;
        if (sx < 0 || sx >= width || mask[y * width + sx] == 0) v = 0;
      }
      rowPass[y * width + x] = v;
    }
  }

  final out = Uint8List(width * height);
  for (int x = 0; x < width; x++) {
    for (int y = 0; y < height; y++) {
      int v = 1;
      for (int dy = -radius; dy <= radius && v == 1; dy++) {
        final sy = y + dy;
        if (sy < 0 || sy >= height || rowPass[sy * width + x] == 0) v = 0;
      }
      out[y * width + x] = v;
    }
  }
  return out;
}

/// Binarizes [image] against threshold [t]: returns a 0/1 mask.
Uint8List threshold(Uint8List image, int t) {
  final out = Uint8List(image.length);
  for (int i = 0; i < image.length; i++) {
    out[i] = image[i] >= t ? 1 : 0;
  }
  return out;
}

/// Binary dilation with a roughly `(2*radius+1)` square structuring
/// element, implemented as two separable max-filter passes (O(n*radius)
/// instead of O(n*radius^2)) — stands in for OpenCV's `dilate(9x9)`.
Uint8List dilate(Uint8List mask, int width, int height, int radius) {
  final rowPass = Uint8List(width * height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int v = 0;
      for (int dx = -radius; dx <= radius && v == 0; dx++) {
        final sx = x + dx;
        if (sx < 0 || sx >= width) continue;
        if (mask[y * width + sx] == 1) v = 1;
      }
      rowPass[y * width + x] = v;
    }
  }

  final out = Uint8List(width * height);
  for (int x = 0; x < width; x++) {
    for (int y = 0; y < height; y++) {
      int v = 0;
      for (int dy = -radius; dy <= radius && v == 0; dy++) {
        final sy = y + dy;
        if (sy < 0 || sy >= height) continue;
        if (rowPass[sy * width + x] == 1) v = 1;
      }
      out[y * width + x] = v;
    }
  }
  return out;
}
/// Inverse binary threshold: 1 for pixels <= [t], otherwise 0.
/// Useful for finding a dark document on a light background while the
/// regular [threshold] handles light documents on darker backgrounds.
Uint8List thresholdBelow(Uint8List image, int t) {
  final out = Uint8List(image.length);
  for (int i = 0; i < image.length; i++) {
    out[i] = image[i] <= t ? 1 : 0;
  }
  return out;
}

/// Returns the absolute difference between every pixel and the mean of a
/// surrounding square window. This is a cheap adaptive-contrast map: unlike
/// a global Sobel threshold it survives broad shadows, exposure gradients
/// and white paper on a pale desk because each pixel is judged against its
/// local neighbourhood rather than one threshold for the whole frame.
Uint8List localContrastMagnitude(
  Uint8List gray,
  int width,
  int height, {
  int radius = 12,
}) {
  if (gray.length != width * height || width <= 0 || height <= 0) {
    return Uint8List(0);
  }

  final integral = List<int>.filled((width + 1) * (height + 1), 0);
  final stride = width + 1;
  for (int y = 0; y < height; y++) {
    int rowSum = 0;
    for (int x = 0; x < width; x++) {
      rowSum += gray[y * width + x];
      integral[(y + 1) * stride + (x + 1)] =
          integral[y * stride + (x + 1)] + rowSum;
    }
  }

  int rectSum(int x0, int y0, int x1, int y1) {
    return integral[(y1 + 1) * stride + (x1 + 1)] -
        integral[y0 * stride + (x1 + 1)] -
        integral[(y1 + 1) * stride + x0] +
        integral[y0 * stride + x0];
  }

  final out = Uint8List(gray.length);
  for (int y = 0; y < height; y++) {
    final y0 = (y - radius).clamp(0, height - 1);
    final y1 = (y + radius).clamp(0, height - 1);
    for (int x = 0; x < width; x++) {
      final x0 = (x - radius).clamp(0, width - 1);
      final x1 = (x + radius).clamp(0, width - 1);
      final count = (x1 - x0 + 1) * (y1 - y0 + 1);
      final mean = rectSum(x0, y0, x1, y1) / count;
      final difference = (gray[y * width + x] - mean).abs();
      out[y * width + x] = (difference * 4.0).round().clamp(0, 255);
    }
  }
  return out;
}

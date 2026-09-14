import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Builds a single portrait A4-style page containing the front and back of
/// an identity card. The heavy decode/resize/encode work runs in a worker
/// isolate so the live camera UI stays responsive.
class IdCardComposer {
  IdCardComposer._();

  static const int pageWidth = 1654;
  static const int pageHeight = 2339;

  static Future<File> compose({
    required File front,
    required File back,
  }) async {
    final temp = await getTemporaryDirectory();
    final outputPath =
        '${temp.path}/id_card_${DateTime.now().microsecondsSinceEpoch}.jpg';

    final result = await compute<Map<String, String>, String?>(
      _composeIdCardIsolate,
      <String, String>{
        'front': front.path,
        'back': back.path,
        'output': outputPath,
      },
    );

    if (result == null) {
      throw StateError('Unable to compose ID card page');
    }

    final file = File(result);
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('ID card page was not written');
    }
    return file;
  }
}

String? _composeIdCardIsolate(Map<String, String> args) {
  try {
    final frontBytes = File(args['front']!).readAsBytesSync();
    final backBytes = File(args['back']!).readAsBytesSync();
    final front = img.decodeImage(frontBytes);
    final back = img.decodeImage(backBytes);
    if (front == null || back == null) return null;

    const pageWidth = IdCardComposer.pageWidth;
    const pageHeight = IdCardComposer.pageHeight;
    const horizontalMargin = 150;
    const topMargin = 210;
    const bottomMargin = 210;
    const cardGap = 170;

    final maxCardWidth = pageWidth - (horizontalMargin * 2);
    final maxCardHeight =
        ((pageHeight - topMargin - bottomMargin - cardGap) / 2).floor();

    final canvas = img.Image(width: pageWidth, height: pageHeight);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

    final frontFitted = _fitInside(front, maxCardWidth, maxCardHeight);
    final backFitted = _fitInside(back, maxCardWidth, maxCardHeight);

    final contentHeight = frontFitted.height + cardGap + backFitted.height;
    var y = ((pageHeight - contentHeight) / 2).round();

    final frontX = ((pageWidth - frontFitted.width) / 2).round();
    img.compositeImage(canvas, frontFitted, dstX: frontX, dstY: y);

    y += frontFitted.height + cardGap;
    final backX = ((pageWidth - backFitted.width) / 2).round();
    img.compositeImage(canvas, backFitted, dstX: backX, dstY: y);

    final output = File(args['output']!);
    output.parent.createSync(recursive: true);
    output.writeAsBytesSync(img.encodeJpg(canvas, quality: 92), flush: true);
    return output.path;
  } catch (_) {
    return null;
  }
}

img.Image _fitInside(img.Image source, int maxWidth, int maxHeight) {
  final widthScale = maxWidth / source.width;
  final heightScale = maxHeight / source.height;
  final scale = widthScale < heightScale ? widthScale : heightScale;

  // Never enlarge a small source unnecessarily; it only increases file size
  // without creating detail.
  final safeScale = scale > 1.0 ? 1.0 : scale;
  final width =
      (source.width * safeScale).round().clamp(1, maxWidth).toInt();
  final height =
      (source.height * safeScale).round().clamp(1, maxHeight).toInt();

  if (width == source.width && height == source.height) return source;
  return img.copyResize(
    source,
    width: width,
    height: height,
    interpolation: img.Interpolation.linear,
  );
}

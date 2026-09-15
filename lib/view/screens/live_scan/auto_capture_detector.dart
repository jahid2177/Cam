import 'package:flutter/foundation.dart';
import 'package:openscan/core/cv/models/quad.dart';

/// Watches a stream of detected quads and decides when the document has
/// been held stable and fully framed long enough to auto-capture, mirroring
/// the reference app's auto-capture behavior. Pure logic, no camera/isolate
/// dependency, so it can be driven directly with synthetic quad sequences in
/// tests instead of a live camera stream.
///
/// Quads passed in are expected to already be `isPlausibleQuad`-filtered by
/// the detection pipeline (true for `LiveScanController.latestQuad`), so
/// this only checks positional stability across consecutive frames, not
/// shape validity.
class AutoCaptureDetector {
  /// Consecutive stable detections required before capture fires. At the
  /// live-scan pipeline's throttled detection rate (~1 in 3 camera frames,
  /// observed on-device as roughly 200-350ms between accepted results),
  /// this is set low enough to not itself become the binding constraint —
  /// [kMinStableDuration] is the actual timing knob; both conditions must
  /// hold.
  static const int kStableFrameCount = 5;

  /// Max per-corner movement between consecutive frames, as a fraction of
  /// the normalized [0,1] coordinate space, for a frame to count as "still"
  /// relative to the previous one. Starting point for on-device tuning.
  static const double kPositionToleranceFraction = 0.013;

  /// Do not auto-capture a tiny rectangle in the distance. Manual capture
  /// remains available, but automatic capture waits until the document is
  /// large enough to produce a useful crop.
  static const double kMinDocumentAreaFraction = 0.15;

  /// Minimum wall-clock span the stable window must cover even if enough
  /// frames arrived faster than that, so a burst of quick results can't
  /// satisfy the frame-count alone. Primary knob for how long a document
  /// must be held still before auto-capture fires.
  static const Duration kMinStableDuration = Duration(milliseconds: 850);

  /// Cooldown after any capture (auto or manual) before auto-capture can
  /// fire again, so a continuously-open batch session doesn't immediately
  /// re-trigger on the same still-framed document.
  static const Duration kCooldownDuration = Duration(seconds: 2);

  /// Fires once when the stability condition is met. Callers must invoke
  /// [notifyCaptured] once they've actually captured (whether triggered by
  /// this or by a manual tap) to start the cooldown and reset state.
  final VoidCallback onStable;

  /// Notified whenever the "about to auto-capture" state changes, so the UI
  /// can drive a visual cue.
  final ValueChanged<bool>? onImminentChanged;

  final DateTime Function() _now;

  AutoCaptureDetector({
    required this.onStable,
    this.onImminentChanged,
    DateTime Function() now = DateTime.now,
  }) : _now = now;

  final List<Quad> _window = [];
  DateTime? _windowStart;
  DateTime? _cooldownUntil;
  bool _enabled = true;
  bool _imminent = false;
  bool _firedForWindow = false;

  bool get isEnabled => _enabled;

  set enabled(bool value) {
    _enabled = value;
    if (!value) _reset();
  }

  bool get isInCooldown =>
      _cooldownUntil != null && _now().isBefore(_cooldownUntil!);

  /// Feed each new detection result. Pass null for a frame where nothing
  /// was detected.
  void onQuadUpdate(Quad? quad) {
    if (!_enabled || isInCooldown || quad == null || !_isLargeEnough(quad)) {
      _reset();
      return;
    }

    if (_window.isEmpty || !_isWithinTolerance(_window.last, quad)) {
      _window.clear();
      _windowStart = _now();
      _firedForWindow = false;
    }
    _window.add(quad);
    if (_window.length > kStableFrameCount + 2) {
      _window.removeAt(0);
    }

    _setImminent(_window.length >= kStableFrameCount - 2);

    if (!_firedForWindow &&
        _window.length >= kStableFrameCount &&
        _now().difference(_windowStart!) >= kMinStableDuration) {
      _firedForWindow = true;
      onStable();
    }
  }

  /// Starts the post-capture cooldown and clears the stability window.
  void notifyCaptured() {
    _cooldownUntil = _now().add(kCooldownDuration);
    _reset();
  }

  void _reset() {
    _window.clear();
    _windowStart = null;
    _firedForWindow = false;
    _setImminent(false);
  }

  void _setImminent(bool value) {
    if (_imminent == value) return;
    _imminent = value;
    onImminentChanged?.call(value);
  }

  bool _isLargeEnough(Quad q) {
    final p = q.points;
    double area = 0;
    for (int i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      area += a.x * b.y - b.x * a.y;
    }
    return area.abs() / 2 >= kMinDocumentAreaFraction;
  }

  bool _isWithinTolerance(Quad a, Quad b) {
    final pa = a.points, pb = b.points;
    double meanMovement = 0;
    for (int i = 0; i < 4; i++) {
      final dx = (pa[i].x - pb[i].x).abs();
      final dy = (pa[i].y - pb[i].y).abs();
      if (dx > kPositionToleranceFraction || dy > kPositionToleranceFraction) {
        return false;
      }
      meanMovement += (dx + dy) / 2;
    }
    meanMovement /= 4;
    if (meanMovement > kPositionToleranceFraction * 0.55) return false;

    final areaA = _area(a);
    final areaB = _area(b);
    if (areaA <= 0 || areaB <= 0) return false;
    final areaDrift = (areaA - areaB).abs() / areaA;
    if (areaDrift > 0.045) return false;

    final centerAx = pa.fold<double>(0, (v, p) => v + p.x) / 4;
    final centerAy = pa.fold<double>(0, (v, p) => v + p.y) / 4;
    final centerBx = pb.fold<double>(0, (v, p) => v + p.x) / 4;
    final centerBy = pb.fold<double>(0, (v, p) => v + p.y) / 4;
    if ((centerAx - centerBx).abs() > 0.008 ||
        (centerAy - centerBy).abs() > 0.008) return false;
    return true;
  }

  double _area(Quad q) {
    final p = q.points;
    double area = 0;
    for (int i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      area += a.x * b.y - b.x * a.y;
    }
    return area.abs() / 2;
  }
}

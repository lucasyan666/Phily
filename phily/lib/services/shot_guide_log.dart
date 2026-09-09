import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// What the camera knew about a shot at the instant the shutter fired: which
/// guide was up, whether the subject had locked to it, and which target.
///
/// This is the data behind the gallery's "the shot remembers its guide": the
/// gold lozenge on on-guide thumbnails, the ON GUIDE filter and percentage,
/// and the viewer's guide recall. Stored as plain strings/numbers so the
/// gallery never has to import the camera's private types.
class ShotGuide {
  /// [CompositionMode] enum name, e.g. `ruleOfThirds`. `none` when no guide.
  final String mode;

  /// Display label, e.g. "Rule of Thirds".
  final String label;

  /// True when the shot locked — "Perfect" / eye level / horizon "Level".
  final bool locked;

  /// Index of the power point the subject sat on (into the mode's
  /// `powerPoints`, top-left → top-right → bottom-left → bottom-right for the
  /// grids), or -1 when not applicable.
  final int point;

  /// Roll off level at capture, degrees (signed).
  final double rollDeg;

  const ShotGuide({
    required this.mode,
    required this.label,
    required this.locked,
    this.point = -1,
    this.rollDeg = 0,
  });

  bool get hasGuide => mode != 'none';

  Map<String, Object> toJson() => {
    'mode': mode,
    'label': label,
    'locked': locked,
    'point': point,
    'roll': rollDeg,
  };

  static ShotGuide? fromJson(Object? o) {
    if (o is! Map) return null;
    final mode = o['mode'];
    if (mode is! String) return null;
    return ShotGuide(
      mode: mode,
      label: (o['label'] as String?) ?? mode,
      locked: (o['locked'] as bool?) ?? false,
      point: (o['point'] as num?)?.toInt() ?? -1,
      rollDeg: (o['roll'] as num?)?.toDouble() ?? 0,
    );
  }

  /// "Subject on the top-left crossing." — for the four grid intersections.
  String? get crossingName => switch (point) {
    0 => 'top-left',
    1 => 'top-right',
    2 => 'bottom-left',
    3 => 'bottom-right',
    _ => null,
  };
}

/// Per-asset guide records, keyed by photo library asset id. A small JSON
/// file in the app's documents directory — a few hundred bytes per shot,
/// loaded once, written on each capture. Listeners (the gallery) rebuild when
/// a record lands.
class ShotGuideLog extends ChangeNotifier {
  ShotGuideLog._();
  static final ShotGuideLog instance = ShotGuideLog._();

  static const String _fileName = 'phily_shots.json';

  final Map<String, ShotGuide> _byId = {};
  bool _loaded = false;
  Future<void>? _loading;

  bool get isLoaded => _loaded;

  ShotGuide? operator [](String assetId) => _byId[assetId];

  /// True when [assetId] locked to its guide.
  bool isOnGuide(String assetId) => _byId[assetId]?.locked ?? false;

  /// Ids of every on-guide shot, for the gallery filter.
  Set<String> get onGuideIds => {
    for (final e in _byId.entries)
      if (e.value.locked) e.key,
  };

  int get total => _byId.length;
  int get onGuideCount => _byId.values.where((g) => g.locked).length;

  /// 0..100, or null before the first guided shot exists.
  int? get onGuidePercent =>
      total == 0 ? null : (onGuideCount * 100 / total).round();

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final g = ShotGuide.fromJson(v);
            if (k is String && g != null) _byId[k] = g;
          });
        }
      }
    } catch (e) {
      debugPrint('ShotGuideLog: load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Record [guide] against a freshly saved asset and persist.
  Future<void> record(String assetId, ShotGuide guide) async {
    await load();
    _byId[assetId] = guide;
    notifyListeners();
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({for (final e in _byId.entries) e.key: e.value.toJson()}),
        flush: true,
      );
    } catch (e) {
      debugPrint('ShotGuideLog: write failed: $e');
    }
  }

  /// Forget a deleted asset.
  Future<void> remove(String assetId) async {
    if (_byId.remove(assetId) == null) return;
    notifyListeners();
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({for (final e in _byId.entries) e.key: e.value.toJson()}),
        flush: true,
      );
    } catch (_) {}
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }
}

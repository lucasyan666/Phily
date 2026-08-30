import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:phily/screens/branded_loader.dart';
import 'package:phily/theme.dart';

const _gold = kGold;

// ─────────────────────────────────────────────────────────────────────────────
// Shared glassy chrome (matches the camera page)
// ─────────────────────────────────────────────────────────────────────────────

/// A frosted-look top bar. Uses a dark gradient (NOT a real BackdropFilter blur)
/// so it's cheap to paint — a live blur here janks the open/close zoom badly.
/// Warm smoked glass over the grid, finished with the camera chrome's gold-leaf
/// lip so both screens read as the same slab of dark glass.
class _FrostBar extends StatelessWidget {
  final Widget child;
  const _FrostBar({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            kSmoke.withValues(alpha: 0.80),
            kSmoke.withValues(alpha: 0.44),
            kSmoke.withValues(alpha: 0.12),
          ],
          stops: const [0.0, 0.62, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          // Gold-leaf edge facing the photos — brightest at the centre, like
          // the camera panels' preview-facing lip.
          const GildedHairline(opacity: 0.55),
        ],
      ),
    );
  }
}

/// Gilded frost — the viewer's chrome material: a real BackdropFilter blur
/// under a smoked-glass sheen, finished with a fine gold rim ([rimmed]) and the
/// app's soft shadow. The full-screen viewer is mostly static, so unlike the
/// grid's faked frost it can afford true blur; the gilding ties it to the
/// camera's gold-leaf chrome. Sizes to its [child].
class _GildedFrost extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final bool rimmed; // false → caller draws its own rim (e.g. a metal bezel)
  const _GildedFrost({
    required this.child,
    required this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.rimmed = true,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      boxShadow: kSoftShadow,
    ),
    child: ClipRRect(
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAliasWithSaveLayer,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            // Smoked glass: a champagne-warmed sheen at the light source
            // melting into warm near-black, so the frost reads gilded, not grey.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.04),
                kSmoke.withValues(alpha: 0.44),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
            border: rimmed
                ? Border.all(color: kGold.withValues(alpha: 0.55), width: 0.9)
                : null,
          ),
          child: child,
        ),
      ),
    ),
  );
}

/// Floating frosted-glass action button (share / bin in the pager): a real
/// BackdropFilter disc with a top sheen, hairline rim and soft shadow. Springs
/// down on press; on tap it fires a haptic, a quick icon pop, and a ripple ring.
class _GlassCircleButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;
  final VoidCallback onTap;
  const _GlassCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconSize = 23,
  });

  @override
  State<_GlassCircleButton> createState() => _GlassCircleButtonState();
}

class _GlassCircleButtonState extends State<_GlassCircleButton>
    with SingleTickerProviderStateMixin {
  static const double _d = 54;
  bool _pressed = false;
  late final AnimationController _tap;

  @override
  void initState() {
    super.initState();
    _tap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 440),
    );
  }

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  void _onTap() {
    HapticFeedback.lightImpact();
    _tap.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: _onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: AnimatedBuilder(
          animation: _tap,
          builder: (context, _) {
            final t = _tap.value;
            final ripple = Curves.easeOut.transform(t);
            // Triangle 0→1→0 → a quick scale-up-and-back pop of the glyph.
            final tri = (1 - (2 * t - 1).abs()).clamp(0.0, 1.0);
            final pop = 1 + 0.26 * Curves.easeOut.transform(tri);
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Tap ripple — a champagne ring that expands past the button
                // and fades, echoing the app's gilded accents.
                if (t > 0 && t < 1)
                  Transform.scale(
                    scale: 0.85 + 0.7 * ripple,
                    child: Container(
                      width: _d,
                      height: _d,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: kGoldLit.withValues(alpha: 0.75 * (1 - t)),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                // Gilded frost disc — smoked blur, no flat rim: the machined
                // bezel below is the edge.
                _GildedFrost(
                  borderRadius: BorderRadius.circular(_d / 2),
                  rimmed: false,
                  child: SizedBox(
                    width: _d,
                    height: _d,
                    child: Center(
                      child: Transform.scale(
                        scale: pop,
                        child: Icon(
                          widget.icon,
                          color: kPaper,
                          size: widget.iconSize,
                          shadows: const [
                            Shadow(color: Colors.black38, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Machined-gold bezel — the same sweep-gradient ring the camera's
                // capture button wears, catching light from the upper-left.
                const IgnorePointer(
                  child: CustomPaint(
                    size: Size(_d, _d),
                    painter: MetalRingPainter(width: 1.6),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Widget _spinner() => const Center(
  child: SizedBox(
    width: 26,
    height: 26,
    child: CircularProgressIndicator(color: kGold, strokeWidth: 2),
  ),
);

String _fmtDuration(Duration d) {
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Today" / "Yesterday" / "14 Jun" / "14 Jun 2024" (year only when not current).
/// [now] is injectable so tests can pin the reference date; the app leaves it null.
String dateLabel(DateTime dt, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final days = today.difference(DateTime(dt.year, dt.month, dt.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final y = dt.year != ref.year ? ' ${dt.year}' : '';
  return '${dt.day} ${_months[dt.month - 1]}$y';
}

/// "1:03 PM".
String timeLabel(DateTime dt) {
  final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Grid — the gallery entry point
// ─────────────────────────────────────────────────────────────────────────────

/// A date group: a header label + the indices (into _items) it contains.
class _Section {
  final String label;
  final List<int> indices;
  _Section(this.label, this.indices);
}

/// Sticky date header bar. Opaque so grid cells don't show through while it's
/// pinned; pushed off by the next section's header (handled by SliverStickyHeader).
class _SectionHeaderBar extends StatelessWidget {
  final String label;
  const _SectionHeaderBar(this.label);

  @override
  Widget build(BuildContext context) {
    // One quiet treatment for every day — gold stays reserved for live
    // controls (scrub bubble, selection), so headers read as wayfinding.
    return Container(
      height: 30,
      color: Colors.black,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 14),
      child: Text(
        // Tracked small-caps date — the camera chrome's label voice.
        label.toUpperCase(),
        style: brandLabel(
          size: 11,
          weight: FontWeight.w600,
          color: kPaper.withValues(alpha: 0.85),
          letterSpacing: 2.4,
        ),
      ),
    );
  }
}

/// Calm empty state when the library (or the Phily filter) has nothing yet.
class _EmptyGallery extends StatelessWidget {
  final bool phily; // true → the ALL/PHILY filter is on Phily
  const _EmptyGallery({this.phily = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Soft gold aura behind the mark — the same warm glow as the loader.
          Container(
            width: 128,
            height: 128,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [kGold.withValues(alpha: 0.14), Colors.transparent],
                stops: const [0.0, 0.72],
              ),
            ),
            child: Icon(
              Icons.photo_library_outlined,
              color: kPaper.withValues(alpha: 0.30),
              size: 52,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            phily ? 'No Phily shots yet' : 'No photos yet',
            style: brandDisplay(
              size: 21,
              weight: FontWeight.w500,
              color: kPaper.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            phily
                ? 'Photos you capture with Phily appear here'
                : 'Photos you capture will appear here',
            style: brandLabel(
              size: 12.5,
              weight: FontWeight.w400,
              color: kPaper.withValues(alpha: 0.42),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// The date pill that floats beside the fast-scroll thumb while you scrub. Dark
/// faux-glass with a gold hairline + gold text, in theme with the app's chrome.
class _ScrubBubble extends StatelessWidget {
  final String label;
  const _ScrubBubble(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      // The camera's shared smoked-glass chip, gold-kissed (active) — the scrub
      // bubble is a "live" control, so it wears the lit rim.
      decoration: glassChipDecoration(radius: 14, active: true),
      child: Text(
        label,
        style: const TextStyle(
          color: _gold,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// A tiny fast-scroll handle pinned to the right edge. Touch it to grab (medium
/// haptic + it swells from a hairline pill into a gold one), then drag to scrub
/// the grid. Releases back to its slim resting state. In theme with the app's
/// gold accent + faux-glass chrome.
class _FastScrollThumb extends StatefulWidget {
  final ValueNotifier<double> frac; // current scroll position, 0..1
  final VoidCallback onGrab;
  final ValueChanged<double> onScrub;
  final String Function(double frac) labelForFrac; // date for the scrub bubble
  const _FastScrollThumb({
    required this.frac,
    required this.onGrab,
    required this.onScrub,
    required this.labelForFrac,
  });

  @override
  State<_FastScrollThumb> createState() => _FastScrollThumbState();
}

class _FastScrollThumbState extends State<_FastScrollThumb> {
  // A fixed-height touch slot keeps the grab geometry stable while the visible
  // pill grows/shrinks inside it.
  static const double _slotH = 64;
  static const double _touchW = 32;
  static const double _idleW = 4, _activeW = 8;
  static const double _idleH = 46, _activeH = 60;

  bool _active = false;
  double _dragFrac = 0;
  double _usable = 1;
  // Last date shown in the scrub bubble — a ratchet tick fires each time it
  // changes, so scrubbing through time feels detented (iOS Photos-style).
  String _scrubLabel = '';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _usable = (c.maxHeight - _slotH).clamp(1.0, double.infinity);
        return ValueListenableBuilder<double>(
          valueListenable: widget.frac,
          builder: (_, f, _) {
            final top = f.clamp(0.0, 1.0) * _usable;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // While grabbed, a date bubble floats to the left of the thumb
                // showing roughly where in time you've scrubbed to (iOS Photos).
                if (_active)
                  Positioned(
                    right: _touchW + 6,
                    top: (top + _slotH / 2 - 15).clamp(0.0, _usable + _slotH),
                    child: IgnorePointer(
                      child: _ScrubBubble(widget.labelForFrac(f)),
                    ),
                  ),
                Positioned(
                  right: 0,
                  top: top,
                  width: _touchW,
                  height: _slotH,
                  child: Listener(
                    // Opaque so the whole slim column grabs cleanly; pointer
                    // delta is in global space, so it tracks the finger even as
                    // the thumb repositions under it.
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) {
                      _dragFrac = f;
                      _scrubLabel = widget.labelForFrac(f);
                      setState(() => _active = true);
                      widget.onGrab();
                    },
                    onPointerMove: (e) {
                      _dragFrac = (_dragFrac + e.delta.dy / _usable).clamp(
                        0.0,
                        1.0,
                      );
                      widget.onScrub(_dragFrac);
                      // Ratchet tick each time the scrubbed-to date changes.
                      final String l = widget.labelForFrac(_dragFrac);
                      if (l != _scrubLabel) {
                        _scrubLabel = l;
                        HapticFeedback.selectionClick();
                      }
                    },
                    onPointerUp: (_) {
                      if (_active) setState(() => _active = false);
                    },
                    onPointerCancel: (_) {
                      if (_active) setState(() => _active = false);
                    },
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 170),
                        curve: Curves.easeOut,
                        margin: const EdgeInsets.only(right: 3),
                        width: _active ? _activeW : _idleW,
                        height: _active ? _activeH : _idleH,
                        decoration: BoxDecoration(
                          color: _active
                              ? _gold.withValues(alpha: 0.95)
                              : Colors.white.withValues(alpha: 0.32),
                          borderRadius: BorderRadius.circular(_active ? 5 : 3),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: _active ? 0.6 : 0.16,
                            ),
                            width: 0.5,
                          ),
                          boxShadow: _active
                              ? [
                                  BoxShadow(
                                    color: _gold.withValues(alpha: 0.45),
                                    blurRadius: 10,
                                    spreadRadius: 0.5,
                                  ),
                                ]
                              : const [],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// ALL / PHILY segmented switch in the gallery's top bar — the whole library,
/// or just the shots captured with the app. Same design language as the
/// camera's .5×/1× lens toggle: a smoked pill whose active segment is a
/// polished-gold chip with a soft glow.
class _AlbumToggle extends StatelessWidget {
  final bool philyOnly;
  final ValueChanged<bool> onChanged;
  const _AlbumToggle({required this.philyOnly, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool value) {
      final bool active = philyOnly == value;
      return GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: kDurFast,
          curve: kEaseOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            gradient: active
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [kGoldLit, kGold],
                  )
                : null,
            borderRadius: BorderRadius.circular(kRadiusLg),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: kGold.withValues(alpha: 0.35),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: brandLabel(
              size: 9.5,
              weight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.black : kPaper.withValues(alpha: 0.55),
              letterSpacing: 1.6,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(kRadiusLg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('ALL', false), seg('PHILY', true)],
      ),
    );
  }
}

/// A glassy grid of the library's photos & videos (most recent first). The asset
/// list is loaded once and cached; tap a cell to open the full-screen pager.
class GalleryGridPage extends StatefulWidget {
  final AssetPathEntity album;
  final int count;
  const GalleryGridPage({super.key, required this.album, required this.count});

  @override
  State<GalleryGridPage> createState() => _GalleryGridPageState();
}

class _GalleryGridPageState extends State<GalleryGridPage> {
  // Load in pages so the grid paints almost instantly instead of waiting for the
  // whole library; more pages stream in as you scroll near the bottom.
  static const int _pageSize = 120;
  List<AssetEntity> _items = [];
  bool _loading = true;
  int _loadedPages = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  // Live pull-to-dismiss distance (px past the top). A ValueNotifier so only the
  // dim overlay repaints as you pull — the GridView is never rebuilt mid-pull.
  final ValueNotifier<double> _pull = ValueNotifier(0);
  bool _dismissing = false; // guard so we pop only once
  // Loaded grid thumbnails by asset id → handed to the viewer as an instant
  // placeholder so opening a photo/video doesn't flash a spinner. Capped with
  // LRU eviction (see _cacheThumb) so a huge library can't grow it without bound.
  static const int _thumbCacheCap = 300;
  final Map<String, Uint8List> _thumbCache = {};
  // Multi-select: long-press to enter, tap to toggle, batch share/delete.
  bool _selectMode = false;
  final Set<String> _selectedIds = {};
  // ALL / PHILY filter: everything in the library, or just the shots captured
  // with the app (they save into the 'Phily' album — see _saveMediaInBackground
  // on the camera page). The album handle is resolved lazily on first switch.
  bool _philyOnly = false;
  AssetPathEntity? _philyAlbum;
  bool _philyAlbumResolved = false;
  // Bumped on every filter switch; in-flight page loads compare against it and
  // drop their results if the user has toggled again mid-await.
  int _albumEpoch = 0;
  // Fast-scroll thumb: a tiny grabbable pill on the right edge. The controller
  // lets us jump the grid as you drag; the notifier feeds the thumb's position
  // (0..1) without rebuilding the grid.
  final ScrollController _scrollCtrl = ScrollController();
  final ValueNotifier<double> _scrollFrac = ValueNotifier(0);

  // Defer the first asset load until the slide-up transition finishes (see
  // didChangeDependencies), so the heavy first grid build doesn't jank the open.
  bool _loadStarted = false;
  Animation<double>? _enterAnim;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadStarted || _enterAnim != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      _startLoad();
    } else {
      _enterAnim = anim..addStatusListener(_onEnter);
    }
  }

  void _onEnter(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _enterAnim?.removeStatusListener(_onEnter);
    _enterAnim = null;
    _startLoad();
  }

  void _startLoad() {
    if (_loadStarted) return;
    _loadStarted = true;
    _load();
  }

  @override
  void dispose() {
    _enterAnim?.removeStatusListener(_onEnter);
    _pull.dispose();
    _scrollCtrl.dispose();
    _scrollFrac.dispose();
    super.dispose();
  }

  /// The album the grid is currently reading from: the whole library, or the
  /// app's own 'Phily' album when the filter is on (null until it's resolved —
  /// or forever, if nothing has been captured with the app yet).
  AssetPathEntity? get _activeAlbum => _philyOnly ? _philyAlbum : widget.album;

  /// Switch the ALL / PHILY filter: resolve the Phily album on first use, then
  /// reload the grid from page zero. Epoch-guarded so a quick double-toggle
  /// can't interleave stale pages.
  Future<void> _setPhilyOnly(bool v) async {
    if (_philyOnly == v) return;
    hapticTap();
    _albumEpoch++;
    setState(() {
      _philyOnly = v;
      _selectMode = false;
      _selectedIds.clear();
      _items = [];
      _loadedPages = 0;
      _hasMore = true;
      _loadingMore = false;
      _loading = true;
    });
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    if (v && !_philyAlbumResolved) {
      // Find the app's own album once (created by the first in-app capture).
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
      );
      if (!mounted) return;
      _philyAlbumResolved = true;
      for (final p in paths) {
        if (p.name == 'Phily') {
          _philyAlbum = p;
          break;
        }
      }
    }
    await _load();
  }

  Future<void> _load() async {
    final int epoch = _albumEpoch;
    final AssetPathEntity? album = _activeAlbum;
    if (album == null) {
      // Phily filter on, but nothing captured with the app yet → empty state.
      if (mounted && epoch == _albumEpoch) setState(() => _loading = false);
      return;
    }
    // Just the first page → grid appears right away.
    final first = await album.getAssetListPaged(page: 0, size: _pageSize);
    if (!mounted || epoch != _albumEpoch) return;
    setState(() {
      _items = first;
      _loadedPages = 1;
      _hasMore = first.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final int epoch = _albumEpoch;
    final AssetPathEntity? album = _activeAlbum;
    if (album == null) return;
    _loadingMore = true;
    final next = await album.getAssetListPaged(
      page: _loadedPages,
      size: _pageSize,
    );
    if (!mounted || epoch != _albumEpoch) {
      _loadingMore = false;
      return;
    }
    // Dedupe by id (deletions shift page boundaries, which can re-yield an item).
    final seen = _items.map((a) => a.id).toSet();
    final fresh = next.where((a) => !seen.contains(a.id)).toList();
    setState(() {
      _items.addAll(fresh);
      _loadedPages++;
      _hasMore = next.length == _pageSize;
      _loadingMore = false;
    });
  }

  // Group consecutive items by capture day ("Today" / "14 Jun"). _items is
  // already most-recent-first, so days come out in descending order.
  List<_Section> _buildSections() {
    final out = <_Section>[];
    String? key;
    for (var i = 0; i < _items.length; i++) {
      final dt = _items[i].createDateTime;
      final k = '${dt.year}.${dt.month}.${dt.day}';
      if (k != key) {
        key = k;
        out.add(_Section(dateLabel(dt), []));
      }
      out.last.indices.add(i);
    }
    return out;
  }

  void _enterSelect(AssetEntity a) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectMode = true;
      _selectedIds.add(a.id);
    });
  }

  void _toggleSelect(AssetEntity a) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selectedIds.remove(a.id)) _selectedIds.add(a.id);
      if (_selectedIds.isEmpty) _selectMode = false;
    });
  }

  void _exitSelect() => setState(() {
    _selectMode = false;
    _selectedIds.clear();
  });

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    // iOS shows one confirmation for the batch; returns the ids it removed.
    final deleted = await PhotoManager.editor.deleteWithIds(
      _selectedIds.toList(),
    );
    if (deleted.isEmpty || !mounted) return;
    HapticFeedback.heavyImpact();
    final del = deleted.toSet();
    setState(() {
      _items.removeWhere((a) => del.contains(a.id));
      for (final id in deleted) {
        _thumbCache.remove(id);
      }
      _selectedIds.clear();
      _selectMode = false;
    });
  }

  Future<void> _shareSelected() async {
    if (_selectedIds.isEmpty) return;
    final chosen = _items.where((a) => _selectedIds.contains(a.id)).toList();
    final files = <XFile>[];
    for (final a in chosen) {
      final f = await a.file;
      if (f != null) files.add(XFile(f.path));
    }
    if (files.isEmpty || !mounted) return;
    final size = MediaQuery.of(context).size;
    await Share.shareXFiles(
      files,
      sharePositionOrigin:
          Offset(size.width / 2 - 1, size.height - 1) & const Size(2, 2),
    );
    if (mounted) _exitSelect();
  }

  bool _onScroll(ScrollNotification n) {
    // BouncingScrollPhysics lets the position go past the top (pixels < 0)
    // instead of firing an OverscrollNotification — so read the position
    // directly. `past` = how far the grid is pulled below the top edge.
    final double past = -n.metrics.pixels;
    if (past > 110 && !_dismissing) {
      _dismissing = true;
      HapticFeedback.lightImpact(); // the "released" click as it lets go
      Navigator.of(context).pop(); // pull past the top → close to the camera
      return true;
    }
    // Drive the dim via the notifier only — no setState, so the grid isn't
    // rebuilt. The bounce springs `pixels` back to 0 on release, fading it out.
    final double v = past > 0 ? past : 0;
    if (_pull.value != v) _pull.value = v;
    // Feed the fast-scroll thumb its 0..1 position.
    final double max = n.metrics.maxScrollExtent;
    final double f = max > 0 ? (n.metrics.pixels / max).clamp(0.0, 1.0) : 0.0;
    if (_scrollFrac.value != f) _scrollFrac.value = f;
    // Prefetch the next page well before the user hits the bottom.
    if (_hasMore &&
        !_loadingMore &&
        n.metrics.pixels >= n.metrics.maxScrollExtent - 1500) {
      _loadMore();
    }
    return false;
  }

  // Drag the fast-scroll thumb → jump the grid to that fraction of its extent.
  void _scrubTo(double frac) {
    if (!_scrollCtrl.hasClients) return;
    final max = _scrollCtrl.position.maxScrollExtent;
    _scrollCtrl.jumpTo((frac * max).clamp(0.0, max));
  }

  Future<void> _openAt(int i) async {
    // Pass the cached list; the viewer returns the id of anything it deleted.
    final deletedId = await Navigator.of(context).push<String>(
      PageRouteBuilder(
        // Opaque so nothing heavy (the full grid + its frosted blurs) renders
        // behind the viewer during the open — that was the source of the jank.
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, _, _) => GalleryViewerPage(
          assets: _items,
          initialIndex: i,
          thumbs: _thumbCache,
        ),
        // Zoom in: scale up from the thumbnail size + fade.
        transitionsBuilder: (_, anim, _, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.86, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (deletedId != null && mounted) {
      // Just drop the one item — the remaining cells keep their loaded
      // thumbnails (keyed by id) and simply shift up. No reload.
      setState(() => _items.removeWhere((a) => a.id == deletedId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final barH = MediaQuery.of(context).padding.top + 52;
    final bottomPad = MediaQuery.of(context).padding.bottom + 8;
    final sections = _buildSections();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_loading)
            const BrandedLoader()
          else if (_items.isEmpty)
            _EmptyGallery(phily: _philyOnly)
          else
            // Inset below the bar so pinned date headers sit under it, not behind.
            Padding(
              padding: EdgeInsets.only(top: barH),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: CustomScrollView(
                  controller: _scrollCtrl,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    // Each header pins only while its own section is on screen;
                    // the next day's header pushes it up and replaces it (iOS
                    // Photos behaviour) instead of stacking.
                    for (final s in sections)
                      SliverStickyHeader(
                        header: _SectionHeaderBar(s.label),
                        sliver: SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 3,
                                  crossAxisSpacing: 3,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (_, j) => _cell(s.indices[j]),
                              childCount: s.indices.length,
                            ),
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
                  ],
                ),
              ),
            ),

          // Cheap dim that follows the pull (springs back with the bounce).
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<double>(
                valueListenable: _pull,
                builder: (_, p, _) {
                  final a = (p / 150).clamp(0.0, 0.9);
                  if (a <= 0.001) return const SizedBox.shrink();
                  return ColoredBox(color: Colors.black.withValues(alpha: a));
                },
              ),
            ),
          ),

          // Fast-scroll thumb on the right edge (only worth showing once the
          // library is long enough to actually scroll).
          if (!_loading && _items.length > 24)
            Positioned(
              top: barH,
              right: 0,
              bottom: bottomPad,
              width: 32,
              child: _FastScrollThumb(
                frac: _scrollFrac,
                onGrab: () => HapticFeedback.mediumImpact(),
                onScrub: _scrubTo,
                // Approximate the date by mapping the scroll fraction linearly
                // onto the loaded items — close enough for a scrub hint.
                labelForFrac: (frac) {
                  if (_items.isEmpty) return '';
                  final i = (frac * (_items.length - 1)).round().clamp(
                    0,
                    _items.length - 1,
                  );
                  return dateLabel(_items[i].createDateTime);
                },
              ),
            ),

          // Top bar — "Photos" normally; selection controls in select mode.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _FrostBar(child: _topBar(context)),
          ),
        ],
      ),
    );
  }

  // Insert a freshly-decoded thumbnail, refreshing its recency and evicting the
  // oldest once we're over the cap. Insertion order = recency here (Dart maps are
  // linked), which is good enough since cells reload as you scroll back to them.
  void _cacheThumb(String id, Uint8List bytes) {
    _thumbCache.remove(id);
    _thumbCache[id] = bytes;
    while (_thumbCache.length > _thumbCacheCap) {
      _thumbCache.remove(_thumbCache.keys.first);
    }
  }

  Widget _cell(int i) {
    final asset = _items[i];
    return GestureDetector(
      key: ValueKey(asset.id),
      onTap: () => _selectMode ? _toggleSelect(asset) : _openAt(i),
      onLongPress: _selectMode ? null : () => _enterSelect(asset),
      child: _GridThumb(
        asset: asset,
        selecting: _selectMode,
        selected: _selectedIds.contains(asset.id),
        onLoaded: (b) => _cacheThumb(asset.id, b),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top + 4;
    if (_selectMode) {
      return Padding(
        padding: EdgeInsets.only(top: topInset, bottom: 10, left: 8, right: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: _exitSelect,
            ),
            Expanded(
              child: Text(
                // Tracked small-caps — the brand's chrome-label voice.
                '${_selectedIds.length} SELECTED',
                textAlign: TextAlign.center,
                style: brandLabel(size: 12.5, letterSpacing: 2.2),
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.ios_share_rounded,
                color: _selectedIds.isEmpty
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.white,
              ),
              onPressed: _selectedIds.isEmpty ? null : _shareSelected,
            ),
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                color: _selectedIds.isEmpty
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.white,
              ),
              onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: topInset, bottom: 10, left: 16, right: 16),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Tracked small-caps — the same chrome-label voice as the camera page.
          Text(
            'GALLERY',
            style: brandLabel(
              size: 13.5,
              weight: FontWeight.w600,
              letterSpacing: 3.2,
            ),
          ),
          // ALL / PHILY filter, floated on the right edge of the bar.
          Align(
            alignment: Alignment.centerRight,
            child: _AlbumToggle(
              philyOnly: _philyOnly,
              onChanged: _setPhilyOnly,
            ),
          ),
        ],
      ),
    );
  }
}

/// One square grid cell — small thumbnail + a video badge. Caches its thumbnail
/// in state; keyed by asset id so it survives list re-orders without reloading.
class _GridThumb extends StatefulWidget {
  final AssetEntity asset;
  final void Function(Uint8List bytes)? onLoaded;
  final bool selecting; // multi-select mode is active
  final bool selected; // this cell is selected
  const _GridThumb({
    required this.asset,
    this.onLoaded,
    this.selecting = false,
    this.selected = false,
  });

  @override
  State<_GridThumb> createState() => _GridThumbState();
}

class _GridThumbState extends State<_GridThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    widget.asset
        .thumbnailDataWithSize(const ThumbnailSize(300, 300), quality: 80)
        .then((b) {
          if (mounted) setState(() => _bytes = b);
          if (b != null) widget.onLoaded?.call(b); // cache for instant open
        });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    const radius = BorderRadius.all(Radius.circular(kRadiusSm));
    if (bytes == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: radius,
        ),
      );
    }
    final isVideo = widget.asset.type == AssetType.video;
    // Gentle fade-in as each thumbnail loads (instead of popping in).
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(opacity: t, child: child),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Selected cells shrink slightly to read as "lifted".
          AnimatedScale(
            scale: widget.selected ? 0.86 : 1.0,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: Container(
              // A gold rim hugs the lifted cell while it's selected.
              foregroundDecoration: widget.selected
                  ? BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.75),
                        width: 1.4,
                      ),
                    )
                  : null,
              child: ClipRRect(
                borderRadius: radius,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          if (isVideo)
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: kSmoke.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(kRadiusSm),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                    width: 0.6,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 13,
                    ),
                    const SizedBox(width: 1),
                    Text(
                      _fmtDuration(widget.asset.videoDuration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Selection check (multi-select mode): polished-gold metal when
          // selected (champagne→antique, like the paywall badge), hollow otherwise.
          if (widget.selecting)
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: widget.selected
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [kGoldLit, kGold, kGoldDeep],
                        )
                      : null,
                  color: widget.selected
                      ? null
                      : Colors.black.withValues(alpha: 0.3),
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: widget.selected
                      ? [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.55),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
                child: widget.selected
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.black,
                        size: 15,
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-screen pager
// ─────────────────────────────────────────────────────────────────────────────

/// Full-screen, swipeable viewer over the cached [assets]. Photos pinch-to-zoom;
/// videos play inline. Swipe down to dismiss; delete flies the item into the
/// bin and pops with the deleted id.
class GalleryViewerPage extends StatefulWidget {
  final List<AssetEntity> assets;
  final int initialIndex;
  final Map<String, Uint8List> thumbs; // instant placeholders by asset id

  const GalleryViewerPage({
    super.key,
    required this.assets,
    this.initialIndex = 0,
    this.thumbs = const {},
  });

  @override
  State<GalleryViewerPage> createState() => _GalleryViewerPageState();
}

class _GalleryViewerPageState extends State<GalleryViewerPage>
    with TickerProviderStateMixin {
  late final PageController _controller;
  late int _index;
  // Anchor for the iOS share sheet popover (the Share button's rect).
  final GlobalKey _shareBtnKey = GlobalKey();
  // Swipe-down-to-dismiss: live drag distance (px). Driven through a notifier so
  // a drag repaints only the transforms — it never rebuilds the PageView/video
  // underneath (that per-frame rebuild was the jitter). _springCtrl eases the
  // distance back to rest when you release below the dismiss threshold.
  final ValueNotifier<double> _drag = ValueNotifier(0);
  late final AnimationController _springCtrl;
  double _springFrom = 0;
  // "Sucked into the bin" delete animation.
  late final AnimationController _deleteCtrl;
  bool _deleting = false;
  // Immersive viewing: tap a photo to hide the top bar + buttons.
  bool _chromeVisible = true;
  // Whether the swipe-down drag is past the release-to-close threshold —
  // debounces the threshold click so it fires once per crossing.
  bool _pastDismiss = false;
  // True once the open-zoom transition has settled. The gilded-frost chrome
  // (three real BackdropFilter blurs) is NOT painted until then — a blur
  // re-rasterises every frame while the page scales, which was the jitter in
  // the open animation. Chrome fades in the moment the photo lands instead.
  bool _entered = false;
  Animation<double>? _enterAnim;

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  // Fades a chrome element with the tap-to-hide toggle and blocks its taps once
  // hidden; held at 0 (unpainted, so its blur costs nothing) until the open
  // transition settles. (The inner Opacity still handles the swipe-down/delete
  // fades.)
  Widget _chrome(Widget child) {
    final bool shown = _chromeVisible && _entered;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: child,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
    _deleteCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _springCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 240),
        )..addListener(() {
          _drag.value =
              _springFrom * (1 - Curves.easeOut.transform(_springCtrl.value));
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entered || _enterAnim != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      _entered = true;
    } else {
      _enterAnim = anim..addStatusListener(_onEnterStatus);
    }
  }

  void _onEnterStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _enterAnim?.removeStatusListener(_onEnterStatus);
    _enterAnim = null;
    if (mounted) setState(() => _entered = true);
  }

  @override
  void dispose() {
    _enterAnim?.removeStatusListener(_onEnterStatus);
    _controller.dispose();
    _deleteCtrl.dispose();
    _springCtrl.dispose();
    _drag.dispose();
    super.dispose();
  }

  Future<void> _deleteCurrent() async {
    if (_deleting) return;
    final asset = widget.assets[_index];
    // iOS shows its own (mandatory) delete-confirmation sheet; returns the ids
    // it actually removed (empty if the user cancelled).
    final deleted = await PhotoManager.editor.deleteWithIds([asset.id]);
    if (deleted.isEmpty || !mounted) return;
    HapticFeedback.lightImpact(); // gentle — it lifts off
    setState(() => _deleting = true);
    await _deleteCtrl.forward(from: 0);
    HapticFeedback.heavyImpact(); // stronger — it drops into the bin
    if (mounted) Navigator.of(context).pop(asset.id);
  }

  Future<void> _shareCurrent() async {
    final asset = widget.assets[_index];
    final file = await asset.file; // resolves the photo/video to a temp file
    if (file == null || !mounted) return;
    HapticFeedback.selectionClick();
    // iOS requires a non-zero anchor rect (the iPad popover source; newer iOS
    // rejects a zero rect even on iPhone). Anchor it to the Share button.
    final box = _shareBtnKey.currentContext?.findRenderObject() as RenderBox?;
    final Rect origin = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : (Offset.zero & MediaQuery.of(context).size);
    // Native iOS share sheet — covers Instagram, Messages, WhatsApp, AirDrop,
    // Save to Files, etc. The destination app handles its own auth; no login.
    await Share.shareXFiles([XFile(file.path)], sharePositionOrigin: origin);
  }

  // ── Swipe-down-to-dismiss, via RAW pointer events ──────────────────────────
  // Deliberately NOT a GestureDetector drag: a drag recognizer that wins the
  // gesture arena keeps every later-landing finger for itself, so a pinch only
  // worked if both fingers touched down almost simultaneously. Raw Listener
  // events sit outside the arena entirely — the InteractiveViewer's scale
  // recognizer now always gets the pinch, however late the second finger
  // arrives, while single-finger downward drags still drive the dismiss.
  final Set<int> _livePointers = {};
  int _primaryPointer = -1;
  bool _dismissTracking = false;
  Offset _pointerDownPos = Offset.zero;
  VelocityTracker? _vt;
  // True while the current page is pinch-zoomed — its pan owns vertical drags,
  // so the dismiss must stand down (reported up by the photo/video pages).
  bool _pageZoomed = false;

  void _onPointerDown(PointerDownEvent e) {
    _livePointers.add(e.pointer);
    if (_livePointers.length == 1) {
      _primaryPointer = e.pointer;
      _pointerDownPos = e.position;
      _vt = VelocityTracker.withKind(e.kind)
        ..addPosition(e.timeStamp, e.position);
      if (_springCtrl.isAnimating) _springCtrl.stop();
    } else {
      // Second finger → this is a pinch, never a dismiss. Spring back.
      _cancelDismiss();
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_livePointers.length != 1 ||
        e.pointer != _primaryPointer ||
        _pageZoomed) {
      return;
    }
    _vt?.addPosition(e.timeStamp, e.position);
    if (!_dismissTracking) {
      // Begin only once the drag is decisively downward — horizontal motion
      // belongs to the PageView, ambiguous wiggle to nobody.
      final Offset total = e.position - _pointerDownPos;
      if (total.dy > 14 && total.dy.abs() > total.dx.abs() * 1.4) {
        _dismissTracking = true;
      } else {
        return;
      }
    }
    // Track the finger 1:1 via the notifier — no setState, so the page/video
    // isn't rebuilt mid-drag.
    final v = _drag.value + e.delta.dy;
    _drag.value = v < 0 ? 0 : v; // downward only
    // One light click the moment the drag crosses the release-to-close
    // threshold — you know it'll dismiss before you let go.
    final bool past = _drag.value > 110;
    if (past && !_pastDismiss) HapticFeedback.lightImpact();
    _pastDismiss = past;
  }

  void _onPointerUp(PointerUpEvent e) {
    _livePointers.remove(e.pointer);
    if (e.pointer != _primaryPointer || !_dismissTracking) return;
    _dismissTracking = false;
    _pastDismiss = false;
    final double vy = _vt?.getVelocity().pixelsPerSecond.dy ?? 0;
    _vt = null;
    if (_drag.value > 110 || vy > 700) {
      Navigator.of(context).pop();
    } else {
      _springFrom = _drag.value;
      _springCtrl.forward(from: 0); // ease smoothly back to rest
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _livePointers.remove(e.pointer);
    if (e.pointer == _primaryPointer) _cancelDismiss();
  }

  /// Abort an in-progress dismiss (second finger landed / pointer cancelled):
  /// ease the page back to rest.
  void _cancelDismiss() {
    _vt = null;
    if (!_dismissTracking && _drag.value == 0) return;
    _dismissTracking = false;
    _pastDismiss = false;
    if (_drag.value > 0) {
      _springFrom = _drag.value;
      _springCtrl.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final screenW = size.width;
    final screenH = size.height;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    // Bin sits bottom-right; the delete animation flies the photo into it.
    final binDx = (screenW - 40) - screenW / 2;
    final binDy = (screenH - safeBottom - 40) - screenH / 2;
    final total = widget.assets.length;

    return Scaffold(
      backgroundColor: Colors.black, // opaque → nothing heavy renders behind
      // Raw pointer tracking (not a drag GestureDetector) so the dismiss never
      // steals late-landing pinch fingers from the InteractiveViewer.
      body: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        // Repaints on drag/delete only; the PageView is the cached `child`, so
        // swiping to dismiss never rebuilds the photo/video underneath.
        child: AnimatedBuilder(
          animation: Listenable.merge([_drag, _deleteCtrl]),
          child: PageView.builder(
            controller: _controller,
            itemCount: total,
            onPageChanged: (i) => setState(() {
              _index = i;
              _pageZoomed = false; // fresh page starts unzoomed
            }),
            itemBuilder: (_, i) => _GalleryPage(
              asset: widget.assets[i],
              active: i == _index,
              placeholder: widget.thumbs[widget.assets[i].id],
              onTap: _toggleChrome,
              chromeVisible: _chromeVisible,
              onZoomed: (z) => _pageZoomed = z,
            ),
          ),
          builder: (context, pageView) {
            final dragDy = _drag.value;
            final progress = (dragDy / 240).clamp(0.0, 1.0);
            final chromeOpacity = (1 - progress * 2.2).clamp(0.0, 1.0);
            // The photo/video itself fades as it's dragged down, not just slides.
            final imgOpacity = (1 - progress * 1.3).clamp(0.0, 1.0);
            final dt = Curves.easeIn.transform(_deleteCtrl.value);
            final chrome = (chromeOpacity * (1 - _deleteCtrl.value)).clamp(
              0.0,
              1.0,
            );
            return Stack(
              children: [
                // Backdrop dims back in as you release, fades out as you drag.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: (1 - progress).clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                ),
                // Page — follows the finger (translate + slight scale), then
                // flies into the bin while deleting.
                Transform.translate(
                  offset: Offset(0, dragDy),
                  child: Transform.scale(
                    scale: 1 - progress * 0.06,
                    child: Transform.translate(
                      offset: Offset(binDx * dt, binDy * dt),
                      child: Transform.scale(
                        scale: 1 - 0.9 * dt,
                        child: Opacity(
                          opacity: ((1 - dt) * imgOpacity).clamp(0.0, 1.0),
                          child: pageView,
                        ),
                      ),
                    ),
                  ),
                ),

                // Floating glass date bubble — the same glossy material as the
                // action buttons, instead of a full-width top panel.
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  left: 0,
                  right: 0,
                  child: _chrome(
                    Opacity(
                      opacity: chrome,
                      child: Center(
                        child: _GildedFrost(
                          borderRadius: BorderRadius.circular(kRadiusLg),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 7,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Chrome-label voice (matches the camera page);
                              // the time glints in gold below the date.
                              Text(
                                dateLabel(
                                  widget.assets[_index].createDateTime,
                                ),
                                style: brandLabel(
                                  size: 12.5,
                                  weight: FontWeight.w600,
                                  letterSpacing: 0.6,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                timeLabel(
                                  widget.assets[_index].createDateTime,
                                ),
                                style: brandLabel(
                                  size: 9,
                                  weight: FontWeight.w500,
                                  color: kGold.withValues(alpha: 0.95),
                                  letterSpacing: 1.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Floating glassy share (bottom-left) + bin (bottom-right).
                Positioned(
                  left: 16,
                  bottom: safeBottom + 6,
                  child: _chrome(
                    Opacity(
                      opacity: chrome,
                      child: _GlassCircleButton(
                        key: _shareBtnKey,
                        icon: Icons.ios_share_rounded,
                        iconSize: 22,
                        onTap: _shareCurrent,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: safeBottom + 6,
                  child: _chrome(
                    Opacity(
                      opacity: chrome,
                      child: _GlassCircleButton(
                        icon: Icons.delete_outline_rounded,
                        onTap: _deleteCurrent,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Dispatches a page to the photo or video view.
class _GalleryPage extends StatelessWidget {
  final AssetEntity asset;
  final bool active;
  final Uint8List? placeholder;
  final VoidCallback? onTap; // tap → hide/show the chrome (photos AND videos)
  final bool chromeVisible; // the viewer's chrome state (videos fade their UI)
  final ValueChanged<bool>? onZoomed; // pinch state up to the viewer's dismiss
  const _GalleryPage({
    required this.asset,
    required this.active,
    this.placeholder,
    this.onTap,
    this.chromeVisible = true,
    this.onZoomed,
  });

  @override
  Widget build(BuildContext context) {
    return asset.type == AssetType.video
        ? _VideoPage(
            asset: asset,
            active: active,
            placeholder: placeholder,
            onTap: onTap,
            chromeVisible: chromeVisible,
            onZoomed: onZoomed,
          )
        : _PhotoPage(
            asset: asset,
            placeholder: placeholder,
            onTap: onTap,
            onZoomed: onZoomed,
          );
  }
}

/// A pinch- and double-tap-zoom photo. Loads a high-res JPEG thumbnail once.
class _PhotoPage extends StatefulWidget {
  final AssetEntity asset;
  final Uint8List? placeholder;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onZoomed; // report pinch state to the viewer
  const _PhotoPage({
    required this.asset,
    this.placeholder,
    this.onTap,
    this.onZoomed,
  });

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage>
    with SingleTickerProviderStateMixin {
  Uint8List? _bytes;
  // Full-res is decoded lazily on the first zoom (see _loadFullRes). _fullLoaded
  // guards the smaller 1440px preview from clobbering it if it resolves later.
  bool _fullRequested = false;
  bool _fullLoaded = false;
  bool _previewRequested = false;
  Animation<double>? _routeAnim;
  final TransformationController _tc = TransformationController();
  bool _zoomed = false;
  late final AnimationController _zoomCtrl;
  Animation<Matrix4>? _zoomAnim;
  TapDownDetails? _doubleTapPos;

  @override
  void initState() {
    super.initState();
    _zoomCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 240),
        )..addListener(() {
          if (_zoomAnim != null) _tc.value = _zoomAnim!.value;
        });
    // Show the grid's already-decoded thumbnail instantly — zero work during
    // the open transition. The 1440px sharpen is deferred until the zoom has
    // settled (didChangeDependencies): decoding it mid-animation swapped the
    // full-screen texture mid-zoom, which read as a jitter.
    _bytes = widget.placeholder;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_previewRequested || _routeAnim != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      _loadPreview();
    } else {
      _routeAnim = anim..addStatusListener(_onRouteStatus);
    }
  }

  void _onRouteStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _routeAnim = null;
    _loadPreview();
  }

  // Sharpen from the grid thumbnail to a 1440px preview (post-transition).
  void _loadPreview() {
    if (_previewRequested) return;
    _previewRequested = true;
    widget.asset
        .thumbnailDataWithSize(const ThumbnailSize(1440, 1440), quality: 90)
        .then((b) {
          // Don't downgrade a full-res image that may have arrived first.
          if (mounted && b != null && !_fullLoaded) {
            setState(() => _bytes = b);
          }
        });
  }

  // Lazily decode the photo at (near) native resolution the first time the user
  // zooms — so pinching in to check focus/sharpness stays crisp instead of
  // magnifying the 1440px preview. Requested as a JPEG thumbnail at the asset's
  // own pixel size (not originBytes) so HEIC captures still decode in Flutter.
  void _loadFullRes() {
    if (_fullRequested) return;
    _fullRequested = true;
    final w = widget.asset.width > 0 ? widget.asset.width : 3000;
    final h = widget.asset.height > 0 ? widget.asset.height : 3000;
    widget.asset.thumbnailDataWithSize(ThumbnailSize(w, h), quality: 95).then((
      b,
    ) {
      if (mounted && b != null) {
        _fullLoaded = true;
        setState(() => _bytes = b);
      }
    });
  }

  @override
  void dispose() {
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _zoomCtrl.dispose();
    _tc.dispose();
    super.dispose();
  }

  // Update the zoom flag + report it to the viewer (its swipe-down dismiss
  // stands down while the photo is zoomed, so pans stay pans).
  void _setZoomed(bool z) {
    if (z == _zoomed) return;
    setState(() => _zoomed = z);
    widget.onZoomed?.call(z);
  }

  void _onInteractionEnd() {
    _setZoomed(_tc.value.getMaxScaleOnAxis() > 1.02);
  }

  // Double-tap: zoom to the tapped point (2.6×), or snap back if already zoomed.
  void _handleDoubleTap() {
    final Matrix4 target;
    if (_tc.value.getMaxScaleOnAxis() > 1.02) {
      target = Matrix4.identity();
    } else {
      _loadFullRes(); // sharpen as we zoom in
      const double scale = 2.6;
      final p = _doubleTapPos?.localPosition ?? Offset.zero;
      target = Matrix4.identity()
        ..translateByDouble(-p.dx * (scale - 1), -p.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, scale, 1);
    }
    _zoomAnim = Matrix4Tween(
      begin: _tc.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOutCubic));
    _zoomCtrl.forward(from: 0).whenComplete(() {
      if (mounted) _setZoomed(target.getMaxScaleOnAxis() > 1.02);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return _spinner();
    // Pan only while zoomed → at 1× the PageView keeps horizontal swipes and the
    // pager keeps vertical drags free for swipe-to-dismiss.
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _doubleTapPos = d,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1.0,
        maxScale: 5.0,
        panEnabled: _zoomed,
        onInteractionUpdate: (_) {
          // Kick off the full-res decode the moment a pinch passes 1× — not on
          // plain taps or pager swipes (scale stays ~1.0 for those).
          if (!_fullRequested && _tc.value.getMaxScaleOnAxis() > 1.05) {
            _loadFullRes();
          }
        },
        onInteractionEnd: (_) => _onInteractionEnd(),
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}

/// Inline video playback. Tap to play/pause; scrub at the bottom. Auto-pauses
/// when swiped off-screen.
class _VideoPage extends StatefulWidget {
  final AssetEntity asset;
  final bool active;
  final Uint8List? placeholder;
  final VoidCallback? onTap; // tap → hide/show the chrome (like photos)
  final bool chromeVisible; // fades the scrubber row with the viewer chrome
  final ValueChanged<bool>? onZoomed; // report pinch state to the viewer
  const _VideoPage({
    required this.asset,
    required this.active,
    this.placeholder,
    this.onTap,
    this.chromeVisible = true,
    this.onZoomed,
  });

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _vc;
  // Pinch-zoom, same as photos: pan only while zoomed so the PageView keeps
  // horizontal swipes and the viewer keeps swipe-down-to-dismiss at 1×.
  final TransformationController _tc = TransformationController();
  bool _zoomed = false;
  // The ENTIRE player init (file resolve + AVPlayer spin-up), not just
  // autoplay, waits for the open transition to settle — initialising the
  // decoder mid-animation janks the zoom-in. The grid thumbnail posters the
  // page in the meantime. _enterDone flips true when the route's enter
  // animation completes (or is already past it on a later swipe).
  bool _enterDone = false;
  bool _initStarted = false;
  Animation<double>? _routeAnim;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_enterDone || _routeAnim != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      _enterDone = true;
      _init();
    } else {
      _routeAnim = anim..addStatusListener(_onRouteStatus);
    }
  }

  void _onRouteStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _routeAnim = null;
    _enterDone = true;
    _init(); // _tryPlay fires from _init once the controller is ready
  }

  Future<void> _init() async {
    if (_initStarted) return;
    _initStarted = true;
    final file = await widget.asset.file;
    if (file == null || !mounted) return;
    final vc = VideoPlayerController.file(file);
    try {
      await vc.initialize();
    } catch (_) {
      await vc.dispose();
      return;
    }
    if (!mounted) {
      await vc.dispose();
      return;
    }
    await vc.setLooping(true);
    setState(() => _vc = vc);
    _tryPlay(); // play as soon as it's ready and the open animation is done
  }

  // Set when the user explicitly pauses via the play/pause chip — nothing may
  // auto-resume it (chrome-toggle rebuilds used to restart a paused video).
  bool _userPaused = false;

  // Play when this page is the active one, the open transition has finished,
  // and the user hasn't deliberately paused it.
  void _tryPlay() {
    final vc = _vc;
    if (vc == null || !mounted || !widget.active || !_enterDone) return;
    if (_userPaused) return; // paused on purpose — stays paused
    if (!vc.value.isPlaying) vc.play();
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    // Pause when swiped off-screen; auto-resume ONLY on the transition back to
    // active — a plain rebuild (e.g. tapping to hide/show the chrome) must
    // leave a user-paused video exactly where it is, showing its frame.
    if (!widget.active) {
      if (old.active) _userPaused = false; // fresh start when swiped back to
      if (_vc?.value.isPlaying ?? false) _vc?.pause();
    } else if (!old.active) {
      _tryPlay();
    }
  }

  @override
  void dispose() {
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _tc.dispose();
    _vc?.dispose();
    super.dispose();
  }

  void _toggle() {
    final vc = _vc;
    if (vc == null) return;
    if (vc.value.isPlaying) {
      _userPaused = true; // deliberate — survives chrome toggles
      vc.pause();
    } else {
      _userPaused = false;
      vc.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = _vc;
    if (vc == null) {
      // Poster the grid thumbnail while the player spins up — no spinner flash.
      final ph = widget.placeholder;
      return Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          if (ph != null) Image.memory(ph, fit: BoxFit.contain),
          _spinner(),
        ],
      );
    }
    // Tap → hide/show the chrome, exactly like photos (play/pause lives on
    // the glass button beside the scrubber instead).
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          InteractiveViewer(
            transformationController: _tc,
            minScale: 1.0,
            maxScale: 5.0,
            panEnabled: _zoomed,
            onInteractionEnd: (_) {
              final z = _tc.value.getMaxScaleOnAxis() > 1.02;
              if (z != _zoomed) {
                setState(() => _zoomed = z);
                widget.onZoomed?.call(z);
              }
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: vc.value.aspectRatio,
                child: VideoPlayer(vc),
              ),
            ),
          ),
          // Play/pause + scrubber — just above the share/bin buttons; fades
          // away with the rest of the chrome on tap.
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).padding.bottom + 66,
            child: IgnorePointer(
              ignoring: !widget.chromeVisible,
              child: AnimatedOpacity(
                opacity: widget.chromeVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: Row(
                  children: [
                    _PlayPauseButton(controller: vc, onToggle: _toggle),
                    const SizedBox(width: 12),
                    Expanded(child: _Scrubber(controller: vc)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small smoked-glass play/pause chip beside the scrubber — since tapping the
/// film itself now toggles the chrome (like photos), this is where playback
/// control lives. Gold glyph, morphing between play and pause.
class _PlayPauseButton extends StatelessWidget {
  final VideoPlayerController controller;
  final VoidCallback onToggle;
  const _PlayPauseButton({required this.controller, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticTap();
        onToggle();
      },
      child: Container(
        width: 34,
        height: 34,
        decoration: glassChipDecoration(circle: true),
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (_, v, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(v.isPlaying),
              color: kGoldLit,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

/// A minimal video scrubber — a single line of light (see [_GoldLinePainter]):
/// molten-gold played thread with a breathing glow and drifting glint, paper
/// hairline remainder, a glowing point of light at the playhead, and tabular
/// time labels either side. Tap or drag to seek.
class _Scrubber extends StatefulWidget {
  final VideoPlayerController controller;
  const _Scrubber({required this.controller});

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> with TickerProviderStateMixin {
  late final Ticker _ticker;
  // Press/drag "swell": the tube thickens + brightens while actively scrubbing.
  late final AnimationController _press;
  // Pulsing glow while the bar is selected (scrubbing).
  late final AnimationController _glow;
  bool _engaged = false;
  int _lastTick = -1; // detented haptic ticks while dragging
  // The controller only reports `position` a few times a second, so the bar is
  // driven instead by an estimate ticked every frame: the last reported position
  // plus the wall-clock elapsed (× speed) since that report. _watch measures that
  // elapsed; each controller update resyncs both. Result: a true 60fps playhead.
  final Stopwatch _watch = Stopwatch();
  Duration _lastPos = Duration.zero;
  int _durMs = 0;
  double _speed = 1.0;
  bool _playing = false;
  bool _dragging = false; // the finger owns the bar while scrubbing
  final ValueNotifier<double> _frac = ValueNotifier(0);
  // Bumped every vsync while playing so the shimmer band drifts smoothly even
  // when the playhead fraction itself barely moves (long videos).
  final ValueNotifier<int> _tickN = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _onValue();
    widget.controller.addListener(_onValue);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    _ticker.dispose();
    _press.dispose();
    _glow.dispose();
    _frac.dispose();
    _tickN.dispose();
    super.dispose();
  }

  // Resync to a fresh controller report; start/stop the per-frame ticker so it
  // only runs while playing.
  void _onValue() {
    final v = widget.controller.value;
    _durMs = v.duration.inMilliseconds;
    _speed = v.playbackSpeed <= 0 ? 1.0 : v.playbackSpeed;
    _lastPos = v.position;
    _watch
      ..reset()
      ..start();
    _playing = v.isPlaying;
    if (_playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!_playing && _ticker.isActive) {
      _ticker.stop();
    }
    if (!_playing && !_dragging) _emit(_lastPos.inMilliseconds.toDouble());
  }

  void _onTick(Duration _) {
    _tickN.value++; // repaint every vsync while playing → the shimmer drifts
    if (_dragging) return;
    double ms = _lastPos.inMilliseconds.toDouble();
    if (_playing) ms += _watch.elapsedMilliseconds * _speed;
    _emit(ms);
  }

  void _emit(double ms) {
    final frac = _durMs > 0 ? (ms / _durMs).clamp(0.0, 1.0) : 0.0;
    if ((_frac.value - frac).abs() > 0.0005) _frac.value = frac;
  }

  void _seek(double frac, {bool tick = false}) {
    frac = frac.clamp(0.0, 1.0);
    _frac.value = frac;
    if (tick) {
      // Detented haptic ticks as the fluid passes ~28 notches across the bar.
      final t = (frac * 28).round();
      if (t != _lastTick) {
        _lastTick = t;
        HapticFeedback.selectionClick();
      }
    }
    widget.controller.seekTo(Duration(milliseconds: (frac * _durMs).round()));
  }

  // Begin scrubbing: pause the interpolation, swell the tube, give a press tick.
  void _engage() {
    _dragging = true;
    _lastTick = (_frac.value * 28).round();
    if (!_engaged) {
      _engaged = true;
      HapticFeedback.mediumImpact();
    }
    _press.forward();
    if (!_glow.isAnimating) _glow.repeat(reverse: true); // breathe while held
  }

  void _release() {
    _dragging = false;
    if (_engaged) {
      _engaged = false;
      HapticFeedback.lightImpact();
    }
    _press.reverse();
    _glow.stop(); // the fading swell carries the glow out
  }

  @override
  Widget build(BuildContext context) {
    // Elapsed glints in champagne; the total rests in dim paper — both tabular
    // so nothing shifts as the digits tick over, softly shadowed so they stay
    // legible over bright footage (no chrome behind them, just the film).
    const List<Shadow> legible = [Shadow(color: Colors.black54, blurRadius: 5)];
    const TextStyle elapsedStyle = TextStyle(
      color: kGoldLit,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      fontFeatures: [FontFeature.tabularFigures()],
      shadows: legible,
    );
    final TextStyle totalStyle = TextStyle(
      color: kPaper.withValues(alpha: 0.6),
      fontSize: 11,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.6,
      fontFeatures: const [FontFeature.tabularFigures()],
      shadows: legible,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([_frac, _press, _glow, _tickN]),
      builder: (context, _) {
        final frac = _frac.value;
        final active = Curves.easeOut.transform(_press.value);
        // Pulsing glow while selected: breathes between ~0.55 and 1, faded
        // by the swell so it eases out on release.
        final glow = active * (0.55 + 0.45 * _glow.value);
        // Wall-clock phase — drives the drifting glint AND the resting
        // breath of the glow, one 2.8s cycle (the paywall CTA's cadence).
        // Repaints ride the playback ticker, so all the light pauses
        // gracefully with the film.
        final double shimmer =
            (DateTime.now().millisecondsSinceEpoch % 2800) / 2800.0;
        final posMs = (frac * _durMs).round();
        return Row(
          children: [
            Text(
              _fmtDuration(Duration(milliseconds: posMs)),
              style: elapsedStyle,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) {
                      _engage();
                      _seek(d.localPosition.dx / w);
                    },
                    onTapUp: (_) => _release(),
                    onHorizontalDragStart: (d) {
                      _engage();
                      _seek(d.localPosition.dx / w);
                    },
                    onHorizontalDragUpdate: (d) =>
                        _seek(d.localPosition.dx / w, tick: true),
                    onHorizontalDragEnd: (_) => _release(),
                    onHorizontalDragCancel: _release,
                    child: SizedBox(
                      height: 30,
                      child: CustomPaint(
                        size: Size(w, 30),
                        painter: _GoldLinePainter(frac, active, glow, shimmer),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _fmtDuration(Duration(milliseconds: _durMs)),
              style: totalStyle,
            ),
          ],
        );
      },
    );
  }
}

/// A single line of light. The played side is a fine molten-gold thread —
/// champagne at its origin deepening to gold at the playhead — resting on a
/// breathing bloom that inhales and exhales even at rest. A champagne glint
/// ([shimmer]) drifts along the thread while the film plays, and the playhead
/// itself is a small point of living light: a near-white core in a fine gold
/// ring, haloed. While you scrub ([active] → 1) the line thickens and
/// everything brightens. Minimal — one line, all glow.
class _GoldLinePainter extends CustomPainter {
  final double frac;
  final double active; // 0 resting → 1 actively scrubbing
  final double glow; // 0..1 pulsing halo while the bar is held
  final double shimmer; // 0..1 shared clock: drifting glint + resting breath
  const _GoldLinePainter(this.frac, this.active, this.glow, this.shimmer);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double cy = size.height / 2;
    final double a = active.clamp(0.0, 1.0);
    const double inset = 4.0; // room for the round caps + playhead bloom
    final double usable = w - inset * 2;
    if (usable <= 0) return;
    final double fx = inset + usable * frac.clamp(0.0, 1.0);
    final double th = 2.0 + 1.6 * a; // the line swells under the finger

    // The resting breath — the glow gently inhales/exhales on the same clock
    // as the drifting glint, so the line always feels alive, never static.
    final double breath = 0.5 + 0.5 * math.sin(shimmer * 2 * math.pi);

    // 0) Soft dark under-shadow, so the light reads over bright footage.
    canvas.drawLine(
      Offset(inset, cy),
      Offset(w - inset, cy),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..strokeWidth = th + 3
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // 1) The rail — the unplayed remainder, a bare paper hairline.
    canvas.drawLine(
      Offset(fx, cy),
      Offset(w - inset, cy),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round,
    );

    if (fx > inset + 0.5) {
      // 2) Breathing golden bloom beneath the played thread — swelling
      //    further with the held pulse ([glow]).
      canvas.drawLine(
        Offset(inset, cy),
        Offset(fx, cy),
        Paint()
          ..color = kGold.withValues(alpha: 0.28 + 0.14 * breath + 0.35 * glow)
          ..strokeWidth = th + 2.5
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 + 4 * glow),
      );

      // 3) The molten thread itself — champagne at the origin deepening to
      //    gold at the playhead.
      final Rect lineRect = Rect.fromLTRB(inset, cy - th, fx, cy + th);
      canvas.drawLine(
        Offset(inset, cy),
        Offset(fx, cy),
        Paint()
          ..shader = const LinearGradient(
            colors: [kGoldLit, kGold],
          ).createShader(lineRect)
          ..strokeWidth = th
          ..strokeCap = StrokeCap.round,
      );

      // 4) Drifting champagne glint gliding along the thread.
      final double played = fx - inset;
      if (played > 24) {
        final double bandW = math.min(70.0, played * 0.5);
        final double bx = inset - bandW + (played + 2 * bandW) * shimmer;
        final Rect band = Rect.fromLTWH(bx, cy - th, bandW, th * 2);
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(inset, cy - th * 2, fx, cy + th * 2));
        canvas.drawLine(
          Offset(bx, cy),
          Offset(bx + bandW, cy),
          Paint()
            ..shader = LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0),
                Colors.white.withValues(alpha: 0.55),
                Colors.white.withValues(alpha: 0),
              ],
            ).createShader(band)
            ..strokeWidth = th
            ..strokeCap = StrokeCap.round,
        );
        canvas.restore();
      }
    }

    // 5) The playhead — a point of living light: breathing champagne halo
    //    around a near-white core in a fine gold ring.
    final double orbR = 2.4 + 1.4 * a;
    canvas.drawCircle(
      Offset(fx, cy),
      orbR + 4.0 + 1.8 * breath + 3.5 * a,
      Paint()
        ..color = kGoldLit.withValues(alpha: 0.20 + 0.12 * breath + 0.35 * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      Offset(fx, cy),
      orbR,
      Paint()..color = const Color(0xFFFFF9E8),
    );
    canvas.drawCircle(
      Offset(fx, cy),
      orbR + 0.7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = kGold.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_GoldLinePainter old) =>
      old.frac != frac ||
      old.active != active ||
      old.glow != glow ||
      old.shimmer != shimmer;
}

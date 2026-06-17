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
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.16),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.10),
            width: 0.5,
          ),
        ),
      ),
      child: child,
    );
  }
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
                // Tap ripple — a ring that expands past the button and fades.
                if (t > 0 && t < 1)
                  Transform.scale(
                    scale: 0.85 + 0.7 * ripple,
                    child: Container(
                      width: _d,
                      height: _d,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.7 * (1 - t)),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                // Shared liquid-glass disc (blur + sheen + rim + shadow).
                GlassSurface(
                  borderRadius: BorderRadius.circular(_d / 2),
                  child: SizedBox(
                    width: _d,
                    height: _d,
                    child: Center(
                      child: Transform.scale(
                        scale: pop,
                        child: Icon(
                          widget.icon,
                          color: Colors.white,
                          size: widget.iconSize,
                          shadows: const [
                            Shadow(color: Colors.black38, blurRadius: 4),
                          ],
                        ),
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

Widget _spinner() => const Center(
  child: SizedBox(
    width: 26,
    height: 26,
    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
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
String _dateLabel(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(DateTime(dt.year, dt.month, dt.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final y = dt.year != now.year ? ' ${dt.year}' : '';
  return '${dt.day} ${_months[dt.month - 1]}$y';
}

/// "1:03 PM".
String _timeLabel(DateTime dt) {
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
    // Accent the most recent days in gold to tie in the app's accent.
    final recent = label == 'Today' || label == 'Yesterday';
    return Container(
      height: 42,
      color: Colors.black,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 14, top: 12, bottom: 6),
      child: Text(
        label,
        style: TextStyle(
          color: recent ? _gold : Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Calm empty state when the library has no photos/videos yet.
class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.photo_library_outlined,
            color: Colors.white.withValues(alpha: 0.28),
            size: 54,
          ),
          const SizedBox(height: 14),
          Text(
            'No photos yet',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Photos you capture will appear here',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 13,
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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.black.withValues(alpha: 0.82),
            Colors.black.withValues(alpha: 0.62),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.55), width: 0.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
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
                      setState(() => _active = true);
                      widget.onGrab();
                    },
                    onPointerMove: (e) {
                      _dragFrac = (_dragFrac + e.delta.dy / _usable).clamp(
                        0.0,
                        1.0,
                      );
                      widget.onScrub(_dragFrac);
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
  // Fast-scroll thumb: a tiny grabbable pill on the right edge. The controller
  // lets us jump the grid as you drag; the notifier feeds the thumb's position
  // (0..1) without rebuilding the grid.
  final ScrollController _scrollCtrl = ScrollController();
  final ValueNotifier<double> _scrollFrac = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pull.dispose();
    _scrollCtrl.dispose();
    _scrollFrac.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Just the first page → grid appears right away.
    final first = await widget.album.getAssetListPaged(
      page: 0,
      size: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      _items = first;
      _loadedPages = 1;
      _hasMore = first.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final next = await widget.album.getAssetListPaged(
      page: _loadedPages,
      size: _pageSize,
    );
    if (!mounted) {
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
        out.add(_Section(_dateLabel(dt), []));
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
            const _EmptyGallery()
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
                  return _dateLabel(_items[i].createDateTime);
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
                '${_selectedIds.length} selected',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.ios_share_rounded, color: Colors.white),
              onPressed: _selectedIds.isEmpty ? null : _shareSelected,
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.white,
              ),
              onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: topInset, bottom: 10, left: 16, right: 16),
      child: const Center(
        child: Text(
          'Photos',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
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
            child: ClipRRect(
              borderRadius: radius,
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
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
                  color: Colors.black.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(kRadiusSm),
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
          // Selection check (multi-select mode): gold filled when selected,
          // hollow white otherwise.
          if (widget.selecting)
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.selected
                      ? _gold
                      : Colors.black.withValues(alpha: 0.3),
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: widget.selected
                      ? [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 6,
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

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  // Fades a chrome element with the tap-to-hide toggle and blocks its taps once
  // hidden. (The inner Opacity still handles the swipe-down/delete fades.)
  Widget _chrome(Widget child) => IgnorePointer(
    ignoring: !_chromeVisible,
    child: AnimatedOpacity(
      opacity: _chromeVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: child,
    ),
  );

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
  void dispose() {
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

  void _onDragStart(DragStartDetails _) {
    if (_springCtrl.isAnimating) _springCtrl.stop();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // Track the finger 1:1 via the notifier — no setState, so the page/video
    // isn't rebuilt mid-drag.
    final v = _drag.value + d.delta.dy;
    _drag.value = v < 0 ? 0 : v; // downward only
  }

  void _onDragEnd(DragEndDetails d) {
    if (_drag.value > 110 || (d.primaryVelocity ?? 0) > 700) {
      Navigator.of(context).pop();
    } else {
      _springFrom = _drag.value;
      _springCtrl.forward(from: 0); // ease smoothly back to rest
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
      body: GestureDetector(
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        // Repaints on drag/delete only; the PageView is the cached `child`, so
        // swiping to dismiss never rebuilds the photo/video underneath.
        child: AnimatedBuilder(
          animation: Listenable.merge([_drag, _deleteCtrl]),
          child: PageView.builder(
            controller: _controller,
            itemCount: total,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _GalleryPage(
              asset: widget.assets[i],
              active: i == _index,
              placeholder: widget.thumbs[widget.assets[i].id],
              onTap: _toggleChrome,
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
                        child: GlassSurface(
                          borderRadius: BorderRadius.circular(kRadiusLg),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _dateLabel(
                                  widget.assets[_index].createDateTime,
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              Text(
                                _timeLabel(
                                  widget.assets[_index].createDateTime,
                                ),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: 0.4,
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
  final VoidCallback? onTap; // tap a photo to hide/show the chrome
  const _GalleryPage({
    required this.asset,
    required this.active,
    this.placeholder,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return asset.type == AssetType.video
        ? _VideoPage(asset: asset, active: active, placeholder: placeholder)
        : _PhotoPage(asset: asset, placeholder: placeholder, onTap: onTap);
  }
}

/// A pinch- and double-tap-zoom photo. Loads a high-res JPEG thumbnail once.
class _PhotoPage extends StatefulWidget {
  final AssetEntity asset;
  final Uint8List? placeholder;
  final VoidCallback? onTap;
  const _PhotoPage({required this.asset, this.placeholder, this.onTap});

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
    // Show the grid's already-decoded thumbnail instantly (no spinner, no work
    // during the open transition), then sharpen to full-res in the background.
    _bytes = widget.placeholder;
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
    _zoomCtrl.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _onInteractionEnd() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) setState(() => _zoomed = z);
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
      final z = target.getMaxScaleOnAxis() > 1.02;
      if (mounted && z != _zoomed) setState(() => _zoomed = z);
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
  const _VideoPage({
    required this.asset,
    required this.active,
    this.placeholder,
  });

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _vc;
  // Autoplay only once the open transition has settled — kicking the decoder off
  // mid-animation janks the zoom-in. _enterDone flips true when the route's
  // enter animation completes (or is already past it on a later swipe).
  bool _enterDone = false;
  Animation<double>? _routeAnim;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_enterDone || _routeAnim != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      _enterDone = true;
    } else {
      _routeAnim = anim..addStatusListener(_onRouteStatus);
    }
  }

  void _onRouteStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _routeAnim = null;
    _enterDone = true;
    _tryPlay();
  }

  Future<void> _init() async {
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

  // Play when this page is the active one and the open transition has finished.
  void _tryPlay() {
    final vc = _vc;
    if (vc == null || !mounted || !widget.active || !_enterDone) return;
    if (!vc.value.isPlaying) vc.play();
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    // Pause when swiped off-screen; resume/start when it becomes active again.
    if (!widget.active) {
      if (_vc?.value.isPlaying ?? false) _vc?.pause();
    } else {
      _tryPlay();
    }
  }

  @override
  void dispose() {
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _vc?.dispose();
    super.dispose();
  }

  void _toggle() {
    final vc = _vc;
    if (vc == null) return;
    vc.value.isPlaying ? vc.pause() : vc.play();
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
    return GestureDetector(
      onTap: _toggle,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: vc.value.aspectRatio,
              child: VideoPlayer(vc),
            ),
          ),
          // Minimalist scrubber — sits just above the share/bin buttons.
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).padding.bottom + 66,
            child: _Scrubber(controller: vc),
          ),
        ],
      ),
    );
  }
}

/// A slim, minimalist video scrubber: gold played track, faint rail, a small
/// round knob, with monospaced time labels either side. Tap or drag to seek.
class _Scrubber extends StatefulWidget {
  final VideoPlayerController controller;
  const _Scrubber({required this.controller});

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
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

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _onValue();
    widget.controller.addListener(_onValue);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    _ticker.dispose();
    _frac.dispose();
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
    if (_dragging) return;
    double ms = _lastPos.inMilliseconds.toDouble();
    if (_playing) ms += _watch.elapsedMilliseconds * _speed;
    _emit(ms);
  }

  void _emit(double ms) {
    final frac = _durMs > 0 ? (ms / _durMs).clamp(0.0, 1.0) : 0.0;
    if ((_frac.value - frac).abs() > 0.0005) _frac.value = frac;
  }

  void _seek(double frac) {
    frac = frac.clamp(0.0, 1.0);
    _frac.value = frac;
    widget.controller.seekTo(Duration(milliseconds: (frac * _durMs).round()));
  }

  @override
  Widget build(BuildContext context) {
    const timeStyle = TextStyle(
      color: Colors.white,
      fontSize: 11,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.3,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return ValueListenableBuilder<double>(
      valueListenable: _frac,
      builder: (context, frac, _) {
        final posMs = (frac * _durMs).round();
        return Row(
          children: [
            Text(_fmtDuration(Duration(milliseconds: posMs)), style: timeStyle),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _seek(d.localPosition.dx / w),
                    onHorizontalDragStart: (_) => _dragging = true,
                    onHorizontalDragUpdate: (d) =>
                        _seek(d.localPosition.dx / w),
                    onHorizontalDragEnd: (_) => _dragging = false,
                    onHorizontalDragCancel: () => _dragging = false,
                    child: SizedBox(
                      height: 24,
                      child: CustomPaint(
                        size: Size(w, 24),
                        painter: _GlassTubePainter(frac),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _fmtDuration(Duration(milliseconds: _durMs)),
              style: timeStyle.copyWith(
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A 3D glass-tube progress bar: a translucent capsule "tube" with cylinder
/// shading (bright top edge, dark body, faint bottom reflection) that fills with
/// glowing molten-gold liquid, topped by a lit glass bead playhead.
class _GlassTubePainter extends CustomPainter {
  final double frac;
  const _GlassTubePainter(this.frac);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    const th = 9.0; // tube thickness
    const r = th / 2;
    if (w <= th) return; // too narrow to draw a sane tube
    final cy = size.height / 2;
    final tubeRect = Rect.fromLTWH(0, cy - r, w, th);
    final tube = RRect.fromRectAndRadius(tubeRect, const Radius.circular(r));

    // 1) Empty tube — cylinder shading: specular top, dark glass body, faint
    //    bottom reflection.
    canvas.drawRRect(
      tube,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x40FFFFFF), Color(0x73000000), Color(0x1AFFFFFF)],
          stops: [0.0, 0.55, 1.0],
        ).createShader(tubeRect),
    );

    // 2) Molten-gold liquid, clipped to the tube and the filled fraction.
    final fw = (w * frac).clamp(0.0, w);
    if (fw > 0.5) {
      canvas.save();
      canvas.clipRRect(tube);
      final fillRect = Rect.fromLTWH(0, cy - r, fw, th);
      final fillRRect = RRect.fromRectAndRadius(
        fillRect,
        const Radius.circular(r),
      );
      // Soft glow beneath the liquid.
      canvas.drawRRect(
        fillRRect,
        Paint()
          ..color = kGold.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      // Liquid body — pale-gold sheen → gold → deep amber.
      canvas.drawRRect(
        fillRRect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFF1C9), kGold, Color(0xFFB07E22)],
            stops: [0.0, 0.5, 1.0],
          ).createShader(fillRect),
      );
      // Specular streak along the top of the liquid.
      final specW = fw - th;
      if (specW > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(r * 0.6, cy - r + 1.4, specW, th * 0.24),
            const Radius.circular(2),
          ),
          Paint()..color = Colors.white.withValues(alpha: 0.55),
        );
      }
      canvas.restore();
    }

    // 3) Glass rim around the tube.
    canvas.drawRRect(
      RRect.fromRectAndRadius(tubeRect.deflate(0.4), const Radius.circular(r)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Colors.white.withValues(alpha: 0.22),
    );

    // 4) Playhead — a lit glass bead with a gold halo.
    final px = fw.clamp(r, w - r);
    final center = Offset(px, cy);
    canvas.drawCircle(
      center,
      9,
      Paint()
        ..color = kGold.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      center,
      7.5,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1.1,
          colors: [Colors.white, Color(0xFFFDEFC2), kGold],
          stops: [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: 7.5)),
    );
    canvas.drawCircle(
      center,
      7.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(_GlassTubePainter old) => old.frac != frac;
}

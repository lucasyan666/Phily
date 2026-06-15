import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:phily/screens/branded_loader.dart';

const _gold = Color(0xFFE5C158);

// ─────────────────────────────────────────────────────────────────────────────
// Shared glassy chrome (matches the camera page)
// ─────────────────────────────────────────────────────────────────────────────

/// A frosted top bar — backdrop blur + dark tint + a hairline bottom edge.
class _FrostBar extends StatelessWidget {
  final Widget child;
  const _FrostBar({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.30),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.10),
                width: 0.5,
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Pretty floating glass delete button: a frosted circle with a sheen, hairline
/// ring, soft shadow, and a clean trash glyph.
/// Frosted glass circle button (bin + share actions in the pager). Springs down
/// on press and pops back on release for tactile feedback.
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

class _GlassCircleButtonState extends State<_GlassCircleButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.84 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: _pressed ? 0.30 : 0.22),
                      Colors.white.withValues(alpha: 0.06),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 0.8,
                  ),
                ),
                child: Icon(
                  widget.icon,
                  color: Colors.white,
                  size: widget.iconSize,
                ),
              ),
            ),
          ),
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
  // placeholder so opening a photo/video doesn't flash a spinner.
  final Map<String, Uint8List> _thumbCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pull.dispose();
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
    // Prefetch the next page well before the user hits the bottom.
    if (_hasMore &&
        !_loadingMore &&
        n.metrics.pixels >= n.metrics.maxScrollExtent - 1500) {
      _loadMore();
    }
    return false;
  }

  Future<void> _openAt(int i) async {
    // Pass the cached list; the viewer returns the id of anything it deleted.
    final deletedId = await Navigator.of(context).push<String>(
      PageRouteBuilder(
        // Transparent so the grid shows through the pager's dismiss fade.
        opaque: false,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => GalleryViewerPage(
          assets: _items,
          initialIndex: i,
          thumbs: _thumbCache,
        ),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
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
    final topPad = MediaQuery.of(context).padding.top + 52;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_loading)
            const BrandedLoader()
          else
            NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: GridView.builder(
                // Bounce so a pull past the top dims + dismisses to the camera.
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: EdgeInsets.only(
                  top: topPad + 2,
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                  left: 2,
                  right: 2,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: _items.length,
                itemBuilder: (_, i) {
                  final asset = _items[i];
                  return GestureDetector(
                    key: ValueKey(asset.id), // stable identity → no reload
                    onTap: () => _openAt(i),
                    child: _GridThumb(
                      asset: asset,
                      onLoaded: (b) => _thumbCache[asset.id] = b,
                    ),
                  );
                },
              ),
            ),

          // Cheap dim that follows the pull (and springs back with the bounce) —
          // only this repaints as you pull, never the grid.
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

          // Frosted top bar — title only; pull down to exit (no close button).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _FrostBar(
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 4,
                  bottom: 10,
                  left: 16,
                  right: 16,
                ),
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
              ),
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
  const _GridThumb({required this.asset, this.onLoaded});

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
    if (bytes == null) {
      return Container(color: Colors.white.withValues(alpha: 0.06));
    }
    final isVideo = widget.asset.type == AssetType.video;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        if (isVideo)
          Positioned(
            right: 5,
            bottom: 4,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 15,
                ),
                const SizedBox(width: 1),
                Text(
                  _fmtDuration(widget.asset.videoDuration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                  ),
                ),
              ],
            ),
          ),
      ],
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
    with SingleTickerProviderStateMixin {
  late final PageController _controller;
  late int _index;
  // Anchor for the iOS share sheet popover (the Share button's rect).
  final GlobalKey _shareBtnKey = GlobalKey();
  // Swipe-down-to-dismiss: downward drag distance, and whether a drag is live.
  double _dragDy = 0;
  bool _dragging = false;
  // "Sucked into the bin" delete animation.
  late final AnimationController _deleteCtrl;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
    _deleteCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _deleteCtrl.dispose();
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

  void _onDragUpdate(DragUpdateDetails d) {
    final v = _dragDy + d.delta.dy;
    setState(() => _dragDy = v < 0 ? 0 : v); // downward only
  }

  void _onDragEnd(DragEndDetails d) {
    if (_dragDy > 110 || (d.primaryVelocity ?? 0) > 700) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _dragging = false;
        _dragDy = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final screenW = size.width;
    final screenH = size.height;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final progress = (_dragDy / 240).clamp(0.0, 1.0);
    final chromeOpacity = (1 - progress * 2.2).clamp(0.0, 1.0);
    // The photo/video itself fades as it's dragged down — not just slides.
    final imgOpacity = (1 - progress * 1.3).clamp(0.0, 1.0);
    final slideDur = _dragging
        ? Duration.zero
        : const Duration(milliseconds: 250);
    // Bin sits bottom-right; the delete animation flies the photo into it.
    final binDx = (screenW - 40) - screenW / 2;
    final binDy = (screenH - safeBottom - 40) - screenH / 2;
    final total = widget.assets.length;

    return Scaffold(
      backgroundColor: Colors.transparent, // grid shows through while dragging
      body: GestureDetector(
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        child: Stack(
          children: [
            // Backdrop dims back in as you release, fades out as you drag down.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: slideDur,
                  color: Colors.black.withValues(
                    alpha: (1 - progress).clamp(0.0, 1.0),
                  ),
                ),
              ),
            ),
            AnimatedSlide(
              offset: Offset(0, _dragDy / screenH),
              duration: slideDur,
              curve: Curves.easeOut,
              child: AnimatedScale(
                scale: 1 - progress * 0.06,
                duration: slideDur,
                curve: Curves.easeOut,
                child: AnimatedBuilder(
                  animation: _deleteCtrl,
                  builder: (context, _) {
                    final dt = Curves.easeIn.transform(_deleteCtrl.value);
                    final chrome = (chromeOpacity * (1 - _deleteCtrl.value))
                        .clamp(0.0, 1.0);
                    return Stack(
                      children: [
                        // Pages — flown into the bin while deleting; identity
                        // otherwise.
                        Transform.translate(
                          offset: Offset(binDx * dt, binDy * dt),
                          child: Transform.scale(
                            scale: 1 - 0.9 * dt,
                            child: Opacity(
                              opacity: 1 - dt,
                              child: AnimatedOpacity(
                                opacity: imgOpacity,
                                duration: slideDur,
                                child: PageView.builder(
                                  controller: _controller,
                                  itemCount: total,
                                  onPageChanged: (i) =>
                                      setState(() => _index = i),
                                  itemBuilder: (_, i) => _GalleryPage(
                                    asset: widget.assets[i],
                                    active: i == _index,
                                    placeholder:
                                        widget.thumbs[widget.assets[i].id],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Frosted top bar: close + counter.
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: Opacity(
                            opacity: chrome,
                            child: _FrostBar(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  top: MediaQuery.of(context).padding.top + 4,
                                  bottom: 8,
                                  left: 6,
                                  right: 6,
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: Colors.white,
                                      ),
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                    ),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _dateLabel(
                                              widget
                                                  .assets[_index]
                                                  .createDateTime,
                                            ),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w500,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            _timeLabel(
                                              widget
                                                  .assets[_index]
                                                  .createDateTime,
                                            ),
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.6,
                                              ),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w400,
                                              letterSpacing: 0.4,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 48),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Floating glassy share (bottom-left) + bin (bottom-right).
                        Positioned(
                          left: 16,
                          bottom: safeBottom + 16,
                          child: Opacity(
                            opacity: chrome,
                            child: _GlassCircleButton(
                              key: _shareBtnKey,
                              icon: Icons.ios_share_rounded,
                              iconSize: 22,
                              onTap: _shareCurrent,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 16,
                          bottom: safeBottom + 16,
                          child: Opacity(
                            opacity: chrome,
                            child: _GlassCircleButton(
                              icon: Icons.delete_outline_rounded,
                              onTap: _deleteCurrent,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
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
  const _GalleryPage({
    required this.asset,
    required this.active,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return asset.type == AssetType.video
        ? _VideoPage(asset: asset, active: active, placeholder: placeholder)
        : _PhotoPage(asset: asset, placeholder: placeholder);
  }
}

/// A pinch-to-zoom photo. Loads a high-res JPEG thumbnail once.
class _PhotoPage extends StatefulWidget {
  final AssetEntity asset;
  final Uint8List? placeholder;
  const _PhotoPage({required this.asset, this.placeholder});

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  Uint8List? _bytes;
  final TransformationController _tc = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    // Show the grid's already-decoded thumbnail instantly (no spinner, no work
    // during the open transition), then sharpen to full-res in the background.
    _bytes = widget.placeholder;
    widget.asset
        .thumbnailDataWithSize(const ThumbnailSize(1440, 1440), quality: 90)
        .then((b) {
          if (mounted && b != null) {
            setState(() => _bytes = b);
          }
        });
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _onInteractionEnd() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return _spinner();
    // Pan only while zoomed → at 1× the PageView keeps horizontal swipes and the
    // pager keeps vertical drags free for swipe-to-dismiss.
    return InteractiveViewer(
      transformationController: _tc,
      minScale: 1.0,
      maxScale: 4.0,
      panEnabled: _zoomed,
      onInteractionEnd: (_) => _onInteractionEnd(),
      child: Center(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
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

  @override
  void initState() {
    super.initState();
    _init();
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
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    if (!widget.active && (_vc?.value.isPlaying ?? false)) _vc?.pause();
  }

  @override
  void dispose() {
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
          // Minimalist frosted play button (fades out while playing).
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: vc,
            builder: (_, value, _) => IgnorePointer(
              child: AnimatedOpacity(
                opacity: value.isPlaying ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.5),
                          width: 1,
                        ),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Minimalist scrubber.
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).padding.bottom + 78,
            child: _Scrubber(controller: vc),
          ),
        ],
      ),
    );
  }
}

/// A slim, minimalist video scrubber: gold played track, faint rail, a small
/// round knob, with monospaced time labels either side. Tap or drag to seek.
class _Scrubber extends StatelessWidget {
  final VideoPlayerController controller;
  const _Scrubber({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final durMs = v.duration.inMilliseconds;
        final posMs = v.position.inMilliseconds.clamp(
          0,
          durMs == 0 ? 1 : durMs,
        );
        final frac = durMs > 0 ? posMs / durMs : 0.0;
        const timeStyle = TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.3,
          fontFeatures: [FontFeature.tabularFigures()],
        );
        return Row(
          children: [
            Text(_fmtDuration(v.position), style: timeStyle),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  void seek(double dx) {
                    final f = (dx / w).clamp(0.0, 1.0);
                    controller.seekTo(
                      Duration(milliseconds: (f * durMs).round()),
                    );
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => seek(d.localPosition.dx),
                    onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
                    child: SizedBox(
                      height: 22,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(
                            height: 2.5,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: frac,
                            child: Container(
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: _gold,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment(frac * 2 - 1, 0),
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _fmtDuration(v.duration),
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

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
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
class _GlassBin extends StatelessWidget {
  final VoidCallback onTap;
  const _GlassBin({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
                    Colors.white.withValues(alpha: 0.22),
                    Colors.white.withValues(alpha: 0.06),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.35),
                  width: 0.8,
                ),
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.white,
                size: 23,
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
  List<AssetEntity> _items = [];
  bool _loading = true;
  double _pull = 0; // accumulated top overscroll for pull-down-to-dismiss

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await widget.album.getAssetListRange(
      start: 0,
      end: widget.count,
    );
    if (mounted) {
      setState(() {
        _items = list;
        _loading = false;
      });
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        n.metrics.pixels <= 0) {
      _pull -= n.overscroll; // overscroll is negative at the top
      if (_pull > 90) {
        _pull = 0;
        Navigator.of(context).maybePop(); // back to the camera
      }
    } else if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      _pull = 0;
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
        pageBuilder: (_, _, _) =>
            GalleryViewerPage(assets: _items, initialIndex: i),
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
                // Bounce at the edges so a pull past the top dismisses to camera.
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
                    key: ValueKey(asset.id), // stable identity → no reload on shift
                    onTap: () => _openAt(i),
                    child: _GridThumb(asset: asset),
                  );
                },
              ),
            ),

          // Frosted top bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _FrostBar(
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 4,
                  bottom: 8,
                  left: 4,
                  right: 16,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Text(
                      'Photos',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
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

/// One square grid cell — small thumbnail + a video badge. Caches its thumbnail
/// in state; keyed by asset id so it survives list re-orders without reloading.
class _GridThumb extends StatefulWidget {
  final AssetEntity asset;
  const _GridThumb({required this.asset});

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

  const GalleryViewerPage({
    super.key,
    required this.assets,
    this.initialIndex = 0,
  });

  @override
  State<GalleryViewerPage> createState() => _GalleryViewerPageState();
}

class _GalleryViewerPageState extends State<GalleryViewerPage>
    with SingleTickerProviderStateMixin {
  late final PageController _controller;
  late int _index;
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
                              child: PageView.builder(
                                controller: _controller,
                                itemCount: total,
                                onPageChanged: (i) =>
                                    setState(() => _index = i),
                                itemBuilder: (_, i) => _GalleryPage(
                                  asset: widget.assets[i],
                                  active: i == _index,
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
                                      child: Text(
                                        '${_index + 1} / $total',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w300,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 48),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Floating glassy bin (bottom-right).
                        Positioned(
                          right: 16,
                          bottom: safeBottom + 16,
                          child: Opacity(
                            opacity: chrome,
                            child: _GlassBin(onTap: _deleteCurrent),
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
  const _GalleryPage({required this.asset, required this.active});

  @override
  Widget build(BuildContext context) {
    return asset.type == AssetType.video
        ? _VideoPage(asset: asset, active: active)
        : _PhotoPage(asset: asset);
  }
}

/// A pinch-to-zoom photo. Loads a high-res JPEG thumbnail once.
class _PhotoPage extends StatefulWidget {
  final AssetEntity asset;
  const _PhotoPage({required this.asset});

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
    widget.asset
        .thumbnailDataWithSize(const ThumbnailSize(1440, 1440), quality: 90)
        .then((b) {
          if (mounted) setState(() => _bytes = b);
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
  const _VideoPage({required this.asset, required this.active});

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
    if (vc == null) return _spinner();
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
        final posMs = v.position.inMilliseconds.clamp(0, durMs == 0 ? 1 : durMs);
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

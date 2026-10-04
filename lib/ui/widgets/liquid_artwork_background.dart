import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// 歌词页背景：封面主色 + 预模糊封面。
///
/// [animate] 为 true 时，同一张预模糊封面放大成三份缓慢旋转，得到 Apple Music 那种
/// "流动封面"液态渐变；为 false（暂停播放 / 减弱动效）时改为一整张静态模糊封面，
/// 观感对齐商业播放器（清爽、无全屏动画）。
///
/// 性能：
/// - 封面**一次性预模糊**成小图并缓存，逐帧只做旋转 / 缩放这类廉价变换，
///   不做逐帧高斯模糊（Impeller 下逐帧模糊会持续新建离屏渲染目标，代价极高）；
/// - 旋转极慢，按 [_frameInterval]（约 30fps）更新而非跟随设备刷新率；
/// - 整个背景包在 RepaintBoundary 里，前景歌词滚动不会触发它重绘。
class LiquidArtworkBackground extends StatefulWidget {
  final String imageUrl;
  final Color fallback;
  final bool animate;

  const LiquidArtworkBackground({
    super.key,
    required this.imageUrl,
    required this.fallback,
    this.animate = true,
  });

  @override
  State<LiquidArtworkBackground> createState() => _LiquidArtworkBackgroundState();
}

class _LiquidArtworkBackgroundState extends State<LiquidArtworkBackground> with SingleTickerProviderStateMixin {
  /// 旋转一整圈的时间。
  static const Duration _period = Duration(seconds: 40);

  /// 更新间隔上限（约 30fps）。旋转极慢，更高的刷新率看不出差别。
  static const Duration _frameInterval = Duration(milliseconds: 33);

  /// 预模糊图的边长。作为纯色氛围底，分辨率无需更高。
  static const int _blurredSize = 176;

  /// 图像空间的高斯半径；绘制放大后即屏幕空间的模糊半径。
  static const double _blurSigma = 22;

  /// 预模糊结果缓存：同一封面在整棵界面树内只算一次。
  static final Map<String, ui.Image> _cache = <String, ui.Image>{};

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _angle = 0;
  ui.Image? _blurred;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    if (widget.animate) _ticker.start();
    _blurred = _cache[widget.imageUrl];
    if (_blurred == null) unawaited(_prepare(widget.imageUrl));
  }

  @override
  void didUpdateWidget(LiquidArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _blurred = _cache[widget.imageUrl];
      if (_blurred == null) unawaited(_prepare(widget.imageUrl));
    }
    if (widget.animate == oldWidget.animate) return;
    if (widget.animate) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  Future<void> _prepare(String url) async {
    if (url.isEmpty) return;
    try {
      final provider = CachedNetworkImageProvider(url, maxWidth: 128);
      final source = await _firstFrame(provider);
      final blurred = await _blur(source);
      source.dispose();
      if (!mounted || widget.imageUrl != url) {
        blurred.dispose();
        return;
      }
      _cache[url] = blurred;
      setState(() => _blurred = blurred);
    } catch (_) {
      // 加载 / 解码失败：保持纯色兜底，与旧实现一致。
    }
  }

  static Future<ui.Image> _firstFrame(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// 把整张封面一次性模糊成 [_blurredSize] 见方的缓存图。
  static Future<ui.Image> _blur(ui.Image source) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = _blurredSize.toDouble();
    final dst = Rect.fromLTWH(0, 0, size, size);
    // cover 式裁到正方形，避免拉伸变形
    final side = math.min(source.width, source.height).toDouble();
    final src = Rect.fromLTWH(
      (source.width - side) / 2,
      (source.height - side) / 2,
      side,
      side,
    );
    canvas.drawImageRect(
      source,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: _blurSigma,
          sigmaY: _blurSigma,
          tileMode: TileMode.decal,
        ),
    );
    return recorder.endRecording().toImage(_blurredSize, _blurredSize);
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    if (dt < _frameInterval) return;
    _lastTick = elapsed;
    setState(() {
      _angle = (_angle + dt.inMicroseconds / _period.inMicroseconds * 2 * math.pi) % (2 * math.pi);
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    // 缓存的图在整棵界面树内共享，这里不释放（仅几张 176px 小图）。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blurred = _blurred;
    final t = _angle;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: widget.fallback),
          if (blurred != null)
            ClipRect(
              child: widget.animate
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        _blob(blurred, const Alignment(-0.6, -0.5), scale: 1.9, angle: t),
                        _blob(blurred, const Alignment(0.7, 0.2), scale: 1.6, angle: -t * 1.3 + 1.2),
                        _blob(blurred, const Alignment(-0.3, 0.8), scale: 1.4, angle: t * 0.7 + 2.4, opacity: 0.8),
                      ],
                    )
                  : RawImage(image: blurred, fit: BoxFit.cover),
            ),
          // 压暗一层，保证白色歌词在任何封面上都有足够对比度
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x59000000), Color(0x33000000), Color(0x80000000)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _blob(ui.Image image, Alignment alignment, {required double scale, required double angle, double opacity = 1}) {
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: 0.75,
        child: AspectRatio(
          aspectRatio: 1,
          child: Opacity(
            opacity: opacity,
            child: Transform.rotate(
              angle: angle,
              child: Transform.scale(
                scale: scale,
                child: RawImage(image: image, fit: BoxFit.cover),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

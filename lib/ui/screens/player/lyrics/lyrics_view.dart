import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../models/lyrics.dart';
import '../../../../models/lyrics_query.dart';
import '../../../../models/track.dart';
import '../../../../providers/connect_provider.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../providers/spotify_provider.dart';
import '../../../../services/lyrics/lyrics_translation.dart';
import '../../../widgets/connect/connect_actions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/skeleton.dart';
import 'breathing_dots.dart';
import 'lyric_line_view.dart';

/// 歌词滚动区。
///
/// 行为（对齐 Apple Music）：
/// - 当前行顶端固定在可视区偏上的位置（上方恰好露出上一句），上下句按距离逐级模糊；
/// - 前奏与间奏（无人声片段）显示三个呼吸点，只在该片段内出现，结束时收起；歌曲末尾的无人声不显示；
/// - 用户手动拖动时全部行变清晰（[_browsing]）并显示滚动条，停手 3 秒后恢复对焦并滚回当前行；
///   自动滚动时不显示滚动条；
/// - 点击任意行跳转到该行时间点；
/// - 非同步歌词（UNSYNCED）全部清晰显示、不可点击。
///
/// 性能：手动监听 positionNotifier，只有「当前行」变化时才 setState；
/// 当前行用二分查找定位。
class LyricsView extends StatefulWidget {
  /// 曲目：官方歌词按 ID 取，LRCLIB 补全按曲名 / 歌手 / 专辑 / 时长匹配。
  final SpotifyTrack track;

  /// 顶部 / 底部被玻璃控件覆盖的高度，歌词可从其下方滚过。
  final double topInset;
  final double bottomInset;

  /// 歌词字号：手机 / 右栏 30，桌面沉浸式更大。
  final double fontSize;

  /// 歌词区左右留白。
  final double horizontalPadding;

  /// 跟随正在遥控的远程设备：进度取 [ConnectProvider.position]，点行跳转发给远程设备。
  /// 创建后不可切换，调用方用包含它的 key 让本地 / 远程切换时重建。
  final bool remote;

  const LyricsView({
    super.key,
    required this.track,
    this.topInset = 0,
    this.bottomInset = 0,
    this.fontSize = 30,
    this.horizontalPadding = 28,
    this.remote = false,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  static const Duration _browseHold = Duration(seconds: 3);

  /// 提前切行量：进度流约 200ms 一次，加上对焦/滚动动画耗时，
  /// 不提前的话视觉上会比演唱慢半拍（Apple Music 同样提前切行）。
  static const int _leadMs = 300;

  /// 第一句开唱前的留白至少这么长才显示前奏呼吸点。
  static const int _minIntroMs = 3000;

  /// 间奏短于这个时长不显示呼吸点（一闪而过反而打扰），对焦停在上一句。
  static const int _minGapMs = 1500;

  /// 当前行顶端在「未被玻璃遮挡区域」中的纵向位置比例：偏上，正好露出上一句。
  static const double _focusFraction = 0.16;

  /// 切行滚动与间奏收起 / 展开共用的时长与曲线（两者同步，位置才不会跳）。
  static const Duration _scrollDuration = Duration(milliseconds: 560);

  /// 减弱动效下的轻量时长：滚动仍平滑，但更短更克制，避免「跳行」的生硬感。
  static const Duration _reduceScrollDuration = Duration(milliseconds: 260);
  static const Curve _scrollCurve = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 当前生效的切行时长（减弱动效时用更短的轻量时长）。
  Duration get _scrollMotion => context.reduceMotion ? _reduceScrollDuration : _scrollDuration;

  /// 歌词区可视高度（由 LayoutBuilder 写入），用于把当前行对准"未被玻璃遮挡区域"的正中。
  double _viewportHeight = 0;

  late final ValueListenable<Duration> _position;
  late final void Function(Duration position) _seek;
  final ScrollController _scroll = ScrollController();

  SpotifyLyrics? _lyrics;
  late final LyricsTranslationController _translation;
  late final bool _ownsTranslation;
  SpotifyLyrics? _translationLyrics;
  String? _translationTrackUri;
  int _loadRevision = 0;
  List<GlobalKey> _lineKeys = const [];
  final GlobalKey _introKey = GlobalKey();

  /// 每行是否为空行（间奏占位：空串或 ♪）。
  List<bool> _blank = const [];

  /// 空行所在间奏的结束时间（其后第一句有词歌词的开始）；歌曲末尾的空行为 null（不显示呼吸点）。
  List<int?> _gapEnd = const [];

  /// 第一句之前是否有足够长的前奏（第一行本身就是空行时由该行承担前奏）。
  bool _hasIntro = false;
  int _activeIndex = -1;
  bool _browsing = false;
  Timer? _browseTimer;

  /// 歌词样式（设置页「歌词」分组）；没有 PreferencesProvider（部分测试）时用默认值。
  AppPreferences _style = AppPreferences.defaults;

  bool get _isSynced => _lyrics?.isSynced ?? false;
  bool get _translationIsCurrent =>
      identical(_lyrics, _translationLyrics) &&
      widget.track.uri == _translationTrackUri;

  /// 用于切行的时间点：固定提前量 + 远程模式下用户设置的提前量（服务端快照推算会有偏差）。
  int get _lookupMs =>
      _position.value.inMilliseconds +
      _leadMs +
      (widget.remote ? _style.remoteLyricsLeadMs : 0);

  @override
  void initState() {
    super.initState();
    final shared = context.read<LyricsTranslationController?>();
    _ownsTranslation = shared == null;
    _translation =
        shared ??
        LyricsTranslationController(
          lookup: context.read<SpotifyProvider>().fetchLyricsTranslation,
        );
    _translation.addListener(_onTranslation);
    if (widget.remote) {
      final connect = context.read<ConnectProvider>();
      _position = connect.position;
      _seek = (d) =>
          ConnectActions.run(context, () => connect.seekTo(d.inMilliseconds));
    } else {
      final playback = context.read<PlaybackProvider>();
      _position = playback.positionNotifier;
      _seek = playback.seekTo;
    }
    _position.addListener(_onPosition);
    _load();
  }

  /// 已加载的歌词对应的缓存代数（[SpotifyProvider.lyricsGeneration]），变化时重新加载。
  int _generation = 0;

  void _load() {
    final revision = ++_loadRevision;
    final spotify = context.read<SpotifyProvider>();
    _generation = spotify.lyricsGeneration;
    final cached = spotify.cachedLyrics(widget.track.id);
    if (cached != null) {
      _setLyrics(cached);
      return;
    }
    final generation = _generation;
    spotify.fetchLyrics(LyricsQuery.fromTrack(widget.track)).then((lyrics) {
      if (mounted && generation == _generation && revision == _loadRevision) {
        setState(() => _setLyrics(lyrics));
      }
    });
  }

  void _setLyrics(SpotifyLyrics lyrics) {
    _lyrics = lyrics;
    _lineKeys = List.generate(lyrics.lines.length, (_) => GlobalKey());
    final lines = lyrics.lines;
    _blank = [for (final l in lines) _isBlankWords(l.words)];
    _gapEnd = List<int?>.filled(lines.length, null);
    int? next;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (_blank[i]) {
        _gapEnd[i] = next;
      } else {
        next = lines[i].startTimeMs;
      }
    }
    _hasIntro =
        lines.isNotEmpty && !_blank[0] && lines[0].startTimeMs >= _minIntroMs;
    _activeIndex = _indexFor(_lookupMs);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToActive(animate: false),
    );
  }

  void _onTranslation() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToActive(animate: false),
    );
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.uri != widget.track.uri) {
      _lyrics = null;
      // The toolbar listens above this widget. Configure after the frame so a
      // cached track change cannot notify that ancestor during its build.
      _load();
    }
  }

  /// 对焦行：前奏阶段（尚未唱到第一句，_activeIndex 为 -1）对焦第一句，
  /// 保证任何时刻（包括暂停、刚打开）都有一句清晰地停在中间。
  static bool _isBlankWords(String words) {
    final t = words.trim();
    return t.isEmpty || t == '♪';
  }

  /// 正在进行的无人声片段（显示呼吸点）；不在其中时为 null。
  _Gap? get _currentGap {
    if (!_isSynced || _blank.isEmpty) return null;
    final lines = _lyrics!.lines;
    _Gap? gap;
    if (_activeIndex < 0) {
      if (_blank[0] && _gapEnd[0] != null) {
        gap = _Gap(0, 0, _gapEnd[0]!);
      } else if (_hasIntro) {
        gap = _Gap(-1, 0, lines[0].startTimeMs);
      }
    } else if (_blank[_activeIndex] && _gapEnd[_activeIndex] != null) {
      // 连续多个空行算同一段间奏，由第一个空行显示呼吸点
      var head = _activeIndex;
      while (head > 0 && _blank[head - 1]) {
        head--;
      }
      gap = _Gap(
        head,
        head == 0 ? 0 : lines[head].startTimeMs,
        _gapEnd[_activeIndex]!,
      );
    }
    if (gap == null) return null;
    final minMs = gap.entry < 0 ? _minIntroMs : _minGapMs;
    return gap.endMs - gap.startMs >= minMs ? gap : null;
  }

  /// 对焦项：呼吸点所在项（-1 为前奏）或当前行。前奏阶段没有呼吸点时对焦第一句；
  /// 落在不显示呼吸点的空行（短间奏 / 歌曲末尾）时停在上一句有词的歌词。
  int _focusEntryFor(_Gap? gap) {
    if (gap != null) return gap.entry;
    if (_activeIndex < 0) return 0;
    if (_activeIndex < _blank.length && _blank[_activeIndex]) {
      for (var i = _activeIndex - 1; i >= 0; i--) {
        if (!_blank[i]) return i;
      }
    }
    return _activeIndex;
  }

  /// 对焦行顶端的纵坐标：顶部信息区之下、偏上的位置。
  double get _focusTopY =>
      widget.topInset +
      (_viewportHeight - widget.topInset - widget.bottomInset).clamp(
            0.0,
            double.infinity,
          ) *
          _focusFraction;

  /// 最后一个 startTimeMs <= ms 的行；在第一行之前返回 -1。
  int _indexFor(int ms) {
    final lines = _lyrics?.lines ?? const <LyricLine>[];
    var lo = 0, hi = lines.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startTimeMs <= ms) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  void _onPosition() {
    if (!_isSynced) return;
    final index = _indexFor(_lookupMs);
    if (index == _activeIndex) return;
    setState(() => _activeIndex = index);
    if (!_browsing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  RenderBox? _boxOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box : null;
  }

  void _scrollToActive({bool animate = true}) {
    if (!mounted || _lineKeys.isEmpty || _viewportHeight <= 0) return;
    // 只滚歌词自己的滚动区：静态的 Scrollable.ensureVisible 会沿嵌套滚动容器一路向外滚
    // （右栏详情 ListView 会跟着歌词切行整体滑动），这里只改本滚动区的 position。
    final position = _scroll.hasClients ? _scroll.position : null;
    if (position == null) return;
    final focus = _focusEntryFor(_currentGap);
    final box = _boxOf(
      focus < 0 ? _introKey : _lineKeys[focus.clamp(0, _lineKeys.length - 1)],
    );
    if (box == null) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;

    // 对焦项之上正在收起的呼吸点：收起动画与滚动同步进行，结束后对焦项会上移它当前的高度，
    // 目标位置预先扣掉，动画全程平滑、终点准确
    var collapsing = 0.0;
    if (focus >= 0) {
      collapsing += _boxOf(_introKey)?.size.height ?? 0;
      for (var i = 0; i < focus; i++) {
        if (_blank[i]) collapsing += _boxOf(_lineKeys[i])?.size.height ?? 0;
      }
    }

    final reveal = viewport.getOffsetToReveal(box, 0).offset;
    final target = math.max(
      position.minScrollExtent,
      reveal - _focusTopY - collapsing,
    );
    if ((target - position.pixels).abs() < 0.5) return;
    if (animate) {
      position.animateTo(target, duration: _scrollMotion, curve: _scrollCurve);
    } else {
      position.jumpTo(target);
    }
  }

  /// 只响应用户手势（程序滚动不会产生 UserScrollNotification）。
  bool _onUserScroll(UserScrollNotification n) {
    if (!_isSynced || n.depth != 0) return false;
    _browseTimer?.cancel();
    if (!_browsing) setState(() => _browsing = true);
    _browseTimer = Timer(_browseHold, _endBrowsing);
    return false;
  }

  void _endBrowsing() {
    if (!mounted) return;
    setState(() => _browsing = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  void _seekToLine(LyricLine line) {
    _browseTimer?.cancel();
    _seek(Duration(milliseconds: line.startTimeMs));
    if (_browsing) setState(() => _browsing = false);
  }

  @override
  void dispose() {
    _translation.removeListener(_onTranslation);
    if (_ownsTranslation) _translation.dispose();
    _browseTimer?.cancel();
    _position.removeListener(_onPosition);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = context.select<PreferencesProvider?, AppPreferences>(
      (p) => p?.prefs ?? AppPreferences.defaults,
    );
    // 字号 / 对齐 / 双语开关变化后行高改变（双语开关决定译文行显不显示），重新把对焦行对准中心
    if (style.lyricsScale != _style.lyricsScale ||
        style.lyricsAlign != _style.lyricsAlign ||
        style.lyricsBilingual != _style.lyricsBilingual) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActive(animate: false),
      );
    }
    _style = style;
    final target = Localizations.localeOf(context).toLanguageTag();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _translationLyrics = _lyrics;
        _translationTrackUri = widget.track.uri;
        _translation.configure(
          _lyrics,
          style,
          target,
          query: LyricsQuery.fromTrack(widget.track),
        );
      }
    });
    // 歌词缓存被清空或这首歌被要求重新获取：回到加载态重新取
    final generation = context.select<SpotifyProvider, int>(
      (s) => s.lyricsGeneration,
    );
    if (generation != _generation) {
      _lyrics = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_load);
      });
      _generation = generation;
    }
    final lyrics = _lyrics;
    if (lyrics == null) return _LoadingLines(topInset: widget.topInset);
    if (lyrics.lines.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(
          top: widget.topInset,
          bottom: widget.bottomInset,
        ),
        child: Center(
          child: EmptyState(
            icon: Icons.lyrics_outlined,
            title: context.l10n.lyricsUnavailableTitle,
            message: context.l10n.lyricsUnavailableMessage,
            onDark: true,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 窗口尺寸变化后重新把对焦行对准中心
        if (constraints.maxHeight != _viewportHeight) {
          _viewportHeight = constraints.maxHeight;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToActive(animate: false),
          );
        }
        return _buildLines(lyrics);
      },
    );
  }

  Widget _buildLines(SpotifyLyrics lyrics) {
    final focusY = _focusTopY;
    final centered = _style.lyricsAlign == LyricsAlign.center;
    final fontSize = widget.fontSize * _style.lyricsScale;
    final lines = lyrics.lines;

    // 同步歌词：空行不再显示「• • •」文字，只有正在进行的那段无人声显示呼吸点，其余收起；
    // 模糊层级按「可见的行」计算，收起的空行不占一级
    final gap = _currentGap;
    final focus = _focusEntryFor(gap);
    final rank = List<int>.filled(lines.length, 0);
    var visible = gap?.entry == -1 ? 1 : 0;
    for (var i = 0; i < lines.length; i++) {
      rank[i] = visible;
      if (!(_isSynced && _blank[i] && i != gap?.entry)) visible++;
    }
    final focusRank = focus < 0 ? 0 : rank[focus];

    return NotificationListener<UserScrollNotification>(
      onNotification: _onUserScroll,
      child: ShaderMask(
        // 上下边缘柔和淡出，歌词像从玻璃下方浮现
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0.0, 0.14, 0.82, 1.0],
        ).createShader(rect),
        // 滚动条只在用户手动浏览时出现，跟随播放的自动滚动不显示
        child: RawScrollbar(
          controller: _scroll,
          thumbColor: Colors.white38,
          thickness: 5,
          radius: const Radius.circular(3),
          notificationPredicate: (n) => n.depth == 0 && _browsing,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: _scroll,
              physics: const BouncingScrollPhysics(),
              // 上下留出到对焦位置的距离，第一句和最后一句也能停在对焦位置
              padding: EdgeInsets.fromLTRB(
                widget.horizontalPadding,
                focusY,
                widget.horizontalPadding,
                _viewportHeight - focusY,
              ),
              child: Column(
                crossAxisAlignment: centered
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  if (!_isSynced)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        context.l10n.lyricsUnsynced,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (_isSynced)
                    KeyedSubtree(
                      key: _introKey,
                      child: _gapEntry(
                        gap?.entry == -1 ? gap : null,
                        fontSize,
                        centered,
                      ),
                    ),
                  for (var i = 0; i < lyrics.lines.length; i++)
                    if (_isSynced && _blank[i])
                      KeyedSubtree(
                        key: _lineKeys[i],
                        child: _gapEntry(
                          gap?.entry == i ? gap : null,
                          fontSize,
                          centered,
                        ),
                      )
                    else
                      RepaintBoundary(
                        key: _lineKeys[i],
                        child: LyricLineView(
                          text: lyrics.lines[i].words,
                          translation: _translationIsCurrent
                              ? _translation.lines?.elementAtOrNull(i)
                              : null,
                          fontSize: fontSize,
                          centered: centered,
                          blurScale: _style.lyricsBlur,
                          // 以对焦行为中心：当句清晰，上下句按行距逐级模糊
                          distance: _isSynced ? rank[i] - focusRank : 0,
                          focusAll: !_isSynced || _browsing,
                          onTap: _isSynced
                              ? () => _seekToLine(lyrics.lines[i])
                              : null,
                        ),
                      ),
                  if (lyrics.provider == LyricsProvider.lrclib ||
                      (_translationIsCurrent && _translation.fromLrclib))
                    Padding(
                      padding: const EdgeInsets.only(top: 28),
                      child: Text(
                        context.l10n.lyricsFromLrclib,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 无人声片段占位：[gap] 非空时展开显示呼吸点，否则收起为零高度。
  /// 展开 / 收起与切行滚动同时长同曲线，配合 [_scrollToActive] 的收起补偿保持位置连贯。
  Widget _gapEntry(_Gap? gap, double fontSize, bool centered) {
    return AnimatedSize(
      duration: _scrollMotion,
      curve: _scrollCurve,
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      child: gap == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: EdgeInsets.symmetric(vertical: fontSize * 0.4),
              child: SizedBox(
                width: double.infinity,
                height: fontSize * 1.3,
                child: Align(
                  alignment: centered ? Alignment.center : Alignment.centerLeft,
                  child: BreathingDots(
                    key: ValueKey(gap.startMs),
                    position: _position,
                    leadMs: _lookupMs - _position.value.inMilliseconds,
                    startMs: gap.startMs,
                    endMs: gap.endMs,
                    dotSize: fontSize * 0.4,
                    centered: centered,
                  ),
                ),
              ),
            ),
    );
  }
}

/// 一段无人声片段：[entry] 为显示呼吸点的行（-1 为第一句之前的前奏）。
@immutable
class _Gap {
  final int entry;
  final int startMs;
  final int endMs;

  const _Gap(this.entry, this.startMs, this.endMs);
}

/// 歌词加载中的骨架（白色半透明横条，适配深色流动背景）。
class _LoadingLines extends StatelessWidget {
  final double topInset;

  const _LoadingLines({required this.topInset});

  static const List<double> _widths = [0.82, 0.64, 0.9, 0.48, 0.74, 0.58];

  @override
  Widget build(BuildContext context) {
    // 不可滚动的 ScrollView：窗口很矮时直接裁掉多余骨架，而不是溢出报错
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(28, topInset + 24, 28, 0),
      child: SkeletonPulse(
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in _widths)
                Container(
                  width: constraints.maxWidth * w,
                  height: 26,
                  margin: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

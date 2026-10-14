import 'dart:async';
import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter/material.dart';
import 'models/danmaku_item.dart';
import 'scroll_danmaku_painter.dart';
import 'special_danmaku_painter.dart';
import 'static_danmaku_painter.dart';
import 'danmaku_controller.dart';
import 'dart:ui' as ui;
import 'models/danmaku_option.dart';
import '/models/danmaku_content_item.dart';
import 'dart:math';

class DanmakuScreen extends StatefulWidget {
  // 创建Screen后返回控制器
  final Function(DanmakuController) createdController;
  final DanmakuOption option;

  /// Disabled overlays discard their contents and schedule no work.
  final bool enabled;

  const DanmakuScreen({
    required this.createdController,
    required this.option,
    this.enabled = true,
    super.key,
  });

  @override
  State<DanmakuScreen> createState() => _DanmakuScreenState();
}

class _DanmakuScreenState extends State<DanmakuScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// 视图宽度
  double _viewWidth = 0;

  /// 弹幕控制器
  late DanmakuController _controller;

  /// 弹幕动画控制器
  late AnimationController _animationController;

  /// 静态弹幕动画控制器
  late AnimationController _staticAnimationController;

  /// 弹幕配置
  DanmakuOption _option = DanmakuOption();

  /// 滚动弹幕
  final List<DanmakuItem> _scrollDanmakuItems = [];

  /// 顶部弹幕
  final List<DanmakuItem> _topDanmakuItems = [];

  /// 底部弹幕
  final List<DanmakuItem> _bottomDanmakuItems = [];

  /// 高级弹幕
  final List<DanmakuItem> _specialDanmakuItems = [];

  /// 弹幕高度
  late double _danmakuHeight;

  /// 弹幕轨道数
  late int _trackCount;

  /// 弹幕轨道位置
  final List<double> _trackYPositions = [];

  late final _random = Random();

  /// 内部计时器
  int get _tick => _stopwatch.elapsedMilliseconds;

  final _stopwatch = Stopwatch();

  /// 运行状态
  bool _running = true;
  bool _paused = false;
  bool _foreground = true;
  bool _enabled = true;
  Timer? _cleanupTimer;

  bool get _hasItems =>
      _scrollDanmakuItems.isNotEmpty ||
      _topDanmakuItems.isNotEmpty ||
      _bottomDanmakuItems.isNotEmpty ||
      _specialDanmakuItems.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _enabled = widget.enabled;
    _running = _enabled && _foreground;
    _option = widget.option;
    _controller = DanmakuController(
      onAddDanmaku: addDanmaku,
      onUpdateOption: updateOption,
      onPause: pause,
      onResume: resume,
      onClear: clearDanmakus,
      onSetEnabled: setEnabled,
    );
    _controller.option = _option;
    _controller.running = _running;
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _option.duration),
    );

    _staticAnimationController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _option.duration),
    );

    WidgetsBinding.instance.addObserver(this);
    // A caller may pause or clear immediately from this callback.
    widget.createdController.call(_controller);
  }

  @override
  void didUpdateWidget(covariant DanmakuScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      setEnabled(widget.enabled);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _clearItems();
    _syncRunning();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _running = false;
    _cleanupTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _animationController.dispose();
    _staticAnimationController.dispose();
    _stopwatch.stop();
    super.dispose();
  }

  /// 添加弹幕
  void addDanmaku(DanmakuContentItem content) {
    if (!_running || !mounted) {
      return;
    }

    // Reject unavailable tracks before allocating TextPainter/Paragraphs. A
    // zero-width probe only rejects a scrolling track whose entrance is still
    // occupied; actual speed/collision checks use the measured width below.
    if ((content.type == DanmakuItemType.scroll && _option.hideScroll) ||
        (content.type == DanmakuItemType.top && _option.hideTop) ||
        (content.type == DanmakuItemType.bottom && _option.hideBottom)) return;
    if (content.type != DanmakuItemType.special && _trackYPositions.isEmpty)
      return;
    if (content.type == DanmakuItemType.scroll &&
        !_option.massiveMode &&
        !content.selfSend &&
        !_trackYPositions.any((position) => _scrollCanAddToTrack(position, 0)))
      return;
    if (content.type == DanmakuItemType.top &&
        !_trackYPositions.any(_topCanAddToTrack)) return;
    if (content.type == DanmakuItemType.bottom &&
        !_trackYPositions.any(_bottomCanAddToTrack)) return;

    if (content.type == DanmakuItemType.special) {
      if (!_option.hideSpecial) {
        (content as SpecialDanmakuContentItem).painterCache = TextPainter(
          text: TextSpan(
            text: content.text,
            style: TextStyle(
              color: content.color,
              fontSize: content.fontSize,
              fontWeight: FontWeight.values[_option.fontWeight],
              shadows: content.hasStroke
                  ? [
                      Shadow(
                          color: Colors.black.withOpacity(
                              content.alphaTween?.begin ??
                                  content.color.opacity),
                          blurRadius: 2)
                    ]
                  : null,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        _specialDanmakuItems.add(DanmakuItem(
          width: 0,
          height: 0,
          creationTime: _tick,
          content: content,
          paragraph: null,
          strokeParagraph: null,
        ));
      } else {
        return;
      }
    } else {
      // 在这里提前创建 Paragraph 缓存防止卡顿
      final textPainter = TextPainter(
        text: TextSpan(
            text: content.text,
            style: TextStyle(
                fontSize: _option.fontSize,
                fontWeight: FontWeight.values[_option.fontWeight])),
        textDirection: TextDirection.ltr,
      )..layout();
      final danmakuWidth = textPainter.width;
      final danmakuHeight = textPainter.height;

      final ui.Paragraph paragraph = Utils.generateParagraph(
          content, danmakuWidth, _option.fontSize, _option.fontWeight);

      ui.Paragraph? strokeParagraph;
      if (_option.showStroke) {
        strokeParagraph = Utils.generateStrokeParagraph(
            content, danmakuWidth, _option.fontSize, _option.fontWeight);
      }

      int idx = 1;
      for (double yPosition in _trackYPositions) {
        if (content.type == DanmakuItemType.scroll && !_option.hideScroll) {
          bool scrollCanAddToTrack =
              _scrollCanAddToTrack(yPosition, danmakuWidth);

          if (scrollCanAddToTrack) {
            _scrollDanmakuItems.add(DanmakuItem(
                yPosition: yPosition,
                xPosition: _viewWidth,
                width: danmakuWidth,
                height: danmakuHeight,
                creationTime: _tick,
                content: content,
                paragraph: paragraph,
                strokeParagraph: strokeParagraph));
            break;
          }

          /// 无法填充自己发送的弹幕时强制添加
          if (content.selfSend && idx == _trackCount) {
            _scrollDanmakuItems.add(DanmakuItem(
                yPosition: _trackYPositions[0],
                xPosition: _viewWidth,
                width: danmakuWidth,
                height: danmakuHeight,
                creationTime: _tick,
                content: content,
                paragraph: paragraph,
                strokeParagraph: strokeParagraph));
            break;
          }

          /// 海量弹幕启用时进行随机添加
          if (_option.massiveMode && idx == _trackCount) {
            var randomYPosition =
                _trackYPositions[_random.nextInt(_trackYPositions.length)];
            _scrollDanmakuItems.add(DanmakuItem(
                yPosition: randomYPosition,
                xPosition: _viewWidth,
                width: danmakuWidth,
                height: danmakuHeight,
                creationTime: _tick,
                content: content,
                paragraph: paragraph,
                strokeParagraph: strokeParagraph));
            break;
          }
        }

        if (content.type == DanmakuItemType.top && !_option.hideTop) {
          bool topCanAddToTrack = _topCanAddToTrack(yPosition);

          if (topCanAddToTrack) {
            _topDanmakuItems.add(DanmakuItem(
                yPosition: yPosition,
                xPosition: _viewWidth,
                width: danmakuWidth,
                height: danmakuHeight,
                creationTime: _tick,
                content: content,
                paragraph: paragraph,
                strokeParagraph: strokeParagraph));
            break;
          }
        }

        if (content.type == DanmakuItemType.bottom && !_option.hideBottom) {
          bool bottomCanAddToTrack = _bottomCanAddToTrack(yPosition);

          if (bottomCanAddToTrack) {
            _bottomDanmakuItems.add(DanmakuItem(
                yPosition: yPosition,
                xPosition: _viewWidth,
                width: danmakuWidth,
                height: danmakuHeight,
                creationTime: _tick,
                content: content,
                paragraph: paragraph,
                strokeParagraph: strokeParagraph));
            break;
          }
        }
        idx++;
      }
    }

    _ensureWork();
    switch (content.type) {
      case DanmakuItemType.top:
      case DanmakuItemType.bottom:
        // 重绘静态弹幕
        setState(() {
          _staticAnimationController.value = 0;
        });
        break;
      case DanmakuItemType.scroll:
      case DanmakuItemType.special:
        if (!_animationController.isAnimating &&
            (_scrollDanmakuItems.isNotEmpty ||
                _specialDanmakuItems.isNotEmpty)) {
          _animationController.repeat();
        }
        break;
    }
  }

  /// Manual pause remains independent from visibility and app lifecycle.
  void pause() {
    if (!mounted) return;
    _paused = true;
    _syncRunning();
    setState(() {});
  }

  void resume() {
    if (!mounted) return;
    _paused = false;
    _syncRunning();
    setState(() {});
  }

  void _stopWork() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _animationController.stop();
    _staticAnimationController.stop();
    _stopwatch.stop();
  }

  void _syncRunning() {
    _running = _enabled && _foreground && !_paused;
    _controller.running = _running;
    if (!_running) {
      _stopWork();
    } else {
      _ensureWork();
    }
  }

  void setEnabled(bool enabled) {
    if (!mounted || _enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) _clearItems();
    _syncRunning();
    setState(() {});
  }

  void _ensureWork() {
    if (!_running || !_hasItems || !mounted) {
      _stopWork();
      return;
    }
    _stopwatch.start();
    if ((_scrollDanmakuItems.isNotEmpty || _specialDanmakuItems.isNotEmpty) &&
        !_animationController.isAnimating) {
      _animationController.repeat();
    }
    _cleanupTimer ??= Timer(const Duration(milliseconds: 100), _cleanExpired);
  }

  /// 更新弹幕设置
  void updateOption(DanmakuOption option) {
    bool needClearParagraph = false;
    if (_animationController.isAnimating) {
      _animationController.stop();
    }

    if (option.fontSize != _option.fontSize) {
      needClearParagraph = true;
    }

    /// 需要隐藏弹幕时清理已有弹幕
    if (option.hideScroll && !_option.hideScroll) {
      _scrollDanmakuItems.clear();
    }
    if (option.hideTop && !_option.hideTop) {
      _topDanmakuItems.clear();
    }
    if (option.hideBottom && !_option.hideBottom) {
      _bottomDanmakuItems.clear();
    }
    _option = option;
    _controller.option = _option;

    /// 清理已经存在的 Paragraph 缓存
    if (needClearParagraph) {
      for (DanmakuItem item in _scrollDanmakuItems) {
        if (item.paragraph != null) {
          item.paragraph = null;
        }
        if (item.strokeParagraph != null) {
          item.strokeParagraph = null;
        }
      }
      for (DanmakuItem item in _topDanmakuItems) {
        if (item.paragraph != null) {
          item.paragraph = null;
        }
        if (item.strokeParagraph != null) {
          item.strokeParagraph = null;
        }
      }
      for (DanmakuItem item in _bottomDanmakuItems) {
        if (item.paragraph != null) {
          item.paragraph = null;
        }
        if (item.strokeParagraph != null) {
          item.strokeParagraph = null;
        }
      }
    }
    _ensureWork();
    setState(() {});
  }

  void _clearItems() {
    _scrollDanmakuItems.clear();
    _topDanmakuItems.clear();
    _bottomDanmakuItems.clear();
    _specialDanmakuItems.clear();
    _stopWork();
  }

  /// Clear also cancels the pending cleanup task, so an empty overlay is idle.
  void clearDanmakus() {
    if (!mounted) return;
    _clearItems();
    setState(() {});
  }

  /// 确定滚动弹幕是否可以添加
  bool _scrollCanAddToTrack(double yPosition, double newDanmakuWidth) {
    for (var item in _scrollDanmakuItems) {
      if (item.yPosition == yPosition) {
        final existingEndPosition = item.xPosition + item.width;
        // 首先保证进入屏幕时不发生重叠，其次保证知道移出屏幕前不与速度慢的弹幕(弹幕宽度较小)发生重叠
        if (_viewWidth - existingEndPosition < 0) {
          return false;
        }
        if (item.width < newDanmakuWidth) {
          if ((1 -
                  ((_viewWidth - item.xPosition) / (item.width + _viewWidth))) >
              ((_viewWidth) / (_viewWidth + newDanmakuWidth))) {
            return false;
          }
        }
      }
    }
    return true;
  }

  /// 确定顶部弹幕是否可以添加
  bool _topCanAddToTrack(double yPosition) {
    for (var item in _topDanmakuItems) {
      if (item.yPosition == yPosition) {
        return false;
      }
    }
    return true;
  }

  /// 确定底部弹幕是否可以添加
  bool _bottomCanAddToTrack(double yPosition) {
    for (var item in _bottomDanmakuItems) {
      if (item.yPosition == yPosition) {
        return false;
      }
    }
    return true;
  }

  void _cleanExpired() {
    _cleanupTimer = null;
    if (!_running || !mounted) return;
    final before = _scrollDanmakuItems.length +
        _topDanmakuItems.length +
        _bottomDanmakuItems.length +
        _specialDanmakuItems.length;
    final staticDuration = _option.duration * 1000;
    _scrollDanmakuItems.removeWhere((item) => item.xPosition + item.width < 0);
    _topDanmakuItems
        .removeWhere((item) => _tick - item.creationTime >= staticDuration);
    _bottomDanmakuItems
        .removeWhere((item) => _tick - item.creationTime >= staticDuration);
    _specialDanmakuItems.removeWhere((item) =>
        _tick - item.creationTime >=
        (item.content as SpecialDanmakuContentItem).duration);
    if (_scrollDanmakuItems.isEmpty && _specialDanmakuItems.isEmpty) {
      _animationController.stop();
    }
    final after = _scrollDanmakuItems.length +
        _topDanmakuItems.length +
        _bottomDanmakuItems.length +
        _specialDanmakuItems.length;
    if (before != after) setState(() {});
    _ensureWork();
  }

  @override
  Widget build(BuildContext context) {
    /// 计算弹幕轨道
    final textPainter = TextPainter(
      text: TextSpan(text: '弹幕', style: TextStyle(fontSize: _option.fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    _danmakuHeight = textPainter.height;
    return LayoutBuilder(builder: (context, constraints) {
      /// 计算视图宽度
      if (constraints.maxWidth != _viewWidth) {
        _viewWidth = constraints.maxWidth;
      }

      _trackCount =
          (constraints.maxHeight * _option.area / _danmakuHeight).floor();

      /// 为字幕留出余量
      if (_option.safeArea && _option.area == 1.0) {
        _trackCount = _trackCount - 1;
      }

      _trackYPositions.clear();
      for (int i = 0; i < _trackCount; i++) {
        _trackYPositions.add(i * _danmakuHeight);
      }
      return ClipRect(
        child: IgnorePointer(
          child: Opacity(
            opacity: _option.opacity,
            child: Stack(children: [
              RepaintBoundary(
                  child: AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: ScrollDanmakuPainter(
                        _animationController.value,
                        _scrollDanmakuItems,
                        _option.duration,
                        _option.fontSize,
                        _option.fontWeight,
                        _option.showStroke,
                        _danmakuHeight,
                        _running,
                        _tick),
                    child: Container(),
                  );
                },
              )),
              RepaintBoundary(
                  child: AnimatedBuilder(
                animation: _staticAnimationController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: StaticDanmakuPainter(
                        _staticAnimationController.value,
                        _topDanmakuItems,
                        _bottomDanmakuItems,
                        _option.duration,
                        _option.fontSize,
                        _option.fontWeight,
                        _option.showStroke,
                        _danmakuHeight,
                        _running,
                        _tick),
                    child: Container(),
                  );
                },
              )),
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _animationController, // 与滚动弹幕共用控制器
                  builder: (context, child) {
                    return CustomPaint(
                      painter: SpecialDanmakuPainter(
                          _animationController.value,
                          _specialDanmakuItems,
                          _option.fontSize,
                          _option.fontWeight,
                          _running,
                          _tick),
                      child: Container(),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

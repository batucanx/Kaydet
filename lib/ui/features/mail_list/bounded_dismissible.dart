import 'package:flutter/material.dart';

/// `Dismissible`'ın parmak dokunma alanı dışına çıkınca DERHAL iptal olan
/// hâli.
///
/// Sorun: `Dismissible`'ın kendi `GestureDetector`'ı, sürükleme bir kez
/// başladıktan sonra parmağın ekranda NEREDE olduğuna bakmaksızın (jest
/// arenası bir kez kazanıldığında konum artık hit-test edilmez) gelen tüm
/// `DragUpdate` olaylarını satırın kaydırması olarak yorumlamaya devam eder.
/// Bu yüzden kullanıcı listede gezinirken parmağı satırın sınırlarının
/// dışına (bir üst/alt satıra, ekran kenarına) kayarsa Sil/Arşivle eylemi
/// yanlışlıkla tetiklenebiliyordu.
///
/// Bu widget, `Dismissible`'ın (`flutter/src/widgets/dismissible.dart`)
/// mantığının aynısını uygular — eşik, hız ve animasyon davranışı
/// DEĞİŞMEDEN — tek farkla: her `DragUpdate`'te parmağın global konumu bu
/// satırın kendi `RenderBox` sınırlarıyla karşılaştırılır. Sınır dışına
/// çıkıldığı anda sürükleme "bitmemiş" sayılır (`_dragUnderway = false`) ve
/// denetleyici başlangıç konumuna animasyonla geri döner; ne eşik ne de hız
/// kontrolü çalışır, dolayısıyla `onDismissed` asla tetiklenmez. Parmak
/// sınırlara geri girse bile aynı jest devam ETMEZ — `_dragUnderway` yalnızca
/// jest arenasının yeni bir sürükleme başlattığı `onHorizontalDragStart`'ta
/// tekrar `true` olur, yani yeni bir dokunuşla yeni bir jest gerekir.
///
/// Yatay kaydırma ile dikey listeleme kaydırması arasındaki çakışma zaten
/// Flutter'ın jest arenasınca (yön başına dokunma-payı yarışı) çözülür;
/// burada ek bir şey yapılmaz.
class BoundedDismissible extends StatefulWidget {
  const BoundedDismissible({
    required Key super.key,
    required this.child,
    required this.background,
    required this.secondaryBackground,
    required this.direction,
    required this.dismissThresholds,
    required this.resizeDuration,
    required this.movementDuration,
    this.confirmDismiss,
    this.onUpdate,
    this.onDismissed,
  });

  final Widget child;
  final Widget background;
  final Widget secondaryBackground;
  final DismissDirection direction;
  final Map<DismissDirection, double> dismissThresholds;
  final Duration? resizeDuration;
  final Duration movementDuration;
  final ConfirmDismissCallback? confirmDismiss;
  final DismissUpdateCallback? onUpdate;
  final DismissDirectionCallback? onDismissed;

  @override
  State<BoundedDismissible> createState() => _BoundedDismissibleState();
}

const Curve _kResizeTimeCurve = Interval(0.4, 1.0, curve: Curves.ease);
const double _kMinFlingVelocity = 700.0;
const double _kMinFlingVelocityDelta = 400.0;
const double _kFlingVelocityScale = 1.0 / 300.0;
const double _kDismissThreshold = 0.4;

enum _FlingGestureKind { none, forward, reverse }

class _BoundedDismissibleClipper extends CustomClipper<Rect> {
  _BoundedDismissibleClipper({required this.axis, required this.moveAnimation})
    : super(reclip: moveAnimation);

  final Axis axis;
  final Animation<Offset> moveAnimation;

  @override
  Rect getClip(Size size) {
    switch (axis) {
      case Axis.horizontal:
        final double offset = moveAnimation.value.dx * size.width;
        if (offset < 0) {
          return Rect.fromLTRB(size.width + offset, 0.0, size.width, size.height);
        }
        return Rect.fromLTRB(0.0, 0.0, offset, size.height);
      case Axis.vertical:
        final double offset = moveAnimation.value.dy * size.height;
        if (offset < 0) {
          return Rect.fromLTRB(0.0, size.height + offset, size.width, size.height);
        }
        return Rect.fromLTRB(0.0, 0.0, size.width, offset);
    }
  }

  @override
  Rect getApproximateClipRect(Size size) => getClip(size);

  @override
  bool shouldReclip(_BoundedDismissibleClipper oldClipper) {
    return oldClipper.axis != axis || oldClipper.moveAnimation.value != moveAnimation.value;
  }
}

class _BoundedDismissibleState extends State<BoundedDismissible>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  void initState() {
    super.initState();
    _moveController
      ..addStatusListener(_handleDismissStatusChanged)
      ..addListener(_handleDismissUpdateValueChanged);
    _updateMoveAnimation();
  }

  late final AnimationController _moveController = AnimationController(
    duration: widget.movementDuration,
    vsync: this,
  );
  late Animation<Offset> _moveAnimation;

  AnimationController? _resizeController;
  Animation<double>? _resizeAnimation;

  double _dragExtent = 0.0;
  bool _confirming = false;
  bool _dragUnderway = false;
  Size? _sizePriorToCollapse;
  bool _dismissThresholdReached = false;

  final GlobalKey _contentKey = GlobalKey();

  @override
  bool get wantKeepAlive =>
      _moveController.isAnimating || (_resizeController?.isAnimating ?? false);

  @override
  void dispose() {
    _moveController.dispose();
    _resizeController?.dispose();
    super.dispose();
  }

  bool get _directionIsXAxis {
    return widget.direction == DismissDirection.horizontal ||
        widget.direction == DismissDirection.endToStart ||
        widget.direction == DismissDirection.startToEnd;
  }

  DismissDirection _extentToDirection(double extent) {
    if (extent == 0.0) {
      return DismissDirection.none;
    }
    if (_directionIsXAxis) {
      return switch (Directionality.of(context)) {
        TextDirection.rtl when extent < 0 => DismissDirection.startToEnd,
        TextDirection.ltr when extent > 0 => DismissDirection.startToEnd,
        TextDirection.rtl || TextDirection.ltr => DismissDirection.endToStart,
      };
    }
    return extent > 0 ? DismissDirection.down : DismissDirection.up;
  }

  DismissDirection get _dismissDirection => _extentToDirection(_dragExtent);

  double get _dismissThreshold => widget.dismissThresholds[_dismissDirection] ?? _kDismissThreshold;

  double get _overallDragAxisExtent {
    final Size size = context.size!;
    return _directionIsXAxis ? size.width : size.height;
  }

  /// Bu satırın (kendi `RenderBox`'ının) EKRANDAKİ (global) sınırları —
  /// parmağın hâlâ bu satırın üzerinde olup olmadığını anlamak için.
  Rect? _globalBounds() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize || !renderObject.attached) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _handleDragStart(DragStartDetails details) {
    if (_confirming) {
      return;
    }
    _dragUnderway = true;
    if (_moveController.isAnimating) {
      _dragExtent = _moveController.value * _overallDragAxisExtent * _dragExtent.sign;
      _moveController.stop();
    } else {
      _dragExtent = 0.0;
      _moveController.value = 0.0;
    }
    setState(() {
      _updateMoveAnimation();
    });
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_dragUnderway || _moveController.isAnimating) {
      return;
    }

    // Parmak satırdan dikey eksende (başka bir satıra) kaydıysa jest DERHAL biter:
    // bu güncelleme uygulanmaz, denetleyici başlangıca animasyonla döner.
    // Yatay eksende ise parmağın satır/ekran kenarına gitmesi satırı
    // arşivlemek/silmek için gereklidir; yatay sınır kontrolü yapılmaz.
    final bounds = _globalBounds();
    if (bounds != null) {
      if (_directionIsXAxis) {
        const verticalTolerance = 24.0;
        final y = details.globalPosition.dy;
        if (y < bounds.top - verticalTolerance || y > bounds.bottom + verticalTolerance) {
          _dragUnderway = false;
          if (!_moveController.isDismissed) {
            _moveController.reverse();
          }
          return;
        }
      } else {
        const horizontalTolerance = 24.0;
        final x = details.globalPosition.dx;
        if (x < bounds.left - horizontalTolerance || x > bounds.right + horizontalTolerance) {
          _dragUnderway = false;
          if (!_moveController.isDismissed) {
            _moveController.reverse();
          }
          return;
        }
      }
    }

    final double delta = details.primaryDelta!;
    final double oldDragExtent = _dragExtent;
    switch (widget.direction) {
      case DismissDirection.horizontal:
      case DismissDirection.vertical:
        _dragExtent += delta;

      case DismissDirection.up:
        if (_dragExtent + delta < 0) {
          _dragExtent += delta;
        }

      case DismissDirection.down:
        if (_dragExtent + delta > 0) {
          _dragExtent += delta;
        }

      case DismissDirection.endToStart:
        switch (Directionality.of(context)) {
          case TextDirection.rtl:
            if (_dragExtent + delta > 0) {
              _dragExtent += delta;
            }
          case TextDirection.ltr:
            if (_dragExtent + delta < 0) {
              _dragExtent += delta;
            }
        }

      case DismissDirection.startToEnd:
        switch (Directionality.of(context)) {
          case TextDirection.rtl:
            if (_dragExtent + delta < 0) {
              _dragExtent += delta;
            }
          case TextDirection.ltr:
            if (_dragExtent + delta > 0) {
              _dragExtent += delta;
            }
        }

      case DismissDirection.none:
        _dragExtent = 0;
    }
    if (oldDragExtent.sign != _dragExtent.sign) {
      setState(() {
        _updateMoveAnimation();
      });
    }
    if (!_moveController.isAnimating) {
      _moveController.value = _dragExtent.abs() / _overallDragAxisExtent;
    }
  }

  void _handleDismissUpdateValueChanged() {
    if (widget.onUpdate != null) {
      final bool oldDismissThresholdReached = _dismissThresholdReached;
      _dismissThresholdReached = _moveController.value > _dismissThreshold;
      final details = DismissUpdateDetails(
        direction: _dismissDirection,
        reached: _dismissThresholdReached,
        previousReached: oldDismissThresholdReached,
        progress: _moveController.value,
      );
      widget.onUpdate!(details);
    }
  }

  void _updateMoveAnimation() {
    final double end = _dragExtent.sign;
    _moveAnimation = _moveController.drive(
      Tween<Offset>(
        begin: Offset.zero,
        end: _directionIsXAxis ? Offset(end, 0.0) : Offset(0.0, end),
      ),
    );
  }

  _FlingGestureKind _describeFlingGesture(Velocity velocity) {
    if (_dragExtent == 0.0) {
      return _FlingGestureKind.none;
    }
    final double vx = velocity.pixelsPerSecond.dx;
    final double vy = velocity.pixelsPerSecond.dy;
    DismissDirection flingDirection;
    if (_directionIsXAxis) {
      if (vx.abs() - vy.abs() < _kMinFlingVelocityDelta || vx.abs() < _kMinFlingVelocity) {
        return _FlingGestureKind.none;
      }
      assert(vx != 0.0);
      flingDirection = _extentToDirection(vx);
    } else {
      if (vy.abs() - vx.abs() < _kMinFlingVelocityDelta || vy.abs() < _kMinFlingVelocity) {
        return _FlingGestureKind.none;
      }
      assert(vy != 0.0);
      flingDirection = _extentToDirection(vy);
    }
    if (flingDirection == _dismissDirection) {
      return _FlingGestureKind.forward;
    }
    return _FlingGestureKind.reverse;
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_dragUnderway || _moveController.isAnimating) {
      return;
    }
    _dragUnderway = false;
    if (_moveController.isCompleted) {
      _handleMoveCompleted();
      return;
    }
    final double flingVelocity = _directionIsXAxis
        ? details.velocity.pixelsPerSecond.dx
        : details.velocity.pixelsPerSecond.dy;
    switch (_describeFlingGesture(details.velocity)) {
      case _FlingGestureKind.forward:
        assert(_dragExtent != 0.0);
        assert(!_moveController.isDismissed);
        if (_dismissThreshold >= 1.0) {
          _moveController.reverse();
          break;
        }
        _dragExtent = flingVelocity.sign;
        _moveController.fling(velocity: flingVelocity.abs() * _kFlingVelocityScale);
      case _FlingGestureKind.reverse:
        assert(_dragExtent != 0.0);
        assert(!_moveController.isDismissed);
        _dragExtent = flingVelocity.sign;
        _moveController.fling(velocity: -flingVelocity.abs() * _kFlingVelocityScale);
      case _FlingGestureKind.none:
        if (!_moveController.isDismissed) {
          if (_moveController.value > _dismissThreshold) {
            _moveController.forward();
          } else {
            _moveController.reverse();
          }
        }
    }
  }

  Future<void> _handleDismissStatusChanged(AnimationStatus status) async {
    if (status.isCompleted && !_dragUnderway) {
      await _handleMoveCompleted();
    }
    if (mounted) {
      updateKeepAlive();
    }
  }

  Future<void> _handleMoveCompleted() async {
    if (_dismissThreshold >= 1.0) {
      _moveController.reverse();
      return;
    }
    final bool result = await _confirmStartResizeAnimation();
    if (mounted) {
      if (result) {
        _startResizeAnimation();
      } else {
        _moveController.reverse();
      }
    }
  }

  Future<bool> _confirmStartResizeAnimation() async {
    if (widget.confirmDismiss != null) {
      _confirming = true;
      final DismissDirection direction = _dismissDirection;
      try {
        return await widget.confirmDismiss!(direction) ?? false;
      } finally {
        _confirming = false;
      }
    }
    return true;
  }

  void _startResizeAnimation() {
    assert(_moveController.isCompleted);
    assert(_resizeController == null);
    assert(_sizePriorToCollapse == null);
    if (widget.resizeDuration == null) {
      widget.onDismissed?.call(_dismissDirection);
    } else {
      _resizeController = AnimationController(duration: widget.resizeDuration, vsync: this)
        ..addListener(_handleResizeProgressChanged)
        ..addStatusListener((AnimationStatus status) => updateKeepAlive());
      _resizeController!.forward();
      setState(() {
        _sizePriorToCollapse = context.size;
        _resizeAnimation = _resizeController!
            .drive(CurveTween(curve: _kResizeTimeCurve))
            .drive(Tween<double>(begin: 1.0, end: 0.0));
      });
    }
  }

  void _handleResizeProgressChanged() {
    if (_resizeController!.isCompleted) {
      widget.onDismissed?.call(_dismissDirection);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin için.

    assert(!_directionIsXAxis || debugCheckHasDirectionality(context));

    Widget background = widget.background;
    final DismissDirection direction = _dismissDirection;
    if (direction == DismissDirection.endToStart || direction == DismissDirection.up) {
      background = widget.secondaryBackground;
    }

    if (_resizeAnimation != null) {
      return SizeTransition(
        sizeFactor: _resizeAnimation!,
        axis: _directionIsXAxis ? Axis.vertical : Axis.horizontal,
        child: SizedBox(
          width: _sizePriorToCollapse!.width,
          height: _sizePriorToCollapse!.height,
          child: background,
        ),
      );
    }

    Widget content = SlideTransition(
      position: _moveAnimation,
      child: KeyedSubtree(key: _contentKey, child: widget.child),
    );

    content = Stack(
      children: <Widget>[
        if (!_moveAnimation.isDismissed)
          Positioned.fill(
            child: ClipRect(
              clipper: _BoundedDismissibleClipper(
                axis: _directionIsXAxis ? Axis.horizontal : Axis.vertical,
                moveAnimation: _moveAnimation,
              ),
              child: background,
            ),
          ),
        content,
      ],
    );

    if (widget.direction == DismissDirection.none) {
      return content;
    }

    return GestureDetector(
      onHorizontalDragStart: _directionIsXAxis ? _handleDragStart : null,
      onHorizontalDragUpdate: _directionIsXAxis ? _handleDragUpdate : null,
      onHorizontalDragEnd: _directionIsXAxis ? _handleDragEnd : null,
      onVerticalDragStart: _directionIsXAxis ? null : _handleDragStart,
      onVerticalDragUpdate: _directionIsXAxis ? null : _handleDragUpdate,
      onVerticalDragEnd: _directionIsXAxis ? null : _handleDragEnd,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}

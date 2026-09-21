import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Ekranın altında kısa süre görünen, animasyonlu geçici bildirim.
///
/// Material `SnackBar`ın Material 3 "floating" biçimi kapanırken opaklığı
/// animasyon süresinin yalnızca %20'lik diliminde düşürür (Flutter'daki
/// `_snackBarM3FadeInCurve`, `Interval(0.4, 0.6)`) — pratikte sert bir
/// kesmeyle kaybolur ve süreyi uzatmak eğriyi düzeltmez. Bu bildirim
/// `SnackBarThemeData` ile aynı görünümü korurken hem girişte hem çıkışta
/// yumuşakça kayıp solar.
///
/// `ScaffoldMessenger`a bağlı DEĞİLDİR: kök `Overlay`de yaşar, dolayısıyla
/// hangi ekranın açık olduğundan ve çağıran ekranın ağaçta kalıp kalmadığından
/// bağımsızdır. Bir `Scaffold` yalnızca KENDİ FAB'ından/alt çubuğundan
/// kaçınabilir; iç içe Scaffold'larda (bkz. `AppShell` > `MailListScreen`)
/// snackbar'ı barındıran kök Scaffold iç ekranın FAB'ını hiç bilmez ve
/// bildirim onun üstüne biner. Alt kısmı kaplayan bir öğesi olan ekran bunu
/// [show]'daki `bottomInset` ile bildirir.
abstract final class KaydetNotice {
  static _NoticeViewState? _active;

  /// [message]'ı [overlay]'in en üstünde gösterir; varsa önceki bildirim
  /// yumuşakça kapanır.
  ///
  /// [bottomInset], alt güvenli alanın ÜSTÜNDE kalan ve bildirimin
  /// kapatmaması gereken yüksekliktir (ör. FAB + kenar boşluğu ya da alt
  /// eylem çubuğu). [actionLabel] verilirse yanında bir metin düğmesi çıkar;
  /// dokunulunca [onAction] çağrılır ve bildirim kapanır.
  static void show(
    OverlayState overlay, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    bool destructiveAction = false,
    double bottomInset = 0,
    Duration duration = const Duration(seconds: 3),
  }) {
    _active?.dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _NoticeView(
        message: message,
        actionLabel: actionLabel,
        onAction: onAction,
        destructiveAction: destructiveAction,
        bottomInset: bottomInset,
        duration: duration,
        onClosed: () {
          entry.remove();
          entry.dispose();
        },
      ),
    );
    overlay.insert(entry);
  }

  /// Görünen bildirim varsa yumuşakça kapatır.
  static void dismiss() {
    _active?.dismiss();
  }
}

class _NoticeView extends StatefulWidget {
  const _NoticeView({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.destructiveAction,
    required this.bottomInset,
    required this.duration,
    required this.onClosed,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool destructiveAction;
  final double bottomInset;
  final Duration duration;

  /// Çıkış animasyonu bittiğinde çağrılır — girdiyi `Overlay`den kaldırır.
  final VoidCallback onClosed;

  @override
  State<_NoticeView> createState() => _NoticeViewState();
}

class _NoticeViewState extends State<_NoticeView>
    with SingleTickerProviderStateMixin {
  /// Masaüstü/tablet gibi geniş ekranlarda kart tüm genişliğe yayılmasın.
  static const double _maxWidth = 560;

  /// Dinlenme konumunda alt çubuklarla arasında bırakılan boşluk.
  static const double _restingMargin = Space.md;

  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  late final Animation<Offset> _slide;

  Timer? _timer;
  bool _started = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    // Giriş hızlı başlayıp yumuşakça oturur, çıkış yavaş başlayıp hızlanır —
    // aynı eğrinin tersi olsaydı çıkış "geri sarılan" bir giriş gibi
    // hissettirirdi.
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Motion.standard,
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(_curve);
    KaydetNotice._active = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Erişilebilirlik: sistem animasyonları kapatmışsa süreler sıfırlanır.
    _controller
      ..duration = context.motion(Motion.slow)
      ..reverseDuration = context.motion(Motion.slow);
    if (!_started) {
      _started = true;
      _enter();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (identical(KaydetNotice._active, this)) KaydetNotice._active = null;
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    await _controller.forward();
    if (!mounted || _closing) return;
    _timer = Timer(widget.duration, dismiss);
  }

  /// Bildirimi çıkış animasyonuyla kapatır; art arda çağrılması zararsızdır.
  Future<void> dismiss() async {
    if (_closing || !mounted) return;
    _closing = true;
    _timer?.cancel();
    await _controller.reverse();
    if (!mounted) return;
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final safeBottom = math.max(
      MediaQuery.viewInsetsOf(context).bottom,
      viewPadding.bottom,
    );
    final actionLabel = widget.actionLabel;

    return Positioned(
      left: Space.lg + viewPadding.left,
      right: Space.lg + viewPadding.right,
      bottom:
          safeBottom +
          math.max(_restingMargin, widget.bottomInset + Space.sm),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: FadeTransition(
            opacity: _curve,
            child: SlideTransition(
              position: _slide,
              child: Semantics(
                container: true,
                liveRegion: true,
                child: GestureDetector(
                  // Aşağı kaydırarak kapatma — Material snackbar'daki gibi.
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 200) dismiss();
                  },
                  child: Material(
                    color: t.surfaceElevated,
                    elevation: t.brightness == Brightness.dark ? 0 : 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: Dimens.controlHeight,
                      ),
                      child: Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: Space.lg,
                          end: actionLabel == null ? Space.lg : Space.sm,
                          top: Space.xs,
                          bottom: Space.xs,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.message,
                                style: AppText.bodyMedium.copyWith(
                                  color: t.textPrimary,
                                ),
                              ),
                            ),
                            if (actionLabel != null)
                              TextButton(
                                onPressed: () {
                                  widget.onAction?.call();
                                  dismiss();
                                },
                                style: TextButton.styleFrom(
                                  foregroundColor: widget.destructiveAction
                                      ? t.danger
                                      : t.accent,
                                ),
                                child: Text(actionLabel),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';

/// [KaydetRoute]'un uygulayabileceği geçiş stilleri.
enum KaydetTransitionStyle {
  /// Varsayılan: yumuşak solma — yeni sayfa, olduğu gibi kalan alttaki sayfanın
  /// ÜSTÜNDE belirir. Ölçeklenme yok ve alttaki sayfa solmaz/küçülmez: iki
  /// sayfa birden saydamlaşırsa geçişin ortasında altlarındaki üçüncü bir ekran
  /// (ör. aramanın altındaki Gelen Kutusu) bir an görünür; bu titreme, özellikle
  /// açık temada göz yorar (eski Material "fade through" geçişinin sorunu).
  fade,

  /// Modal ekranlar (Compose, Giriş ekranı gibi): alttan yukarı kayar + solar.
  modal,

  /// "Derinlik" push geçişi: yeni sayfa sağdan kayıp hafifçe büyüyerek
  /// (0.92 → 1.0) üste oturur. Altında kalacak ekranın da (Outlook/iOS'taki
  /// gibi) hafifçe küçülüp kararması isteniyorsa, o ekran
  /// [KaydetDepthCoverEffect] ile sarılmalıdır (bkz. `MailListScreen` —
  /// Gelen Kutusu, Mail Oluşturma'yı bu stille açar).
  horizontalPush,
}

/// Uygulamanın TEK sayfa geçiş noktası. `Navigator.push(MaterialPageRoute(...))`
/// yerine her yerde bu kullanılır — geçiş eğrisi/süresi tek yerden değişir,
/// ekranlar arasında sert kesme (hard cut) hiç olmaz.
class KaydetRoute<T> extends PageRouteBuilder<T> {
  KaydetRoute({
    required WidgetBuilder builder,
    this.fullscreenDialog = false,
    KaydetTransitionStyle? transitionStyle,
    super.settings,
  }) : transitionStyle =
           transitionStyle ??
           (fullscreenDialog
               ? KaydetTransitionStyle.modal
               : KaydetTransitionStyle.fade),
       super(
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
       );

  @override
  final bool fullscreenDialog;

  /// Görsel geçiş stili — verilmezse [fullscreenDialog]'dan türetilir, böylece
  /// bunu belirtmeyen mevcut çağrı yerleri davranışını korur.
  final KaydetTransitionStyle transitionStyle;

  // `horizontalPush`, diğer stillerden bağımsız kendi süresini kullanır (bkz.
  // `Motion.horizontalPush` — Outlook/iOS'un native push hızını hedefler).
  // Diğer tüm stiller `Motion.page`/`Motion.pageBack`'i kullanmaya devam eder.
  @override
  Duration get transitionDuration =>
      transitionStyle == KaydetTransitionStyle.horizontalPush
      ? Motion.horizontalPush
      : Motion.page;

  @override
  Duration get reverseTransitionDuration =>
      transitionStyle == KaydetTransitionStyle.horizontalPush
      ? Motion.horizontalPushBack
      : Motion.pageBack;

  /// [KaydetTransitionStyle.horizontalPush] ile açılan ekranın anlık giriş
  /// ilerlemesi (0 → 1). Bir route'un kendi `secondaryAnimation`'ı yalnızca
  /// KENDİSİ örtülürken tetiklenir ve onu hangi STİLİN örttüğünü bilmez; altta
  /// kalan ekranın (bkz. [KaydetDepthCoverEffect]) ne kadar küçülüp
  /// kararacağını bilebilmesi için stile özel, paylaşılan bu sinyal gerekiyor.
  ///
  /// Not: Tek seviyeli kullanım için tasarlandı — aynı anda iki
  /// `horizontalPush` ekranı üst üste açılırsa ikincisi bu sinyali ezer.
  static final ValueNotifier<double> pushProgress = ValueNotifier(0);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;

    return switch (transitionStyle) {
      KaydetTransitionStyle.modal => _modalTransition(animation, child),
      KaydetTransitionStyle.horizontalPush => _horizontalPushTransition(
        animation,
        child,
      ),
      KaydetTransitionStyle.fade => _fadeTransition(animation, child),
    };
  }

  static Widget _modalTransition(Animation<double> animation, Widget child) {
    // Compose gibi modal ekranlar alttan yukarı kayar.
    final offset = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).chain(CurveTween(curve: Motion.emphasized));
    return SlideTransition(
      position: animation.drive(offset),
      child: FadeTransition(opacity: animation, child: child),
    );
  }

  static Widget _fadeTransition(Animation<double> animation, Widget child) {
    // Yalnızca yeni sayfa solarak belirir (geri dönerken solarak kaybolur);
    // alttaki sayfaya (`secondaryAnimation`) hiç dokunulmaz. Başlangıç ve
    // bitişte yumuşak (easeInOut) — ani bir "belirme" hissi vermez.
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Motion.symmetric)),
      child: child,
    );
  }

  static Widget _horizontalPushTransition(
    Animation<double> animation,
    Widget child,
  ) {
    // Derinlik girişi: yeni sayfa sağdan kayarken aynı anda hafifçe
    // büyüyerek (0.92 → 1.0) tam boyutuna oturur (bkz. [KaydetDepthCoverEffect]
    // — altta kalan ekranın ayna görüntüsü: küçülüp kararır).
    final eased = CurvedAnimation(parent: animation, curve: Motion.standard);
    final slideIn = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(eased);
    final scaleIn = Tween<double>(begin: 0.92, end: 1).animate(eased);

    return _PushProgressReporter(
      animation: animation,
      child: SlideTransition(
        position: slideIn,
        child: ScaleTransition(scale: scaleIn, child: child),
      ),
    );
  }
}

/// [KaydetRoute.pushProgress]'i bu ekranın giriş animasyonuyla senkron tutar;
/// ekran kapanıp tamamen kaldırıldığında sinyali sıfırlar.
class _PushProgressReporter extends StatefulWidget {
  const _PushProgressReporter({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_PushProgressReporter> createState() => _PushProgressReporterState();
}

class _PushProgressReporterState extends State<_PushProgressReporter> {
  @override
  void initState() {
    super.initState();
    widget.animation.addListener(_report);
    _report();
  }

  @override
  void dispose() {
    widget.animation.removeListener(_report);
    _publish(0);
    super.dispose();
  }

  void _report() => _publish(widget.animation.value);

  /// [KaydetRoute.pushProgress]'e yazar; dinleyicisi (`KaydetDepthCoverEffect`)
  /// `setState` çağırdığı için değer, çerçevenin yapı/yerleşim aşamasında
  /// (ör. `initState`, `dispose` ağaç sökülürken) DEĞİŞTİRİLEMEZ: "setState()
  /// called during build" hatası verir. Bu aşamalarda yazma kare sonuna
  /// ertelenir.
  static void _publish(double value) {
    final notifier = KaydetRoute.pushProgress;
    if (notifier.value == value) return;

    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => notifier.value = value);
    } else {
      notifier.value = value;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Üstüne [KaydetTransitionStyle.horizontalPush] ile bir ekran açıldığında bu
/// widget'ı saran ekranı hafifçe küçültüp (1.0 → 0.94) karartır — Outlook/iOS'un
/// "derinlik" push'unda altta kalan ekranın tepkisi. Bkz. `MailListScreen` —
/// Gelen Kutusu, Mail Oluşturma açılırken bununla sarılıdır.
///
/// [child]'ın ağaçtaki yeri geçişin hiçbir anında DEĞİŞMEZ: `Transform` ve
/// `Stack` her karede (ilerleme 0 iken de) yerinde durur, yalnızca değerleri
/// değişir. Ağaç şekli ilerlemeye göre değişirse (ör. 0 iken doğrudan
/// `child`, sonrasında `Transform > Stack > child`) çerçeve [child]'ı
/// güncelleyemez, alt ağacın TAMAMINI söküp yeniden kurar: kaydırma/odak/
/// FAB durumu sıfırlanır ve sökülen ağaçtan yakalanmış her `BuildContext`
/// (ör. yazma ekranı kapanınca bildirim gösteren çağrı yeri) `mounted`
/// olmaktan çıkar.
class KaydetDepthCoverEffect extends StatelessWidget {
  const KaydetDepthCoverEffect({super.key, required this.child});

  final Widget child;

  static const _minScale = 0.94;
  static const _maxDim = 0.28;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: KaydetRoute.pushProgress,
      builder: (context, progress, child) {
        final eased = Motion.standard.transform(progress);
        final scale = 1 - (1 - _minScale) * eased;
        return Transform.scale(
          scale: scale,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Her zaman 0. sırada: karartma katmanı sona eklenip
              // çıkarılabilir, bu sıra ve dolayısıyla [child]'ın elemanı
              // etkilenmez.
              child!,
              if (progress > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: _maxDim * eased),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      child: child,
    );
  }
}

/// `context.pushScreen(...)` — tüm ekran geçişlerinin merkezi girişi.
extension KaydetNavigation on BuildContext {
  Future<T?> pushScreen<T>(
    Widget page, {
    bool fullscreenDialog = false,
    KaydetTransitionStyle? transitionStyle,
  }) => Navigator.of(this).push<T>(
    KaydetRoute<T>(
      builder: (_) => page,
      fullscreenDialog: fullscreenDialog,
      transitionStyle: transitionStyle,
    ),
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/core/theme/app_theme.dart';
import '../ui/core/theme/tokens.dart';
import '../ui/features/auth/login_screen.dart';
import '../ui/features/shell/app_shell.dart';
import '../ui/features/splash/launch_splash.dart';
import 'navigation.dart';
import 'providers.dart';

/// Uygulamanın kökü.
class KaydetApp extends ConsumerWidget {
  const KaydetApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      // Platformun verdiği başlangıç rotası (ör. iOS'ta uygulamayı uyandıran bir
      // URL) yok sayılır: uygulamanın adlandırılmış rotası yok, bilinmeyen bir
      // rota açmaya çalışmak hata verirdi (bkz. `ShareNavigator`).
      initialRoute: Navigator.defaultRouteName,
      title: 'Kaydet',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.themeMode.flutterThemeMode,
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      builder: (context, child) {
        // Sistem yazı boyutu 1.6×'ın üzerine çıkarsa liste satırları taşar;
        // erişilebilirlik korunur ama düzen kırılmaz.
        final media = MediaQuery.of(context);
        final scale = media.textScaler.scale(1);
        // Yalnızca iOS'ta yazılar biraz büyütülür (bkz. `AppText.iosTextBoost`);
        // Android'de çarpan uygulanmaz. Sınırlama çarpandan SONRA yapılır.
        final tokens = context.tokens;
        final clamped = MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.6,
          // Üst çubuğu olmayan ekranlar için varsayılan sistem çubuğu stili;
          // `AppBar` ve yan menü kendi stillerini (daha derindeki bölge)
          // verir ve bunun önüne geçer.
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: tokens.isDark
                  ? Brightness.light
                  : Brightness.dark,
              statusBarBrightness: tokens.isDark
                  ? Brightness.dark
                  : Brightness.light,
              systemNavigationBarColor: tokens.bg,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarIconBrightness: tokens.isDark
                  ? Brightness.light
                  : Brightness.dark,
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        );
        if (defaultTargetPlatform != TargetPlatform.iOS) return clamped;
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(scale * AppText.iosTextBoost),
          ),
          child: clamped,
        );
      },
      home: const _RootGate(),
    );
  }
}

/// Oturum kontrolü: hesap varsa uygulama, yoksa giriş ekranı.
///
/// Soğuk açılışta hesap hazır olsa bile marka animasyonu (bkz. `LaunchSplash`)
/// sonuna kadar oynar; hata varsa beklenmeden gösterilir.
class _RootGate extends ConsumerStatefulWidget {
  const _RootGate();

  @override
  ConsumerState<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<_RootGate> {
  static const Duration _splashDuration = Duration(milliseconds: 1500);

  bool _splashDone = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_splashDuration, () {
      if (mounted) setState(() => _splashDone = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(activeAccountProvider);
    // Sistem animasyonları kapalıysa (erişilebilirlik) animasyon beklenmez.
    final skipSplash = context.motion(_splashDuration) == Duration.zero;

    // Splash/Giriş/Ana uygulama arası eskiden anlık swap'tı — açılışta ve
    // son hesaptan çıkışta/ilk hesap eklemede "tak diye" hissediliyordu.
    // `ValueKey`'ler şart: `AnimatedSwitcher` yalnızca child'ın KEY'i
    // değiştiğinde geçiş animasyonunu tetikler.
    return AnimatedSwitcher(
      duration: context.motion(Motion.page),
      switchInCurve: Motion.standard,
      switchOutCurve: Motion.standard,
      child: account.when(
        loading: () => LaunchSplash(
          key: const ValueKey('root-splash'),
          duration: _splashDuration,
        ),
        error: (error, _) => _SplashScreen(
          key: const ValueKey('root-error'),
          error: '$error',
        ),
        // Aynı `ValueKey` korunur: hesap animasyon bitmeden gelirse
        // `LaunchSplash` yeniden kurulmaz, animasyon kesintisiz sürer.
        data: (row) => !_splashDone && !skipSplash
            ? LaunchSplash(
                key: const ValueKey('root-splash'),
                duration: _splashDuration,
              )
            : row == null
            ? const LoginScreen(key: ValueKey('root-login'))
            : const AppShell(key: ValueKey('root-shell')),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen({super.key, this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Kaydet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 28 * AppText.scale,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 24),
            if (error == null)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Uygulama başlatılamadı:\n$error',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

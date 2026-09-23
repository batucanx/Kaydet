import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/core/theme/app_theme.dart';
import '../ui/core/theme/tokens.dart';
import '../ui/features/auth/login_screen.dart';
import '../ui/features/shell/app_shell.dart';
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
        final scale = MediaQuery.textScalerOf(context).scale(1);
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: scale > 1.6 ? 1.6 : 1.6,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const _RootGate(),
    );
  }
}

/// Oturum kontrolü: hesap varsa uygulama, yoksa giriş ekranı.
class _RootGate extends ConsumerWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(activeAccountProvider);

    // Splash/Giriş/Ana uygulama arası eskiden anlık swap'tı — açılışta ve
    // son hesaptan çıkışta/ilk hesap eklemede "tak diye" hissediliyordu.
    // `ValueKey`'ler şart: `AnimatedSwitcher` yalnızca child'ın KEY'i
    // değiştiğinde geçiş animasyonunu tetikler.
    return AnimatedSwitcher(
      duration: context.motion(Motion.page),
      switchInCurve: Motion.standard,
      switchOutCurve: Motion.standard,
      child: account.when(
        loading: () => const _SplashScreen(key: ValueKey('root-splash')),
        error: (error, _) => _SplashScreen(
          key: const ValueKey('root-error'),
          error: '$error',
        ),
        data: (row) => row == null
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

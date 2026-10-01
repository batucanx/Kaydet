import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

/// Soğuk açılışta gösterilen marka animasyonu.
///
/// Yaklaşık [duration] sürer: uygulama logosu büyüyerek belirir, altındaki çizgi soldan sağa çizilir ve en sonda tüm içerik hafifçe
/// söner. Hesap yüklemesi bu sürede arka planda sürer (bkz. `_RootGate`).
class LaunchSplash extends StatefulWidget {
  const LaunchSplash({super.key, this.duration = const Duration(seconds: 3)});

  final Duration duration;

  @override
  State<LaunchSplash> createState() => _LaunchSplashState();
}

class _LaunchSplashState extends State<LaunchSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late final Animation<double> _word = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.45, curve: Motion.emphasized),
  );
  late final Animation<double> _line = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.35, 0.8, curve: Motion.standard),
  );
  late final Animation<double> _tagline = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.6, 0.9, curve: Motion.standard),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Scaffold(
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: _word.value,
                  child: Transform.scale(
                    scale: 0.88 + 0.12 * _word.value,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.xl),
                      child: Image.asset(
                        'assets/icon/app_logo.png',
                        width: 112,
                        height: 112,
                        fit: BoxFit.cover,
                        semanticLabel: 'Kaydet e-posta uygulaması logosu',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: 72,
                  height: 3,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: _line.value,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Opacity(
                  opacity: _tagline.value,
                  child: Text(
                    'Postanız, tek yerde.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      // iOS'ta uygulama genelindeki yazı çarpanı (bkz.
                      // `AppText.iosTextBoost`) burada geri alınır: iki
                      // platformda görünen boyut aynı kalır.
                      fontSize:
                          18 *
                          AppText.scale /
                          (defaultTargetPlatform == TargetPlatform.iOS
                              ? AppText.iosTextBoost
                              : 1),
                      height: 1.3,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

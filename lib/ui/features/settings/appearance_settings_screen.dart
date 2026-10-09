import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/services/app_settings.dart';
import '../../core/theme/tokens.dart';

/// Görünüm: tema seçimi. Ayrı sayfa yerine alttan açılan bir sayfa; arkadaki
/// ekran bulanık ve hafif karartılmış görünmeye devam eder. Seçim anında
/// uygulanır (tüm uygulama temasını `settingsProvider` belirler).
Future<void> showAppearanceSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (context) => const _AppearanceSheet(),
  );
}

class _AppearanceSheet extends ConsumerWidget {
  const _AppearanceSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final settings = ref.watch(settingsProvider);
    final text = Theme.of(context).textTheme;

    return Stack(
      children: [
        // Arka plan bulanıklığı: boşluğa dokunmak sayfayı kapatır.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            decoration: BoxDecoration(
              color: t.surfaceElevated,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(Radii.xl),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              Space.lg,
              Space.sm,
              Space.lg,
              Space.lg + MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: t.divider,
                      borderRadius: BorderRadius.circular(Radii.full),
                    ),
                  ),
                ),
                const SizedBox(height: Space.md),
                Text('Görünüm', style: text.titleMedium),
                const SizedBox(height: Space.lg),
                Row(
                  children: [
                    for (final mode in AppThemeMode.values) ...[
                      if (mode != AppThemeMode.values.first)
                        const SizedBox(width: Space.sm),
                      Expanded(
                        child: _ThemeCard(
                          mode: mode,
                          selected: settings.themeMode == mode,
                          onTap: () => ref
                              .read(settingsProvider.notifier)
                              .setThemeMode(mode),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.lg),
                Text(
                  'RENK PALETİ',
                  style: text.labelSmall?.copyWith(
                    color: t.textTertiary,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: Space.sm),
                Row(
                  children: [
                    _Swatch(color: t.topBar),
                    _Swatch(color: t.accentFill),
                    _Swatch(color: t.accentSubtle),
                    _Swatch(color: t.surface),
                    _Swatch(color: t.textPrimary),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 28,
      height: 28,
      margin: const EdgeInsets.only(right: Space.sm),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: t.border),
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final AppThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final label = switch (mode) {
      AppThemeMode.system => 'Sistem',
      AppThemeMode.light => 'Açık',
      AppThemeMode.dark => 'Koyu',
    };

    return Semantics(
      button: true,
      selected: selected,
      label: '${mode.label}${selected ? ', seçili' : ''}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          children: [
            AnimatedContainer(
              duration: Motion.base,
              curve: Motion.standard,
              height: 96,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md + 3),
                border: Border.all(
                  color: selected ? t.accent : t.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.md - 1),
                    child: switch (mode) {
                      AppThemeMode.light => const _MiniScreen(
                        tokens: KaydetTokens.light,
                      ),
                      AppThemeMode.dark => const _MiniScreen(
                        tokens: KaydetTokens.dark,
                      ),
                      AppThemeMode.system => const _SplitMiniScreen(),
                    },
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: AnimatedScale(
                      scale: selected ? 1 : 0,
                      duration: Motion.base,
                      curve: Motion.standard,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: t.accentFill,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          LucideIcons.check,
                          size: 13,
                          color: t.onAccentFill,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
            Text(
              label,
              style: text.labelLarge?.copyWith(
                color: selected ? t.accent : t.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Yarısı açık, yarısı koyu önizleme ("Sistem").
class _SplitMiniScreen extends StatelessWidget {
  const _SplitMiniScreen();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _MiniScreen(tokens: KaydetTokens.dark),
        ClipRect(
          clipper: _LeftHalfClipper(),
          child: const _MiniScreen(tokens: KaydetTokens.light),
        ),
      ],
    );
  }
}

class _LeftHalfClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}

/// Seçilen temanın token'larıyla çizilen küçük ekran maketi.
class _MiniScreen extends StatelessWidget {
  const _MiniScreen({required this.tokens});

  final KaydetTokens tokens;

  @override
  Widget build(BuildContext context) {
    Widget line(double widthFactor, Color color) => Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: 4,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(Radii.full),
          ),
        ),
      ),
    );

    return ColoredBox(
      color: tokens.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 22,
            color: tokens.topBar,
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 28,
              child: line(1, tokens.onAccentFill.withValues(alpha: 0.85)),
            ),
          ),
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.sm,
                Space.sm,
                Space.sm,
                0,
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: i == 0 ? tokens.accentFill : tokens.surface,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      children: [
                        line(0.8, tokens.textSecondary),
                        const SizedBox(height: 3),
                        line(0.5, tokens.textTertiary),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

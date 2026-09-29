import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/services/app_settings.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/swipe_action_style.dart';

/// Çekme seçenekleri: sağa ve sola kaydırma eylemlerini seçer. Seçim genel
/// varsayılandır; klasöre göre uyarlama `SwipeActionResolver`da yapılır.
class SwipeSettingsScreen extends ConsumerWidget {
  const SwipeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Çekme seçenekleri'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Text(
              'Gelen kutunuzdaki e-postalar üzerinde hızlıca işlem yapmak için '
              'çekme seçeneklerini özelleştirin.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
            ),
          ),
          Divider(height: 1, color: t.divider),
          _SwipeSection(
            title: 'Sağa çekme',
            action: settings.swipeRight,
            fromLeft: true,
            onChange: () => _pick(context, settings.swipeRight, (a) {
              notifier.setSwipeRight(a);
            }),
          ),
          Divider(height: 1, color: t.divider),
          _SwipeSection(
            title: 'Sola çekme',
            action: settings.swipeLeft,
            fromLeft: false,
            onChange: () => _pick(context, settings.swipeLeft, (a) {
              notifier.setSwipeLeft(a);
            }),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Text(
              'Arşiv, Çöp Kutusu ve İstenmeyen klasörlerinde "Arşivle" '
              'eylemi otomatik olarak "Gelen Kutusuna taşı" olur.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: t.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// Eylem seçim listesi — kısa liste olduğu için tam ekran değil, içeriği
  /// kadar yüksek bir alt sayfa.
  Future<void> _pick(
    BuildContext context,
    SwipeAction current,
    ValueChanged<SwipeAction> onSelected,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: AnimationStyle(
        duration: context.motion(Motion.base),
        reverseDuration: context.motion(Motion.fast),
        curve: Motion.standard,
      ),
      builder: (sheetContext) {
        final t = sheetContext.tokens;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: Space.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final action in SwipeAction.values)
                  if (action != SwipeAction.configure)
                  ListTile(
                    leading: Icon(
                      SwipeStyle.forSelection(action, t)?.icon ??
                          LucideIcons.ban,
                      color: t.textSecondary,
                    ),
                    title: Text(action.label),
                    trailing: action == current
                        ? Icon(LucideIcons.check, color: t.accent)
                        : null,
                    onTap: () {
                      onSelected(action);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SwipeSection extends StatelessWidget {
  const _SwipeSection({
    required this.title,
    required this.action,
    required this.fromLeft,
    required this.onChange,
  });

  final String title;
  final SwipeAction action;

  /// Sağa çekme: eylem alanı SOLDAN açılır; sola çekmede sağdan.
  final bool fromLeft;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      action.label,
                      style: textTheme.bodyMedium?.copyWith(
                        color: t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: onChange, child: const Text('Değiştir')),
            ],
          ),
          const SizedBox(height: Space.lg),
          SwipePreview(action: action, fromLeft: fromLeft),
        ],
      ),
    );
  }
}

/// Kaydırmayı anlatan küçük illüstrasyon: bir mail satırı yana kayar ve
/// seçilen eylemin alanı (gerçek listedeki [SwipeStyle] ile aynı renk/simge/
/// etiket) ortaya çıkar. Seçim değişince anında güncellenir. "Yok" için
/// satır kımıldamaz. Sistem "animasyonları azalt" ayarında hareket yerine
/// eylem alanı açık halde durur.
class SwipePreview extends StatefulWidget {
  const SwipePreview({super.key, required this.action, required this.fromLeft});

  final SwipeAction action;
  final bool fromLeft;

  @override
  State<SwipePreview> createState() => _SwipePreviewState();
}

class _SwipePreviewState extends State<SwipePreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  static final _sequence = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 30),
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 25,
    ),
    TweenSequenceItem(tween: ConstantTween(0.0), weight: 10),
  ]);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = context.motion(Motion.base) == Duration.zero;
    if (_reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = SwipeStyle.forSelection(widget.action, t);

    Widget skeleton({required bool avatarFirst}) {
      Widget line(double factor) => FractionallySizedBox(
        widthFactor: factor,
        alignment: Alignment.centerLeft,
        child: Container(
          height: 8,
          decoration: BoxDecoration(
            color: t.surfaceElevated,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: t.surfaceElevated,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  line(0.55),
                  const SizedBox(height: Space.sm),
                  line(0.9),
                  const SizedBox(height: Space.sm),
                  line(0.7),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          height: 96,
          child: LayoutBuilder(
            builder: (context, box) {
              final travel = box.maxWidth * 0.45;
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final moving = style != null;
                  final progress = !moving
                      ? 0.0
                      : (_reduceMotion ? 1.0 : _sequence.evaluate(_controller));
                  final dx = (widget.fromLeft ? 1 : -1) * travel * progress;
                  return Stack(
                    children: [
                      if (style != null)
                        Positioned.fill(
                          child: Align(
                            alignment: widget.fromLeft
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: Container(
                              width: travel + 1,
                              color: style.color,
                              padding: const EdgeInsets.symmetric(
                                horizontal: Space.lg,
                              ),
                              alignment: widget.fromLeft
                                  ? Alignment.centerLeft
                                  : Alignment.centerRight,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    style.icon,
                                    size: IconSize.lg,
                                    color: style.foreground,
                                  ),
                                  const SizedBox(height: Space.xs),
                                  Text(
                                    style.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: style.foreground,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Transform.translate(
                        offset: Offset(dx, 0),
                        child: Container(
                          color: t.surface,
                          alignment: Alignment.center,
                          child: skeleton(avatarFirst: true),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

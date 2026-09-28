import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Kullanıcının, ekli görsel(ler) için verdiği boyut kararı.
enum ImageSizeChoice { reduced, original }

/// İletiye görsel eklenirken sorulan boyut tercihi — gerçek Outlook/Gmail
/// davranışı: küçültme gönderim boyutunu belirgin biçimde azaltır, özgün
/// boyut orijinal çözünürlüğü/kaliteyi korur. Sayfa kapatılırsa (geri tuşu,
/// dışına dokunma) `null` döner; çağıran taraf bunu "özgün boyutu koru" ile
/// aynı kabul eder — hiçbir ek kaybolmaz.
Future<ImageSizeChoice?> showImageSizePrompt(
  BuildContext context, {
  required int imageCount,
}) => showModalBottomSheet<ImageSizeChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  sheetAnimationStyle: AnimationStyle(
    duration: context.motion(Motion.base),
    reverseDuration: context.motion(Motion.fast),
    curve: Motion.standard,
  ),
  builder: (_) => _ImageSizePromptSheet(imageCount: imageCount),
);

class _ImageSizePromptSheet extends StatelessWidget {
  const _ImageSizePromptSheet({required this.imageCount});

  final int imageCount;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Space.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: Text(
              imageCount > 1
                  ? 'Bu iletideki görüntülerin boyutunu küçültmek ister misiniz?'
                  : 'Bu iletideki görüntünün boyutunu küçültmek ister misiniz?',
              style: AppText.titleMedium.copyWith(color: t.textPrimary),
            ),
          ),
          const SizedBox(height: Space.md),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.imageDown,
                title: 'Resim boyutunu küçült',
                subtitle: 'Daha hızlı gönderilir, kalite az düşer',
                onTap: () =>
                    Navigator.of(context).pop(ImageSizeChoice.reduced),
              ),
              SettingsTile(
                icon: LucideIcons.image,
                title: 'Özgün boyutu koru',
                onTap: () =>
                    Navigator.of(context).pop(ImageSizeChoice.original),
              ),
            ],
          ),
          const SizedBox(height: Space.lg),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/translation_providers.dart';
import '../../../data/database/app_database.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';

/// Okuma ekranındaki çeviri DURUM çubuğu.
///
/// - Çeviriyi BAŞLATAN denetim burada değil, alt çubuktaki "..." menüsündedir
///   (bkz. `_MoreMenu`): her iletide görünen bir düğme olmasın diye. Açılışta
///   HİÇBİR ağ isteği yapılmaz (dil algılama dahil); istek yalnızca menüden
///   istenince, orijinal gövdenin TAMAMIyla gider.
/// - Çubuk yalnızca çeviri sürerken (`Çevriliyor...`) ve bitince
///   (`Türkçe gösteriliyor · [Orijinali göster]`) görünür; başlangıç
///   durumunda hiçbir şey çizmez ama hata/limit bildirimlerini dinlemeyi
///   sürdürür.
/// - Orijinale dönmek ağa çıkmaz: orijinal gövde zaten yerelde durur, yalnızca
///   gösterim durumu değişir.
///
/// Kullanıcıya yalnızca sade durum ve hata iletileri gösterilir (teknik
/// ayrıntı asla); renkler tema belirteçlerinden gelir (açık/koyu tema).
class TranslateBar extends ConsumerWidget {
  const TranslateBar({
    super.key,
    required this.messageId,
    required this.body,
    this.noticeBottomInset = 0,
  });

  final int messageId;

  /// ORİJİNAL gövde (çevrilmiş değil) — yalnızca çevrilecek metin var mı diye
  /// bakılır.
  final MessageBodyRow? body;

  /// Bildirimin kapatmaması gereken alt yükseklik (alt eylem çubuğu).
  final double noticeBottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final provider = translationControllerProvider(messageId);
    final state = ref.watch(provider);

    ref.listen(provider, (previous, next) {
      final failure = next.failure;
      String? message;
      if (failure != null && failure != previous?.failure) {
        message = failure.userMessage;
      } else if (next.phase == TranslationPhase.shown &&
          previous?.phase != TranslationPhase.shown &&
          (next.translation?.nearLimit ?? false)) {
        message = 'Bu ayki çeviri kullanım limitine yaklaşıldı.';
      }
      if (message == null) return;
      final overlay = Overlay.of(context, rootOverlay: true);
      if (!overlay.mounted) return;
      KaydetNotice.show(
        overlay,
        message: message,
        bottomInset: noticeBottomInset,
      );
    });

    final hasText =
        (body?.html?.trim().isNotEmpty ?? false) ||
        (body?.plainText?.trim().isNotEmpty ?? false);
    if (!hasText) return const SizedBox.shrink();

    final controller = ref.read(provider.notifier);
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: t.textSecondary);

    final Widget content = switch (state.phase) {
      TranslationPhase.loading => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: t.textSecondary,
            ),
          ),
          const SizedBox(width: Space.sm),
          Text('Çevriliyor...', style: labelStyle),
        ],
      ),
      TranslationPhase.shown => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(LucideIcons.languages, size: IconSize.sm, color: t.accent),
          const SizedBox(width: Space.sm),
          Text('Türkçe gösteriliyor · ', style: labelStyle),
          _LinkButton(
            label: 'Orijinali göster',
            onPressed: controller.showOriginal,
          ),
        ],
      ),
      TranslationPhase.idle => const SizedBox.shrink(),
    };
    if (state.phase == TranslationPhase.idle) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Align(alignment: Alignment.centerLeft, child: content),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: t.accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

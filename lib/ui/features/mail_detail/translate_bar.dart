import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/translation_providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/use_cases/language_names.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';

/// Okuma ekranındaki çeviri denetimi.
///
/// - Kaynak dil Türkçe ise HİÇBİR ŞEY göstermez.
/// - Değilse: `🌐 İngilizce   [Türkçeye Çevir]`; çeviri sürerken
///   `Çevriliyor...`; bitince `Türkçe gösteriliyor · [Orijinali göster]`.
/// - Orijinale dönmek ağa çıkmaz: orijinal gövde zaten yerelde durur, yalnızca
///   gösterim durumu değişir.
///
/// Kullanıcıya yalnızca sade durum ve hata iletileri gösterilir (teknik
/// ayrıntı asla); renkler tema belirteçlerinden gelir (açık/koyu tema).
class TranslateBar extends ConsumerWidget {
  const TranslateBar({
    super.key,
    required this.messageId,
    required this.subject,
    required this.body,
    this.noticeBottomInset = 0,
  });

  final int messageId;
  final String subject;

  /// ORİJİNAL gövde (çevrilmiş değil) — istek bundan kurulur.
  final MessageBodyRow? body;

  /// Bildirimin kapatmaması gereken alt yükseklik (alt eylem çubuğu).
  final double noticeBottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final provider = translationControllerProvider(messageId);
    final state = ref.watch(provider);
    final languageAsync = ref.watch(messageLanguageProvider(messageId));

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

    final shown = state.phase == TranslationPhase.shown;
    final language = languageAsync.value;

    // Türkçe ileti: çeviri arayüzü yok (çeviri gösteriliyorsa yine de
    // "Orijinali göster" kaybolmasın).
    if (!shown && isTurkish(language)) return const SizedBox.shrink();
    // Dil algılanırken (kısa süre) yer tutulmaz; Türkçe iletide düğmenin
    // yanıp sönmesini önler.
    if (!shown && languageAsync.isLoading) return const SizedBox.shrink();

    final controller = ref.read(provider.notifier);
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: t.textSecondary);
    final languageName = languageDisplayName(language);

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
      TranslationPhase.idle => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            LucideIcons.languages,
            size: IconSize.sm,
            color: t.textSecondary,
          ),
          const SizedBox(width: Space.sm),
          if (languageName != null) ...[
            Text(languageName, style: labelStyle),
            Text(' · ', style: labelStyle),
          ],
          _LinkButton(
            label: 'Türkçeye Çevir',
            onPressed: () => unawaited(
              controller.translate(
                subject: subject,
                html: body?.html,
                plainText: body?.plainText,
                sourceLanguage: language ?? 'auto',
              ),
            ),
          ),
        ],
      ),
    };

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

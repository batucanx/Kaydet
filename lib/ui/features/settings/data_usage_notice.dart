import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/tokens.dart';

/// Verilerin nerede tutulduğunu ve hangi durumlarda sunucuya gittiğini
/// anlatan metinler. Giriş ekranındaki kısa not ve Gizlilik sayfasındaki
/// ayrıntılı bilgi AYNI kaynaktan beslenir; biri değişince diğeri sapmaz.
///
/// [pushServerActive]: iOS'ta sunucu tabanlı anlık bildirim yapılandırılmış mı
/// (bkz. `remotePushSyncProvider`). Şifre sunucuya YALNIZCA bu durumda gider.
abstract final class DataUsageText {
  static String loginNote({required bool pushServerActive}) => pushServerActive
      ? 'Şifreniz bu cihazda güvenli depoda saklanır. Anlık bildirim için '
            'şifreniz ve sunucu bilgileriniz şifrelenerek bildirim '
            'sunucusuna da gönderilir. Ayrıntı: Ayarlar › Gizlilik.'
      : 'Şifreniz yalnızca bu cihazda, güvenli depoda saklanır. '
            'Ayrıntı: Ayarlar › Gizlilik.';

  static List<({String title, String body})> sections({
    required bool pushServerActive,
  }) => [
    (
      title: 'Bu cihazda',
      body:
          'İletileriniz ve ekleriniz cihazdaki veritabanında önbelleklenir; '
          'asıl kopya mail sunucunuzda kalır. Şifreniz iOS Anahtar Zinciri / '
          'Android Keystore içinde saklanır, veritabanına ya da günlüklere '
          'yazılmaz. Uygulama, iletilerinizi mail sunucunuzla doğrudan IMAP ve '
          'SMTP üzerinden alıp gönderir.',
    ),
    if (pushServerActive)
      (
        title: 'Anlık bildirim sunucusu (iOS)',
        body:
            'iPhone\'a yeni ileti bildirimi gönderilebilmesi için hesabınızın '
            'şifresi, kullanıcı adı ve IMAP sunucu bilgileri Kaydet bildirim '
            'sunucusuna iletilir. Şifre sunucuda şifrelenmiş olarak saklanır '
            've sunucu, gelen kutunuzu izleyerek yalnızca yeni iletinin '
            'göndereni ile konusunu okur; ileti gövdesi ve ekler indirilmez. '
            'Bu iki bilgi, bildirimi iletmek için Apple\'ın bildirim '
            'servisinden (APNs) geçer.\n\n'
            'Bildirimleri kapattığınızda ya da hesabı çıkardığınızda hesabınız '
            'sunucudan silinir. Bu uygulamayı kullanmaya devam ederek bu '
            'işlemeyi kabul etmiş olursunuz.',
      ),
    (
      title: 'Çeviri',
      body:
          'Bir iletiyi açtığınızda dilini algılamak için iletinin kısa bir '
          'metin örneği, "Türkçeye Çevir"i kullandığınızda ise iletinin metni '
          'çeviri sunucusuna ve oradan Microsoft Azure Translator\'a '
          'gönderilir. Mail adresleriniz ve şifreniz gönderilmez. Çeviri '
          'sunucusu yapılandırılmamışsa hiçbir şey gönderilmez.',
    ),
    (
      title: 'Gönderen logoları',
      body:
          'Gizlilik sayfasındaki "Gönderen logoları" açıkken gönderenlerin '
          'alan adları Google\'ın favicon servisine iletilir. Kapalıyken '
          'hiçbir dış servise iletilmez.',
    ),
  ];
}

/// Giriş ekranında şifre alanının altında görünen kısa not.
class DataUsageNote extends StatelessWidget {
  const DataUsageNote({super.key, required this.pushServerActive});

  final bool pushServerActive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.shieldCheck, size: 16, color: t.textTertiary),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            DataUsageText.loginNote(pushServerActive: pushServerActive),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: t.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Gizlilik sayfasındaki ayrıntılı açıklama.
class DataUsageDetails extends StatelessWidget {
  const DataUsageDetails({super.key, required this.pushServerActive});

  final bool pushServerActive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final section in DataUsageText.sections(
            pushServerActive: pushServerActive,
          )) ...[
            Text(section.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: Space.xs),
            Text(
              section.body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: t.textSecondary,
              ),
            ),
            const SizedBox(height: Space.lg),
          ],
        ],
      ),
    );
  }
}

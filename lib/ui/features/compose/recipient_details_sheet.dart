import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Yazma ekranındaki bir alıcı çipine dokunulunca açılan kişi ayrıntıları.
///
/// Görünüm uygulama temasından gelir (`AppTheme`in `bottomSheetTheme`i:
/// zemin, köşe yarıçapı, tutamaç); açılış/kapanış hızı `Motion` token'larıyla,
/// sistemin "animasyonları azalt" ayarına saygılı (bkz. `BuildContext.motion`).
///
/// [accountId], kişinin "Kişilere Ekle" ile hangi hesabın kişi defterine
/// gireceğidir — yazma ekranında seçili "Gönderen" hesap.
Future<void> showRecipientDetails(
  BuildContext context, {
  required EmailAddress address,
  required int? accountId,
}) => showModalBottomSheet<void>(
  context: context,
  // İçerik kısa; ama büyük yazı ölçeğinde ya da yatay ekranda taşarsa
  // kaydırılır (bkz. `RecipientDetailsSheet`). Tam kontrollü yükseklik,
  // varsayılan 9/16 tavanını kaldırıp güvenli alana göre sınırlar.
  isScrollControlled: true,
  useSafeArea: true,
  sheetAnimationStyle: AnimationStyle(
    duration: context.motion(Motion.base),
    reverseDuration: context.motion(Motion.fast),
    curve: Motion.standard,
  ),
  builder: (_) => RecipientDetailsSheet(address: address, accountId: accountId),
);

/// Alıcının avatarı, adı, e-posta adresi ve — adres henüz kişi defterinde
/// değilse — "Kişilere Ekle" eylemi.
///
/// Yalnızca sistemde gerçekten bulunan veri gösterilir: kişi modeli (bkz.
/// `Contacts` tablosu) ad ve e-posta dışında bir alan (telefon, şirket, soyad)
/// taşımaz, bu yüzden burada da yoktur.
class RecipientDetailsSheet extends ConsumerStatefulWidget {
  const RecipientDetailsSheet({
    super.key,
    required this.address,
    required this.accountId,
  });

  final EmailAddress address;
  final int? accountId;

  @override
  ConsumerState<RecipientDetailsSheet> createState() =>
      _RecipientDetailsSheetState();
}

class _RecipientDetailsSheetState extends ConsumerState<RecipientDetailsSheet> {
  bool _adding = false;

  Future<void> _addToContacts() async {
    final accountId = widget.accountId;
    if (accountId == null || _adding) return;
    setState(() => _adding = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .createContact(
            accountId: accountId,
            email: widget.address.email.trim(),
            name: widget.address.name?.trim() ?? '',
          );
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final address = widget.address;
    final accountId = widget.accountId;

    // Kişi defteri canlı izlenir: "Kişilere Ekle"ye basınca akış güncellenir
    // ve eylem "kayıtlı" durumuna kendiliğinden döner.
    final contacts = accountId == null
        ? const <ContactRow>[]
        : ref.watch(contactsForAccountProvider(accountId)).value ??
              const <ContactRow>[];
    final email = address.email.trim().toLowerCase();
    final isSaved = contacts.any((c) => c.email.toLowerCase() == email);
    final valid = address.isValid;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Space.sm),
            Center(
              child: BrandAvatar(
                name: address.name,
                email: address.email,
                size: 72,
              ),
            ),
            const SizedBox(height: Space.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl),
              child: Text(
                address.display,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppText.titleLarge.copyWith(color: t.textPrimary),
              ),
            ),
            const SectionHeader('KİŞİ'),
            SettingsGroup(
              children: [
                // Uzun adres kısaltılmaz: bu satırın asıl amacı adresin tamamını
                // göstermektir (bkz. `SettingsTile` — başlık sarılır).
                SettingsTile(
                  icon: LucideIcons.mail,
                  title: address.email,
                  subtitle: valid ? 'E-posta' : 'Geçersiz e-posta adresi',
                ),
                if (valid && accountId != null && isSaved)
                  const SettingsTile(
                    icon: LucideIcons.userCheck,
                    title: 'Kişilerinizde kayıtlı',
                  ),
              ],
            ),
            if (valid && accountId != null && !isSaved)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.lg,
                  Space.lg,
                  0,
                ),
                child: FilledButton.icon(
                  onPressed: _adding ? null : _addToContacts,
                  icon: const Icon(LucideIcons.userPlus, size: IconSize.md),
                  label: const Text('Kişilere Ekle'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

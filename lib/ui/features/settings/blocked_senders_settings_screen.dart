import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../data/repositories/blocked_sender_repository.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Engellenen kullanıcılar alt sayfası: liste, adresle engelleme ve engeli kaldırma.
///
/// Bu adreslerden gelen iletiler Gelen Kutusu'na düşmez, sunucuda İstenmeyen klasörüne taşınır;
/// liste web ve diğer cihazlarla eşit tutulur.
class BlockedSendersSettingsScreen extends ConsumerWidget {
  const BlockedSendersSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final blocked =
        ref.watch(blockedSendersProvider).value ?? const <BlockedSenderRow>[];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Engellenen kullanıcılar'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          SectionHeader(
            'ENGELLENENLER',
            trailing: IconButton(
              icon: const Icon(LucideIcons.plus, size: IconSize.md),
              tooltip: 'Kullanıcı engelle',
              onPressed: () => _block(context, ref),
            ),
          ),
          if (blocked.isEmpty)
            SettingsGroup(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Text(
                    'Engellenen kullanıcı yok.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
                  ),
                ),
              ],
            )
          else
            for (final sender in blocked)
              Container(
                margin: const EdgeInsets.symmetric(
                  horizontal: Space.lg,
                  vertical: Space.xs,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: t.danger, width: 1.5),
                ),
                child: ListTile(
                  leading: Icon(
                    LucideIcons.ban,
                    size: IconSize.md,
                    color: t.danger,
                  ),
                  title: Text(
                    sender.name.isEmpty ? sender.email : sender.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  subtitle: sender.name.isEmpty
                      ? null
                      : Text(
                          sender.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontSize: 12, color: t.textSecondary),
                        ),
                  trailing: TextButton(
                    onPressed: () => _unblock(context, ref, sender),
                    child: Text(
                      'Engeli kaldır',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: t.danger,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _block(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kullanıcı engelle'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(hintText: 'ornek@alanadi.com'),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(false),
            confirmLabel: 'Engelle',
            onConfirm: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    final email = controller.text.trim();
    controller.dispose();
    if (confirmed != true || email.isEmpty || !context.mounted) return;

    final result = await ref
        .read(blockedSenderRepositoryProvider)
        .block(accountId: accountId, email: email);
    if (!context.mounted) return;
    KaydetNotice.show(
      Overlay.of(context),
      message: switch (result.outcome) {
        BlockOutcome.blocked => '$email engellendi.',
        BlockOutcome.alreadyBlocked => '$email zaten engelli.',
        BlockOutcome.invalidAddress => 'Geçerli bir e-posta adresi girin.',
        BlockOutcome.ownAddress => 'Kendi adresinizi engelleyemezsiniz.',
      },
    );
  }

  Future<void> _unblock(
    BuildContext context,
    WidgetRef ref,
    BlockedSenderRow sender,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Engel kaldırılsın mı?'),
        content: Text(
          '${sender.email} adresinden gelen iletiler yeniden gelen kutusuna '
          'düşecek; bu adresten İstenmeyen klasöründe bulunan iletiler de '
          'gelen kutusuna taşınacak.',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(false),
            confirmLabel: 'Engeli kaldır',
            onConfirm: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(blockedSenderRepositoryProvider).unblock(sender.id);
    if (!context.mounted) return;
    KaydetNotice.show(
      Overlay.of(context),
      message: '${sender.email} için engel kaldırıldı.',
    );
  }
}

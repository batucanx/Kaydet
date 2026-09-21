import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../auth/login_screen.dart';

/// Hesaplar alt sayfası: hesap listesi, hesap ekleme/kaldırma, etkin
/// hesabın görünen adı ve etkin hesaptan çıkış.
class AccountsSettingsScreen extends ConsumerWidget {
  const AccountsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final account = ref.watch(activeAccountProvider).value;
    final allAccounts =
        ref.watch(allAccountsProvider).value ?? const <AccountRow>[];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Hesaplar'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          SectionHeader(
            'HESAPLAR',
            trailing: IconButton(
              icon: const Icon(LucideIcons.userPlus, size: IconSize.md),
              tooltip: 'Hesap ekle',
              onPressed: () => _addAccount(context),
            ),
          ),
          SettingsGroup(
            children: [
              for (final row in allAccounts)
                _AccountListTile(
                  account: row,
                  isActive: row.id == account?.id,
                  onSwitch: () =>
                      ref.read(accountRepositoryProvider).switchAccount(row.id),
                  onRemove: () => _removeAccount(context, ref, row),
                ),
              if (allAccounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Space.lg),
                  child: Text('Henüz hesap yok.'),
                ),
            ],
          ),

          const SectionHeader('ETKİN HESAP'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.userRound,
                title: 'Görünen ad',
                subtitle: account?.displayName,
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: account == null
                    ? null
                    : () => _editDisplayName(context, ref, account),
              ),
            ],
          ),

          const SizedBox(height: Space.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: OutlinedButton.icon(
              onPressed: account == null
                  ? null
                  : () => _removeAccount(context, ref, account),
              icon: Icon(
                LucideIcons.logOut,
                size: IconSize.md,
                color: t.danger,
              ),
              label: Text(
                'Hesaptan çıkış yap',
                style: TextStyle(color: t.danger),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: t.danger.withValues(alpha: 0.4)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editDisplayName(
    BuildContext context,
    WidgetRef ref,
    AccountRow account,
  ) async {
    final controller = TextEditingController(text: account.displayName);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Görünen ad'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ad Soyad'),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(),
            confirmLabel: 'Kaydet',
            onConfirm: () => Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await ref
        .read(accountRepositoryProvider)
        .updateDisplayName(account.id, value);
  }

  /// "Hesap ekle" akışını açar — mevcut hesap(lar) dokunulmadan kalır.
  void _addAccount(BuildContext context) {
    context.pushScreen(const LoginScreen(isAddingAccount: true));
  }

  /// Bir hesabı cihazdan kaldırır: şifre ve tüm yerel verisi silinir.
  ///
  /// [target] o an etkin değilse (hesap listesinden doğrudan silme) ekran
  /// değişmez — sadece o hesap listeden kaybolur, diğer hesabın açık
  /// oturumuna dokunulmaz. [target] etkinse (alttaki "Hesaptan çıkış yap"
  /// düğmesi ya da listedeki etkin satır) tam çıkış akışı işler: ekran
  /// kilitlenir, bağlantı kapanır, kök ekrana dönülür.
  Future<void> _removeAccount(
    BuildContext context,
    WidgetRef ref,
    AccountRow target,
  ) async {
    final removingActiveAccount = target.isActive;
    final confirmed = await confirmDialog(
      context,
      title: 'Çıkış yap',
      message: removingActiveAccount
          ? 'Bu cihazdaki tüm yerel iletiler ve kayıtlı şifre silinecek. '
                'Sunucudaki iletileriniz etkilenmez.'
          : '${target.email} hesabı ve bu cihazdaki tüm yerel iletileri '
                'silinecek. Sunucudaki iletileriniz etkilenmez.',
      confirmLabel: 'Çıkış yap',
      destructive: true,
    );
    if (confirmed != true || !context.mounted) return;

    final container = ProviderScope.containerOf(context, listen: false);

    if (!removingActiveAccount) {
      // Etkin olmayan bir hesap siliniyor: bu ekrandan hiç ayrılmayız,
      // hesap listesi `allAccountsProvider` akışıyla kendiliğinden güncellenir.
      try {
        await container.read(accountRepositoryProvider).signOut(target.id);
      } on Object catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Hesap silinemedi: $error')));
        }
      }
      return;
    }

    // Etkin hesap siliniyor: bu işlem sırasında ekran ağaçtan kalkabilir;
    // `context`'e bağlı her şey önceden alınır.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Sunucu yanıtı beklenirken ekran kilitlenir: düğmeye ikinci kez
    // basılırsa aynı hesap iki kez silinmeye çalışılır.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SignOutProgress(),
    );

    try {
      await container.read(accountRepositoryProvider).signOut(target.id);
    } on Object catch (error) {
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Çıkış yapılamadı: $error')),
      );
      return;
    }

    // Bu sayfa her zaman `context.pushScreen` ile açılır (bkz.
    // `SettingsScreen`'deki "Hesaplar" satırı): kök ekrana dönülünce hem bu
    // sayfa hem üstündeki ilerleme diyaloğu birlikte kapanır. Kalan hesap
    // varsa repository onu otomatik etkinleştirmiştir ve kök AppShell'i
    // (Ayarlar sekmesinde) gösterir; kalan hesap yoksa Giriş ekranını
    // gösterir.
    navigator.popUntil((route) => route.isFirst);

    // Sonraki girişte eski klasör seçimi ve seçim modu kalmasın. Arama
    // ekranının kendi durumu zaten `autoDispose` (bkz.
    // `app/search_providers.dart`), burada ayrıca sıfırlamaya gerek yok.
    container.invalidate(selectedFolderRawProvider);
    container.invalidate(selectionProvider);
    container.invalidate(pageLimitProvider);
  }
}

/// Hesap değiştirici listesindeki tek satır.
///
/// Dokunma satırı etkinleştirir (etkinse dokunma etkisizdir); ayrı bir
/// simge o hesabı cihazdan kaldırır. eM Client'ın hesap listesindeki gibi:
/// hesaplar arası geçiş ile hesabı kaldırma iki ayrı eylemdir.
class _AccountListTile extends StatelessWidget {
  const _AccountListTile({
    required this.account,
    required this.isActive,
    required this.onSwitch,
    required this.onRemove,
  });

  final AccountRow account;
  final bool isActive;
  final VoidCallback onSwitch;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: isActive ? null : onSwitch,
      child: Container(
        constraints: const BoxConstraints(minHeight: Dimens.touchTarget + 8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            BrandAvatar(
              name: account.displayName,
              email: account.email,
              isSelected: isActive,
              size: 32,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    account.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${account.imapHost}:${account.imapPort} · '
                    '${_securityLabel(account.imapSecurity)}'
                    '${isActive ? ' · Etkin' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isActive ? t.accent : t.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                LucideIcons.trash2,
                size: IconSize.sm,
                color: t.danger,
              ),
              tooltip: 'Hesabı kaldır',
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

String _securityLabel(SocketSecurity security) => switch (security) {
  SocketSecurity.ssl => 'SSL/TLS',
  SocketSecurity.startTls => 'STARTTLS',
  SocketSecurity.none => 'Güvenlik yok',
};

/// Çıkış tamamlanana kadar ekranı kilitleyen ilerleme diyaloğu.
///
/// Geri tuşuyla kapatılamaz: yarıda kesilen çıkış, şifresi silinmiş ama
/// kaydı duran bir hesap bırakır.
class _SignOutProgress extends StatelessWidget {
  const _SignOutProgress();

  @override
  Widget build(BuildContext context) => const PopScope(
    canPop: false,
    child: AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: Space.lg),
          Flexible(child: Text('Çıkış yapılıyor…')),
        ],
      ),
    ),
  );
}

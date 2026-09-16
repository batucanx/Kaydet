import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../data/services/app_settings.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../auth/login_screen.dart';

/// Ayarlar ekranı.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final settings = ref.watch(settingsProvider);
    final account = ref.watch(activeAccountProvider).value;
    final allAccounts =
        ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    final sync = ref.watch(syncControllerProvider);

    return Scaffold(
      appBar: AppBar(
        // Bu ekranın kendi `Scaffold`u `AppShell`'in klasör/modül menüsünü
        // taşımaz; menü butonu Flutter'ın otomatik `leading`iyle gelmez,
        // elle eklenir (bkz. `mail_list_screen.dart`daki aynı desen).
        leading: IconButton(
          icon: const Icon(LucideIcons.menu),
          tooltip: 'Menü',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: const Text('Ayarlar'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          // ----------------------------------------------------- hesaplar
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

          // --------------------------------------------------- etkin hesap
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
              SettingsTile(
                icon: LucideIcons.penLine,
                title: 'İmza',
                subtitle: (account?.signature ?? '').trim().isEmpty
                    ? 'Tanımlı değil'
                    : account!.signature!.trim().split('\n').first,
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: account == null
                    ? null
                    : () => _editSignature(context, ref, account),
              ),
            ],
          ),

          // ---------------------------------------------------- görünüm
          const SectionHeader('GÖRÜNÜM'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.palette,
                title: 'Tema',
                subtitle: switch (settings.themeMode) {
                  ThemeMode.dark => 'Koyu',
                  ThemeMode.light => 'Açık',
                  ThemeMode.system => 'Sistem ayarı',
                },
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () => _pickTheme(context, ref, settings.themeMode),
              ),
            ],
          ),

          // --------------------------------------------------- etiketler
          SectionHeader(
            'ETİKETLER',
            trailing: IconButton(
              icon: const Icon(LucideIcons.plus, size: IconSize.md),
              tooltip: 'Etiket ekle',
              onPressed: () => _createLabel(context, ref),
            ),
          ),
          SettingsGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: labels.isEmpty
                    ? Text(
                        'Henüz etiket yok.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
                      )
                    : Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.sm,
                        children: [
                          for (final label in labels)
                            LabelChip(
                              name: label.name,
                              toneIndex: label.toneIndex,
                              onDeleted: () => ref
                                  .read(accountRepositoryProvider)
                                  .deleteLabel(label.id),
                            ),
                        ],
                      ),
              ),
              if (account?.supportsKeywords == false)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    0,
                    Space.lg,
                    Space.lg,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.info,
                        size: IconSize.sm,
                        color: t.textTertiary,
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          'Sunucunuz özel etiketleri desteklemiyor; etiketler '
                          'yalnızca bu cihazda görünür.',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: t.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),

          // ------------------------------------- bildirim & senkronizasyon
          const SectionHeader('BİLDİRİM VE SENKRONİZASYON'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.bell,
                title: 'Bildirimler',
                subtitle: 'Yeni ileti geldiğinde bildir',
                trailing: Switch(
                  value: settings.notificationsEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setNotifications(value),
                ),
              ),
              SettingsTile(
                icon: LucideIcons.clock,
                title: 'Kontrol sıklığı',
                subtitle: settings.syncFrequency.label,
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () =>
                    _pickFrequency(context, ref, settings.syncFrequency),
              ),
              // Android'de arka plan görevlerinin alt sınırı 15 dakikadır.
              // Gerçekleşmeyecek bir "anlık" vaadi vermemek için burada
              // açıkça yazılır.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.md,
                ),
                child: Text(
                  'Uygulama açıkken yeni iletiler saniyeler içinde düşer. '
                  'Arka planda Android en sık 15 dakikada bir kontrole izin '
                  'verir.',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                ),
              ),
            ],
          ),

          // ---------------------------------------------------- gizlilik
          const SectionHeader('GİZLİLİK'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.shieldAlert,
                title: 'Uzak görselleri yükle',
                subtitle: 'Kapalıyken gönderen iletiyi açtığınızı öğrenemez',
                trailing: Switch(
                  value: settings.showRemoteImages,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setShowRemoteImages(value),
                ),
              ),
              SettingsTile(
                icon: LucideIcons.trash2,
                title: 'Silmeden önce sor',
                subtitle: 'Kalıcı silme işlemlerinde onay iste',
                trailing: Switch(
                  value: settings.confirmBeforeDelete,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setConfirmBeforeDelete(value),
                ),
              ),
            ],
          ),

          // ------------------------------------------------------ bakım
          const SectionHeader('BAKIM'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.refreshCw,
                title: 'Şimdi eşitle',
                subtitle: sync.lastSyncAt == null
                    ? 'Henüz eşitlenmedi'
                    : 'Son: ${formatRelative(sync.lastSyncAt!)}',
                onTap: () =>
                    ref.read(syncControllerProvider.notifier).syncAll(),
              ),
              SettingsTile(
                icon: LucideIcons.hardDrive,
                title: 'Önbelleği temizle',
                subtitle: 'İndirilen ileti içeriklerini siler, iletiler kalır',
                onTap: () => _clearCache(context, ref),
              ),
              SettingsTile(
                icon: LucideIcons.trash2,
                title: 'Çöp kutusunu boşalt',
                subtitle: 'Çöp kutusundaki tüm iletileri kalıcı olarak siler',
                isDestructive: true,
                onTap: () => _emptyTrash(context, ref),
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
          const SizedBox(height: Space.lg),
          Center(
            child: Text(
              'Kaydet 1.0.0',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  static String _securityLabel(SocketSecurity security) => switch (security) {
    SocketSecurity.ssl => 'SSL/TLS',
    SocketSecurity.startTls => 'STARTTLS',
    SocketSecurity.none => 'Güvenlik yok',
  };

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
            onConfirm: () =>
                Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    await ref
        .read(accountRepositoryProvider)
        .updateDisplayName(account.id, value);
  }

  Future<void> _editSignature(
    BuildContext context,
    WidgetRef ref,
    AccountRow account,
  ) async {
    final controller = TextEditingController(text: account.signature ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('İmza'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'İletilerin sonuna eklenecek metin',
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(),
            confirmLabel: 'Kaydet',
            onConfirm: () => Navigator.of(context).pop(controller.text),
          ),
        ],
      ),
    );
    if (value == null) return;
    await ref
        .read(accountRepositoryProvider)
        .updateSignature(account.id, value);
  }

  Future<void> _pickTheme(
    BuildContext context,
    WidgetRef ref,
    ThemeMode current,
  ) async {
    final value = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader('TEMA'),
            RadioGroup<ThemeMode>(
              groupValue: current,
              onChanged: (value) => Navigator.of(context).pop(value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      value: mode,
                      title: Text(switch (mode) {
                        ThemeMode.dark => 'Koyu',
                        ThemeMode.light => 'Açık',
                        ThemeMode.system => 'Sistem ayarını izle',
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
    if (value == null) return;
    await ref.read(settingsProvider.notifier).setThemeMode(value);
  }

  Future<void> _pickFrequency(
    BuildContext context,
    WidgetRef ref,
    SyncFrequency current,
  ) async {
    final value = await showModalBottomSheet<SyncFrequency>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader('KONTROL SIKLIĞI'),
            RadioGroup<SyncFrequency>(
              groupValue: current,
              onChanged: (value) => Navigator.of(context).pop(value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final frequency in SyncFrequency.values)
                    RadioListTile<SyncFrequency>(
                      value: frequency,
                      title: Text(frequency.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
        ),
      ),
    );
    if (value == null) return;
    await ref.read(settingsProvider.notifier).setSyncFrequency(value);
  }

  Future<void> _createLabel(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;

    final controller = TextEditingController();
    var tone = 0;

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Yeni etiket'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Örn: Proje X'),
                ),
                const SizedBox(height: Space.lg),
                Text('Renk', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (var i = 0; i < KaydetTokens.labelToneNames.length; i++)
                      GestureDetector(
                        onTap: () => setState(() => tone = i),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: context.tokens.toneAt(i).background,
                            borderRadius: BorderRadius.circular(Radii.sm),
                            border: Border.all(
                              color: tone == i
                                  ? context.tokens.accent
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: tone == i
                              ? Icon(
                                  LucideIcons.check,
                                  size: 16,
                                  color: context.tokens.toneAt(i).foreground,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            DialogActions(
              cancelLabel: 'Vazgeç',
              onCancel: () => Navigator.of(context).pop(false),
              confirmLabel: 'Oluştur',
              onConfirm: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;
    final name = controller.text.trim();
    if (name.isEmpty) return;

    await ref
        .read(accountRepositoryProvider)
        .createLabel(accountId: accountId, name: name, toneIndex: tone);
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final confirmed = await _confirm(
      context,
      title: 'Önbelleği temizle',
      message:
          'İndirilen ileti içerikleri silinecek. İletiler kalır ve '
          'açtığınızda yeniden indirilir.',
      confirmLabel: 'Temizle',
    );
    if (confirmed != true) return;
    final removed = await ref
        .read(mailRepositoryProvider)
        .pruneCachedBodies(keep: Duration.zero);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$removed ileti içeriği temizlendi.')),
    );
  }

  Future<void> _emptyTrash(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    final confirmed = await _confirm(
      context,
      title: 'Çöp kutusunu boşalt',
      message:
          'Çöp kutusundaki tüm iletiler sunucudan da kalıcı olarak '
          'silinecek. Bu işlem geri alınamaz.',
      confirmLabel: 'Kalıcı olarak sil',
      destructive: true,
    );
    if (confirmed != true) return;
    await ref.read(mailRepositoryProvider).emptyTrash(accountId);
  }

  /// "Hesap ekle" akışını açar — mevcut hesap(lar) dokunulmadan kalır.
  void _addAccount(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const LoginScreen(isAddingAccount: true),
      ),
    );
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
    final confirmed = await _confirm(
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

    // Ayarlar yan menüden açıldıysa kendi yığın sayfasıdır: hesap silinse
    // de üstte durur. Kök ekrana dönülür — kalan hesap varsa repository onu
    // otomatik etkinleştirmiştir ve kök AppShell'i gösterir; kalan hesap
    // yoksa Giriş ekranını gösterir. Bu aynı zamanda ilerleme diyaloğunu
    // da kapatır.
    navigator.popUntil((route) => route.isFirst);

    // Sonraki girişte eski klasör seçimi, arama ve seçim modu kalmasın.
    container.invalidate(selectedFolderRawProvider);
    container.invalidate(selectionProvider);
    container.invalidate(isSearchOpenProvider);
    container.invalidate(searchQueryProvider);
    container.invalidate(pageLimitProvider);
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Vazgeç',
          onCancel: () => Navigator.of(context).pop(false),
          confirmLabel: confirmLabel,
          onConfirm: () => Navigator.of(context).pop(true),
          destructive: destructive,
        ),
      ],
    ),
  );
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
            KaydetAvatar(
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
                    '${SettingsScreen._securityLabel(account.imapSecurity)}'
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

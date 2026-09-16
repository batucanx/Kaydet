import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/actions/message_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../auth/login_screen.dart';
import '../mail_list/mail_list_screen.dart';
import '../settings/settings_screen.dart';

/// Uygulama kabuğu: gövde (etkin modül) + yan menü (klasörler + modül
/// geçişi).
///
/// eM Client'taki gibi modüller (İletiler/Takvim/Kişiler/Ayarlar) arasında
/// geçiş artık ayrı bir alt gezinme çubuğuyla değil, hamburger menünün
/// (bkz. `FolderDrawer`) en altındaki modül listesiyle yapılır — sol
/// rail'in telefondaki karşılığı budur.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(syncControllerProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        controller.resume();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        controller.pause();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final tab = ref.watch(activeTabProvider);

    return Scaffold(
      drawer: const FolderDrawer(),
      // Seçim modunda yan menü kaydırmayla açılmaz: liste üzerindeki
      // yatay kaydırma hareketiyle çakışır.
      drawerEnableOpenDragGesture: !isSelectionMode,
      body: switch (tab) {
        0 => const MailListScreen(),
        3 => const SettingsScreen(),
        _ => _ComingSoon(tab: tab),
      },
    );
  }
}

/// Takvim ve Kişiler v2'de gelecek; sekmeler şimdiden yerinde durur ki
/// eklenince gezinme yeniden tasarlanmasın.
class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.tab});

  final int tab;

  @override
  Widget build(BuildContext context) {
    final (icon, title, description) = tab == 1
        ? (
            LucideIcons.calendarDays,
            'Takvim yakında',
            'Sunucudaki CalDAV takviminiz bir sonraki sürümde bu sekmede '
                'görünecek.',
          )
        : (
            LucideIcons.users,
            'Kişiler yakında',
            'CardDAV adres defteriniz bir sonraki sürümde bu sekmede '
                'görünecek.',
          );

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
        title: Text(tab == 1 ? 'Takvim' : 'Kişiler'),
      ),
      body: EmptyState(icon: icon, title: title, description: description),
    );
  }
}

/// Klasör listesi.
///
/// Tüm hesaplar aynı anda görünür — eM Client'ta olduğu gibi her hesap
/// kendi başlığı altında klasörleriyle listelenir. Başka bir hesabın
/// klasörüne dokunmak o hesabı sessizce etkinleştirir (bkz. [_choose]);
/// ayrı bir "hesap değiştir" adımı yoktur.
class FolderDrawer extends ConsumerStatefulWidget {
  const FolderDrawer({super.key});

  @override
  ConsumerState<FolderDrawer> createState() => _FolderDrawerState();
}

class _FolderDrawerState extends ConsumerState<FolderDrawer> {
  final Set<int> _collapsedAccountIds = {};

  Future<void> _choose(int accountId, SelectedFolder folder) async {
    final activeId = ref.read(accountIdProvider);
    Navigator.of(context).pop();
    // Kullanıcı Ayarlar/Takvim/Kişiler modülündeyken bir posta klasörü
    // seçerse İletiler'e geçilir — aksi hâlde klasör değişir ama ekranda
    // hâlâ önceki modül görünür kalırdı.
    ref.read(activeTabProvider.notifier).select(0);
    if (accountId != activeId) {
      await ref.read(accountRepositoryProvider).switchAccount(accountId);
      if (!mounted) return;
    }
    ref.read(selectedFolderRawProvider.notifier).select(folder);
    ref.read(pageLimitProvider.notifier).reset();
    ref.read(selectionProvider.notifier).clear();
    ref.read(syncControllerProvider.notifier).syncCurrentFolder();
  }

  void _toggleAccount(int accountId) {
    setState(() {
      if (!_collapsedAccountIds.remove(accountId)) {
        _collapsedAccountIds.add(accountId);
      }
    });
  }

  /// Alttaki modül listesinden bir sekme seçer (bkz. `activeTabProvider`).
  void _selectTab(int index) {
    Navigator.of(context).pop();
    ref.read(activeTabProvider.notifier).select(index);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accounts =
        ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final activeId = ref.watch(accountIdProvider);
    final pending = ref.watch(pendingOperationCountProvider).value ?? 0;
    final activeTab = ref.watch(activeTabProvider);

    return Drawer(
      backgroundColor: t.surfaceDeep,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.xl,
                Space.xl,
                Space.md,
                Space.lg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Kaydet',
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(letterSpacing: -0.5),
                    ),
                  ),
                  Tooltip(
                    message: 'Hesap ekle',
                    child: IconButton(
                      icon: Icon(
                        LucideIcons.userPlus,
                        color: t.textSecondary,
                        size: IconSize.md,
                      ),
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const LoginScreen(isAddingAccount: true),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: t.divider, height: 1),

            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final account in accounts)
                    _AccountSection(
                      account: account,
                      isActive: account.id == activeId,
                      isExpanded: !_collapsedAccountIds.contains(account.id),
                      onToggleExpanded: () => _toggleAccount(account.id),
                      onChooseFolder: (folder) => _choose(account.id, folder),
                    ),
                  const SizedBox(height: Space.xl),
                ],
              ),
            ),

            if (pending > 0)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.lg,
                  vertical: Space.sm,
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.clock, size: 14, color: t.textTertiary),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        '$pending işlem gönderilmeyi bekliyor',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                      ),
                    ),
                  ],
                ),
              ),

            Divider(color: t.divider, height: 1),
            // Modül geçişi: eskiden ayrı bir alt gezinme çubuğundaydı,
            // artık eM Client'taki gibi buradan yapılıyor (bkz.
            // `AppShell`'in dosya başı dokümantasyonu) — burada tek satır
            // hâlinde, yalnızca simgelerle, soldan sağa.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ModuleIcon(
                    icon: LucideIcons.mail,
                    tooltip: 'İletiler',
                    isSelected: activeTab == 0,
                    onTap: () => _selectTab(0),
                  ),
                  _ModuleIcon(
                    icon: LucideIcons.calendarDays,
                    tooltip: 'Takvim',
                    isSelected: activeTab == 1,
                    onTap: () => _selectTab(1),
                  ),
                  _ModuleIcon(
                    icon: LucideIcons.users,
                    tooltip: 'Kişiler',
                    isSelected: activeTab == 2,
                    onTap: () => _selectTab(2),
                  ),
                  _ModuleIcon(
                    icon: LucideIcons.settings,
                    tooltip: 'Ayarlar',
                    isSelected: activeTab == 3,
                    onTap: () => _selectTab(3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modül şeridindeki tek simge: etiketsiz, seçiliyken dairesel vurgu alır.
///
/// Etiket görünürde yok, ama `Tooltip` üzerinden erişilebilir kalır (uzun
/// basma/masaüstünde üzerine gelme).
class _ModuleIcon extends StatelessWidget {
  const _ModuleIcon({
    required this.icon,
    required this.tooltip,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.full),
        child: Container(
          width: Dimens.touchTarget,
          height: Dimens.touchTarget,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? t.accentSubtle : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: IconSize.md,
            color: isSelected ? t.accent : t.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Tek bir hesabın klasör ağacı — başlığa dokununca daralır/genişler.
///
/// [isActive] yalnızca seçili klasör vurgusunu doğru hesaba bağlamak için
/// kullanılır; klasörler her hesap için ayrı akışlardan
/// ([mailboxesForAccountProvider] vb.) gelir, etkin hesap değişmeden de
/// güncel kalır.
class _AccountSection extends ConsumerWidget {
  const _AccountSection({
    required this.account,
    required this.isActive,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onChooseFolder,
  });

  final AccountRow account;
  final bool isActive;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<SelectedFolder> onChooseFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final selected = ref.watch(selectedFolderProvider);
    final mailboxes =
        ref.watch(mailboxesForAccountProvider(account.id)).value ??
        const <MailboxRow>[];
    final flaggedCount =
        ref.watch(flaggedCountForAccountProvider(account.id)).value ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggleExpanded,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.lg,
              Space.sm,
            ),
            child: Row(
              children: [
                KaydetAvatar(
                  name: account.displayName,
                  email: account.email,
                  size: 24,
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Text(
                        account.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isExpanded
                      ? LucideIcons.chevronDown
                      : LucideIcons.chevronRight,
                  size: IconSize.sm,
                  color: t.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded) ...[
          for (final box in mailboxes.where((m) => m.isSelectable))
            _FolderTile(
              icon: folderIcon(box.specialUse),
              label: box.name,
              isSelected: isActive && selected?.mailboxId == box.id,
              badge: box.specialUse == SpecialUse.drafts
                  ? null
                  : ref.watch(unreadCountProvider(box.id)).value,
              onTap: () => onChooseFolder(SelectedFolder.mailbox(box.id)),
            ),
          // Sabitlenenler sanal bir klasördür: IMAP \Flagged bayrağı taşıyan
          // iletiler, hangi klasörde olursa olsun — her hesabın kendi
          // sabitlenenleri vardır.
          _FolderTile(
            icon: LucideIcons.pin,
            label: 'Sabitlenenler',
            isSelected: isActive && (selected?.isFlaggedView ?? false),
            badge: flaggedCount > 0 ? flaggedCount : null,
            onTap: () => onChooseFolder(const SelectedFolder.flagged()),
          ),
          const SizedBox(height: Space.sm),
        ],
        Divider(
          color: t.divider,
          height: 1,
          indent: Space.lg,
          endIndent: Space.lg,
        ),
      ],
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: Dimens.touchTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        decoration: BoxDecoration(
          color: isSelected ? t.accentSubtle : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? t.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: IconSize.md,
              color: isSelected ? t.accent : t.textSecondary,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isSelected ? t.textPrimary : t.textSecondary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (badge != null && badge! > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.sm,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? t.accent : t.surface,
                  borderRadius: BorderRadius.circular(Radii.full),
                ),
                child: Text(
                  '${badge!}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: isSelected ? t.onAccentFill : t.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

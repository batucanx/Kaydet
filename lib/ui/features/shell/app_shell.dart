import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../../core/actions/message_actions.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../auth/login_screen.dart';
import '../contacts/contacts_screen.dart';
import '../mail_list/mail_list_screen.dart';
import '../settings/settings_screen.dart';
import 'folder_management_screen.dart';

/// Uygulama kabuğu: gövde (etkin modül) + yan menü (klasörler + modül
/// geçişi).
///
/// eM Client'taki gibi modüller (İletiler/Kişiler/Ayarlar) arasında
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

  /// Kökte değilken sistem geri tuşu: yığıt temizlenip Gelen Kutusu'na
  /// dönülür — `_choose`nin klasör seçimiyle aynı sıfırlama (bkz. o
  /// metodun belgesi), yalnızca senkron tetiklemesi olmadan; geri tuşu
  /// veri değiştirmez, zaten canlı akan yerel veriyi yeniden gösterir.
  void _popToInbox() {
    ref.read(activeTabProvider.notifier).select(0);
    ref.read(selectedFolderRawProvider.notifier).reset();
    ref.read(pageLimitProvider.notifier).reset();
    ref.read(selectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    // Sunucuda başarısız olan arşivle/sil eylemi yerelde geri alındığında
    // kullanıcıya haber verilir — hangi ekranda olursa olsun (kök overlay).
    ref.listen(mailActionFailuresProvider, (_, next) {
      final event = next.value;
      if (event == null) return;
      showMailActionFailure(Overlay.of(context, rootOverlay: true), event);
    });
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final tab = ref.watch(activeTabProvider);
    final isAtRoot = ref.watch(isAtRootDestinationProvider);

    return PopScope(
      // Kökteyken (İletiler + Gelen Kutusu) geri tuşu varsayılan davranışa
      // (uygulamadan çık) bırakılır; aksi halde yutulup Gelen Kutusu'na
      // dönülür — bkz. `isAtRootDestinationProvider`.
      canPop: isAtRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _popToInbox();
      },
      child: Scaffold(
        // NOT: `Scaffold.drawerAnimationStyle` bu Flutter sürümünde
        // (3.44.8) yok — `Scaffold` kaynağında yalnızca `drawerScrimColor`/
        // `drawerEdgeDragWidth` var, drawer'ın kapanış süresi
        // (`_kBaseSettleDuration`, 246ms) private ve özelleştirilemiyor.
        // Kapanış süresini kısaltmak yerine, drawer'ın kendi (sabit)
        // animasyonu sürerken hesap değiştirme işinin ONUNLA AYNI kareye
        // girmemesi sağlanıyor (bkz. `_FolderDrawerState.
        // _selectAccountAndOpenInbox`'taki `Future.delayed` ertelemesi) —
        // asıl kare düşürme sebebi buydu, animasyon süresi değil.
        drawer: const FolderDrawer(),
        onDrawerChanged: (isOpened) {
          if (isOpened) {
            ref.read(syncControllerProvider.notifier).syncFolders(force: true);
          }
        },
        // Seçim modunda yan menü kaydırmayla açılmaz: liste üzerindeki
        // yatay kaydırma hareketiyle çakışır.
        drawerEnableOpenDragGesture: !isSelectionMode,
        // Modül geçişi (İletiler/Kişiler/Ayarlar) eskiden ham
        // `switch` ile anlık widget değişimiydi — "sıfır sert geçiş"
        // kuralı gereği artık `AnimatedSwitcher` üzerinden yumuşak
        // crossfade'e sarılır. `ValueKey` şart: `AnimatedSwitcher` yalnızca
        // child'ın KEY'i değiştiğinde geçiş animasyonunu tetikler.
        body: AnimatedSwitcher(
          duration: context.motion(Motion.page),
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          child: switch (tab) {
            0 => const MailListScreen(key: ValueKey('tab-mail')),
            1 => const ContactsScreen(key: ValueKey('tab-contacts')),
            _ => const SettingsScreen(key: ValueKey('tab-settings')),
          },
        ),
      ),
    );
  }
}

/// Klasör listesi.
///
/// Soldan sağa üç şerit: (1) [NavigationRail] — üstte büyük hesap avatarları
/// (Outlook ölçeğinde, bkz. `Dimens.navRailAvatarSize`) + hesap ekle, altta
/// İletiler/Kişiler modülleri, en altta (her zaman, bkz.
/// `trailingAtBottom`) onlarla aynı boyuttaki Ayarlar; (2) o an etkin hesabın
/// klasörleri. Rayda bir
/// avatara dokunmak o hesabı etkinleştirir ve doğrudan Gelen Kutusu'nu açar
/// (bkz. [_selectAccountAndOpenInbox]) — ayrı bir "klasörleri göster/gizle"
/// adımı yoktur, her zaman tek hesabın klasörleri görünür.
class FolderDrawer extends ConsumerStatefulWidget {
  const FolderDrawer({super.key});

  @override
  ConsumerState<FolderDrawer> createState() => _FolderDrawerState();
}

class _FolderDrawerState extends ConsumerState<FolderDrawer> {
  // Avatara dokunulduğu AN (DB/provider güncellemesi bitmeden) hangi hesabın
  // görsel olarak aktif görüneceği — bkz. `_selectAccountAndOpenInbox`.
  // Gerçek geçiş tamamlanınca (veya başarısız olursa) `null`e döner, o andan
  // sonra halka tekrar `activeAccountId`i (DB'deki gerçeği) yansıtır.
  int? _pendingAccountId;

  void _addAccount() {
    Navigator.of(context).pop();
    context.pushScreen(const LoginScreen(isAddingAccount: true));
  }

  /// Panel başlığındaki pencil/Düzenle ikonuna dokunma — Klasör Yönetimi
  /// ekranını açar (bkz. `FolderManagementScreen`). `_addAccount`'la aynı
  /// desen: basit kapat + it, `_choose`/`_selectAccountAndOpenInbox`'taki
  /// `Motion.fast` ertelemesine gerek yok çünkü burada drawer'ın kapanma
  /// animasyonuyla çakışacak bir provider durumu güncellemesi yok, sadece
  /// yeni bir rota push'u.
  void _manageFolders() {
    Navigator.of(context).pop();
    context.pushScreen(const FolderManagementScreen(), fullscreenDialog: true);
  }

  /// Rayda bir avatara dokunma: o hesabı etkinleştirir ve panelinde
  /// Gelen Kutusu'nu gösterir. Klasör seçimi `null`e sıfırlanınca
  /// `selectedFolderProvider` zaten yeni hesabın Gelen Kutusu'na düşer
  /// (bkz. o sağlayıcının dosya başı açıklaması) — elle çözmeye gerek yok.
  ///
  /// Outlook'taki sıra: (1) parmak değer değmez halka anında yeni hesaba
  /// geçer, (2) drawer hızla kapanır, (3) İÇERİK REBUILD'İ drawer kapanma
  /// animasyonuyla AYNI kareye girmez. Eski sürümde `pop()`in hemen ardından
  /// 5 provider senkron güncelleniyordu; bu, rayin tamamı + panel + her
  /// klasörün rozet sayacını drawer'ın kapanma animasyonuyla aynı karede
  /// yeniden kurup kare düşürüyordu (takılma hissi buradan geliyordu).
  void _selectAccountAndOpenInbox(int accountId) {
    // 1. Optimistic: halka DB/provider beklemeden anında yeni hesaba geçer.
    setState(() => _pendingAccountId = accountId);
    // 2. Drawer hemen kapanmaya başlar.
    Navigator.of(context).pop();

    // 3. Asıl state güncellemesi `Motion.fast` (120ms) kadar ertelenir —
    // drawer'ın sabit ~246ms'lik kapanış animasyonunun (bkz. `AppShell`
    // içindeki not) İLK karesinde değil, ortasında biter; ekran drawer
    // tamamen kaybolmadan önce zaten hazır olur.
    Future.delayed(context.motion(Motion.fast), () {
      if (!mounted) return;
      final activeId = ref.read(accountIdProvider);
      ref.read(activeTabProvider.notifier).select(0);
      ref.read(selectedFolderRawProvider.notifier).reset();
      ref.read(pageLimitProvider.notifier).reset();
      ref.read(selectionProvider.notifier).clear();

      if (accountId == activeId) {
        // Zaten aktif hesap seçildi — geçiş yok, optimistik halka hemen
        // gerçek duruma eşitlenir.
        setState(() => _pendingAccountId = null);
        ref.read(syncControllerProvider.notifier).syncCurrentFolder();
        return;
      }
      unawaited(_switchAccount(accountId));
    });
  }

  Future<void> _switchAccount(int accountId) async {
    try {
      await ref.read(accountRepositoryProvider).switchAccount(accountId);
    } finally {
      // Başarılı da olsa hata da olsa optimistik halka bırakılır — aksi
      // hâlde bir hata durumunda halka yanlış hesapta takılı kalırdı.
      if (mounted) setState(() => _pendingAccountId = null);
    }
    if (!mounted) return;
    ref.read(syncControllerProvider.notifier).syncCurrentFolder();
  }

  /// Panelde bir klasöre/Sabitlenenler'e dokunma. Panel her zaman etkin
  /// hesabın klasörlerini gösterdiği için burada hesap değiştirmeye
  /// gerek yoktur.
  ///
  /// `_selectAccountAndOpenInbox`daki gibi asıl state güncellemesi
  /// `pop()`in hemen ardından değil, `Motion.fast` kadar ertelenir: artık
  /// mail listesi klasör değiştiğinde de crossfade oluyor (bkz.
  /// `MailListScreen` içindeki `AnimatedSwitcher`), o yüzden bu güncelleme
  /// senkron olsaydı hem o crossfade hem `syncCurrentFolder()`ın provider
  /// güncellemeleri drawer'ın kendi ~246ms'lik kapanış animasyonunun İLK
  /// karesine denk gelip kare düşürürdü.
  void _choose(SelectedFolder folder) {
    Navigator.of(context).pop();
    Future.delayed(context.motion(Motion.fast), () {
      if (!mounted) return;
      // Kullanıcı Ayarlar/Kişiler modülündeyken bir posta klasörü
      // seçerse İletiler'e geçilir — aksi hâlde klasör değişir ama ekranda
      // hâlâ önceki modül görünür kalırdı.
      ref.read(activeTabProvider.notifier).select(0);
      ref.read(selectedFolderRawProvider.notifier).select(folder);
      ref.read(pageLimitProvider.notifier).reset();
      ref.read(selectionProvider.notifier).clear();
      ref.read(syncControllerProvider.notifier).syncCurrentFolder();
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
    final activeAccount = ref.watch(activeAccountProvider).value;
    final pending = ref.watch(pendingOperationCountProvider).value ?? 0;
    final activeTab = ref.watch(activeTabProvider);

    return Drawer(
      backgroundColor: t.surfaceDeep,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SideRail(
                    accounts: accounts,
                    activeAccountId: activeAccount?.id,
                    pendingAccountId: _pendingAccountId,
                    onSelectAccount: _selectAccountAndOpenInbox,
                    onAddAccount: _addAccount,
                    activeTab: activeTab,
                    onSelectTab: _selectTab,
                  ),
                  VerticalDivider(color: t.divider, width: 1),
                  Expanded(
                    child: activeAccount == null
                        ? const SizedBox.shrink()
                        : _AccountFolderPanel(
                            account: activeAccount,
                            onChooseFolder: _choose,
                            onManageFolders: _manageFolders,
                          ),
                  ),
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
          ],
        ),
      ),
    );
  }
}

/// Yan menünün sol şeridi: üstte ([leading]) büyük hesap avatarları + hesap
/// ekle, altta (bkz. `groupAlignment: 1`) bir [NavigationRail] ile
/// İletiler/Kişiler modülleri arasında geçiş, en altta
/// ([trailing] + `trailingAtBottom`) onlarla aynı ikon boyutundaki Ayarlar.
/// Modül geçişi eskiden ayrı bir yatay şeritteydi; artık gerçek bir
/// `NavigationRail` — soldaki dikey konumu ve varsayılan seçili-simge
/// vurgusu bunun için var.
class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.accounts,
    required this.activeAccountId,
    required this.pendingAccountId,
    required this.onSelectAccount,
    required this.onAddAccount,
    required this.activeTab,
    required this.onSelectTab,
  });

  final List<AccountRow> accounts;
  final int? activeAccountId;
  // Optimistik seçim — doluysa görsel aktif hesabı DB'nin önüne geçer
  // (bkz. `_FolderDrawerState._selectAccountAndOpenInbox`).
  final int? pendingAccountId;
  final ValueChanged<int> onSelectAccount;
  final VoidCallback onAddAccount;
  final int activeTab;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return NavigationRail(
      backgroundColor: t.surfaceDeep,
      minWidth: 76,
      groupAlignment: 1,
      labelType: NavigationRailLabelType.none,
      trailingAtBottom: true,
      indicatorColor: t.accentSubtle,
      selectedIconTheme: IconThemeData(color: t.accent),
      unselectedIconTheme: IconThemeData(color: t.textSecondary),
      // 2 (Ayarlar) formal bir hedef değil, `trailing`de — o yüzden
      // hedefler listesinde hiçbiri seçili görünmemeli.
      selectedIndex: activeTab < 2 ? activeTab : null,
      onDestinationSelected: onSelectTab,
      leading: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final account in accounts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: _AccountAvatarButton(
                account: account,
                // Optimistik seçim varsa (halka daha az önce tıklanmış
                // hesaba doğru anında kaymış olsun diye) DB'deki gerçek
                // aktif hesabın önüne geçer.
                isActive: account.id == (pendingAccountId ?? activeAccountId),
                onTap: () => onSelectAccount(account.id),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Tooltip(
              message: 'Hesap ekle',
              child: InkWell(
                onTap: onAddAccount,
                borderRadius: BorderRadius.circular(Radii.full),
                child: Container(
                  width: Dimens.avatarSize,
                  height: Dimens.avatarSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: t.divider),
                  ),
                  child: Icon(
                    LucideIcons.plus,
                    size: IconSize.md,
                    color: t.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          Divider(
            color: t.divider,
            height: 1,
            indent: Space.md,
            endIndent: Space.md,
          ),
        ],
      ),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(LucideIcons.mail),
          label: Text('İletiler'),
        ),
        NavigationRailDestination(
          icon: Icon(LucideIcons.users),
          label: Text('Kişiler'),
        ),
      ],
      trailing: Padding(
        padding: const EdgeInsets.only(bottom: Space.lg),
        child: _RailIconButton(
          icon: LucideIcons.settings,
          tooltip: 'Ayarlar',
          isSelected: activeTab == 2,
          onTap: () => onSelectTab(2),
        ),
      ),
    );
  }
}

/// Ayarlar, [NavigationRail]'in formal hedef listesinde değil ([trailing]
/// alanında) olduğu için seçili-durum vurgusu ayrıca burada uygulanır —
/// diğer üç modülün otomatik aldığı görünümle aynı: dairesel `accentSubtle`
/// arka plan.
///
/// [NavigationRail]'in kendi hedefleri (İletiler/Kişiler) seçim
/// değiştiğinde Flutter'ın dahili `AnimationController`larıyla (bkz.
/// `_destinationControllers`, `kThemeAnimationDuration`) zaten yumuşak geçer
/// — burası formal hedef listesinde OLMADIĞI için o mekanizmadan
/// yararlanamaz, aynı yumuşaklığı `AnimatedContainer`/`TweenAnimationBuilder`
/// ile elle sağlar; aksi hâlde arka plan ve ikon rengi sert bir sıçramayla
/// değişirdi.
class _RailIconButton extends StatelessWidget {
  const _RailIconButton({
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
    final duration = context.motion(Motion.fast);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.full),
        child: AnimatedContainer(
          duration: duration,
          curve: Motion.standard,
          width: Dimens.touchTarget,
          height: Dimens.touchTarget,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? t.accentSubtle : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: isSelected ? t.accent : t.textSecondary),
            duration: duration,
            curve: Motion.standard,
            builder: (context, color, _) =>
                Icon(icon, size: IconSize.lg, color: color),
          ),
        ),
      ),
    );
  }
}

class _AccountAvatarButton extends StatelessWidget {
  const _AccountAvatarButton({
    required this.account,
    required this.isActive,
    required this.onTap,
  });

  final AccountRow account;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: account.email,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.full),
        // Halka rengi/kalınlığı `isActive` değiştiğinde anlık atlamaz,
        // `Motion.fast` boyunca akıcı geçer — optimistik seçimin
        // (`_pendingAccountId`) görsel karşılığı budur.
        child: AnimatedContainer(
          duration: context.motion(Motion.fast),
          curve: Motion.standard,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive ? t.accent : Colors.transparent,
              width: isActive ? 2.5 : 1.5,
            ),
          ),
          // Hafif büyüme — Outlook'un "seçildi" hissi.
          child: AnimatedScale(
            scale: isActive ? 1.0 : 0.95,
            duration: context.motion(Motion.fast),
            curve: Motion.standard,
            child: BrandAvatar(
              name: account.displayName,
              email: account.email,
              size: Dimens.navRailAvatarSize,
            ),
          ),
        ),
      ),
    );
  }
}

/// Sağdaki panel: etkin hesabın başlığı + klasörleri. Her zaman tek hesabı
/// gösterir — hesap değişimi rayda yapılır (bkz. [_SideRail]).
///
/// İçerik ([_AccountFolderPanelContent]) hesap değiştiğinde anlık
/// yenilenmez, `Motion.base` boyunca yumuşak bir crossfade ile geçer —
/// `ValueKey(account.id)` şart, aksi hâlde `AnimatedSwitcher` hangi child'ın
/// değiştiğini anlayamaz ve geçiş hiç tetiklenmez.
class _AccountFolderPanel extends StatelessWidget {
  const _AccountFolderPanel({
    required this.account,
    required this.onChooseFolder,
    required this.onManageFolders,
  });

  final AccountRow account;
  final ValueChanged<SelectedFolder> onChooseFolder;
  final VoidCallback onManageFolders;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: context.motion(Motion.base),
      switchInCurve: Motion.standard,
      switchOutCurve: Motion.standard,
      child: _AccountFolderPanelContent(
        key: ValueKey(account.id),
        account: account,
        onChooseFolder: onChooseFolder,
        onManageFolders: onManageFolders,
      ),
    );
  }
}

class _AccountFolderPanelContent extends ConsumerStatefulWidget {
  const _AccountFolderPanelContent({
    super.key,
    required this.account,
    required this.onChooseFolder,
    required this.onManageFolders,
  });

  final AccountRow account;
  final ValueChanged<SelectedFolder> onChooseFolder;
  final VoidCallback onManageFolders;

  @override
  ConsumerState<_AccountFolderPanelContent> createState() =>
      _AccountFolderPanelContentState();
}

class _AccountFolderPanelContentState
    extends ConsumerState<_AccountFolderPanelContent> {
  AccountRow get account => widget.account;
  ValueChanged<SelectedFolder> get onChooseFolder => widget.onChooseFolder;
  VoidCallback get onManageFolders => widget.onManageFolders;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final selected = ref.watch(selectedFolderProvider);
    final collapsedMap = ref.watch(collapsedFoldersProvider);
    final collapsed =
        collapsedMap[account.id] ??
        ref.read(settingsStoreProvider).readCollapsedFolders(account.id);
    final mailboxes =
        ref.watch(mailboxesForAccountProvider(account.id)).value ??
        const <MailboxRow>[];
    final flaggedCount =
        ref.watch(flaggedCountForAccountProvider(account.id)).value ?? 0;
    final folders = mailboxes.where((m) => m.isSelectable).toList();
    // Aynı klasör hem burada hem aşağıdaki tam listede görünür — ikinci bir
    // kopya değil, aynı `MailboxRow`un `isFavorite` süzgeci (bkz.
    // `FolderManagementScreen`). Sıra da ortak `sortOrder`dan gelir.
    final favorites = folders.where((m) => m.isFavorite).toList();

    // Tree traversal: path + delimiter → parent-child ilişkisi, ek DB alanı
    // veya migration gerekmez (bkz. `buildFolderTree` açıklaması).
    final tree = ref.watch(folderTreeForAccountProvider(account.id));

    Widget folderTile(
      MailboxRow box, {
      double indent = 0,
      bool? expanded,
      VoidCallback? onToggle,
    }) => _FolderTile(
      expanded: expanded,
      onToggle: onToggle,
      icon: folderIcon(box.specialUse),
      label: box.name,
      indent: indent,
      isSelected: selected?.mailboxId == box.id,
      badge: box.specialUse == SpecialUse.drafts
          ? null
          : ref.watch(unreadCountProvider(box.id)).value,
      onTap: () => onChooseFolder(SelectedFolder.mailbox(box.id)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.xl,
            Space.sm,
            Space.lg,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.displayName.isEmpty
                          ? account.email
                          : account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
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
              IconButton(
                icon: const Icon(LucideIcons.pencil, size: IconSize.sm),
                tooltip: 'Düzenle',
                onPressed: onManageFolders,
              ),
            ],
          ),
        ),
        Divider(color: t.divider, height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: Space.sm),
            children: [
              if (favorites.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.sm,
                    Space.lg,
                    Space.xs,
                  ),
                  child: Text(
                    'Sık Kullanılanlar',
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: t.textTertiary),
                  ),
                ),
                // Sık Kullanılanlar bölümü kullanıcı tercihi — her zaman flat,
                // depth gözetilmez (hangi klasörü favorilediği önemli değil).
                for (final box in favorites) folderTile(box),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Divider(color: t.divider, height: 1),
                ),
              ],
              // Tam liste: depth-first tree sırası + depth-based indent.
              for (var i = 0; i < tree.length; i++)
                if (!_isHidden(tree, i, collapsed))
                  folderTile(
                    tree[i].mailbox,
                    indent: tree[i].depth * Space.lg,
                    expanded: _hasChildren(tree, i)
                        ? !collapsed.contains(tree[i].mailbox.id)
                        : null,
                    onToggle: () => ref
                        .read(collapsedFoldersProvider.notifier)
                        .toggle(account.id, tree[i].mailbox.id),
                  ),
              // Sabitlenenler sanal bir klasördür: IMAP \Flagged bayrağı
              // taşıyan iletiler, hangi klasörde olursa olsun.
              _FolderTile(
                icon: LucideIcons.pin,
                label: 'Sabitlenenler',
                isSelected: selected?.isFlaggedView ?? false,
                badge: flaggedCount > 0 ? flaggedCount : null,
                onTap: () => onChooseFolder(const SelectedFolder.flagged()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _hasChildren(List<FolderTreeNode> tree, int i) =>
      i + 1 < tree.length && tree[i + 1].depth > tree[i].depth;

  /// Atalarından biri daraltılmışsa satır gizlenir.
  bool _isHidden(List<FolderTreeNode> tree, int i, Set<int> collapsed) {
    var depth = tree[i].depth;
    for (var k = i - 1; k >= 0 && depth > 0; k--) {
      if (tree[k].depth < depth) {
        depth = tree[k].depth;
        if (collapsed.contains(tree[k].mailbox.id)) return true;
      }
    }
    return false;
  }
}

/// Panelde bir klasör satırı. Seçili durum değiştiğinde (bkz. `isSelected`)
/// arka plan, sol kenar çubuğu, ikon/metin rengi ve rozet artık anlık
/// sıçramıyor — hepsi `Motion.fast` boyunca birlikte yumuşak geçiyor
/// (bkz. `AnimatedContainer`/`AnimatedDefaultTextStyle`/
/// `TweenAnimationBuilder`), tıpkı sağdaki hesap halkasında olduğu gibi
/// (bkz. `_AccountAvatarButton`).
class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.badge,
    this.indent = 0,
    this.expanded,
    this.onToggle,
  });

  /// null = alt klasörü yok; true/false = açık/kapalı (chevron gösterilir).
  final bool? expanded;
  final VoidCallback? onToggle;
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final int? badge;

  /// Yatay girinti (px) — tree derinliğine göre `buildFolderTree`'den gelir.
  /// 0 = kök klasör; her ek seviye `Space.lg` (16 dp) ek girinti.
  final double indent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final duration = context.motion(Motion.fast);
    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: duration,
        curve: Motion.standard,
        constraints: const BoxConstraints(minHeight: Dimens.touchTarget),
        padding: EdgeInsets.only(
          // Seçim göstergesi sol kenara yapışık — indent sol padding'e eklenir.
          left: Space.lg + indent,
          right: Space.lg,
          top: Space.md,
          bottom: Space.md,
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
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: isSelected ? t.accent : t.textSecondary),
              duration: duration,
              curve: Motion.standard,
              builder: (context, color, _) =>
                  Icon(icon, size: IconSize.md, color: color),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: duration,
                curve: Motion.standard,
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: isSelected ? t.textPrimary : t.textSecondary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (expanded != null)
              InkWell(
                onTap: onToggle,
                borderRadius: BorderRadius.circular(Radii.full),
                child: Padding(
                  padding: const EdgeInsets.all(Space.xs),
                  child: AnimatedRotation(
                    turns: expanded! ? 0.25 : 0,
                    duration: duration,
                    curve: Motion.standard,
                    child: Icon(
                      LucideIcons.chevronRight,
                      size: IconSize.sm,
                      color: t.textTertiary,
                    ),
                  ),
                ),
              ),
            if (badge != null && badge! > 0)
              AnimatedContainer(
                duration: duration,
                curve: Motion.standard,
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.sm,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? t.accent : t.surface,
                  borderRadius: BorderRadius.circular(Radii.full),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: Motion.standard,
                  style: Theme.of(context).textTheme.labelSmall!.copyWith(
                    color: isSelected ? t.onAccentFill : t.textSecondary,
                  ),
                  child: Text('${badge!}'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

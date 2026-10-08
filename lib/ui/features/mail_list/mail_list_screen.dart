import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/push_stubs.dart';
import '../../../app/sync_controller.dart';
import '../../../core/result.dart' show AuthFailure;
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../../core/actions/message_actions.dart';
import '../../core/actions/password_actions.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/swipe_action_style.dart';
import '../settings/swipe_settings_screen.dart';
import '../../../domain/use_cases/swipe_action_resolver.dart';
import '../../../data/services/app_settings.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_launcher.dart';
import '../mail_detail/mail_detail_screen.dart';
import '../search/search_screen.dart';
import 'bounded_dismissible.dart';
import 'mail_row.dart';

/// Sunucusuna kalıcı olarak ulaşılamayan hesap için sakin şerit (bkz.
/// `SyncController._noteConnectionFailure`: ardışık hata + süre eşiği).
///
/// Tek hesap görünümünde yalnızca etkin hesap için; Tüm Hesaplar'da ulaşılamayan
/// hesapların adresleri listelenir. Sunucu yanıt verince kendiliğinden kaybolur.
class _UnreachableBanner extends ConsumerWidget {
  const _UnreachableBanner({required this.isAllAccounts});

  final bool isAllAccounts;

  static String _time(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final clock = '${two(at.hour)}:${two(at.minute)}';
    return sameDay ? clock : '${two(at.day)}.${two(at.month)} $clock';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreachable = ref.watch(
      syncControllerProvider.select((s) => s.unreachableAccounts),
    );
    if (unreachable.isEmpty) return const SizedBox.shrink();

    final String message;
    if (isAllAccounts) {
      final emails = [
        for (final a in ref.watch(allAccountsProvider).value ?? const <AccountRow>[])
          if (unreachable.containsKey(a.id)) a.email,
      ];
      if (emails.isEmpty) return const SizedBox.shrink();
      message = 'Sunucuya ulaşılamıyor: ${emails.join(', ')}';
    } else {
      final activeId = ref.watch(accountIdProvider);
      if (activeId == null || !unreachable.containsKey(activeId)) {
        return const SizedBox.shrink();
      }
      final last = unreachable[activeId];
      message = last == null
          ? 'Sunucuya ulaşılamıyor.'
          : 'Sunucuya ulaşılamıyor · Son eşitleme ${_time(last)}';
    }

    return StatusBanner(
      message: message,
      icon: LucideIcons.serverOff,
      actionLabel: 'Yeniden dene',
      onAction: () => ref
          .read(syncControllerProvider.notifier)
          .syncCurrentFolder(allAccounts: true),
    );
  }
}

/// AppBar'ın altındaki ince "eşitleniyor" çizgisi.
///
/// Hesap değişiminde ya da kullanım sırasında eşitleme birkaç saniye sürebilir;
/// çizgi, listenin bir anda güncellenmesi yerine kullanıcıya işin sürdüğünü
/// gösterir. Çok kısa turlarda (arka plan yoklaması) titremesin diye çizgi
/// [_showDelay] sonra belirir. Yüksekliği sabittir; belirip kaybolması
/// listeyi kaydırmaz. Yalnızca `isSyncing` izlenir, bu yüzden ekranın geri
/// kalanı yeniden kurulmaz.
class _SyncProgressBar extends ConsumerStatefulWidget {
  const _SyncProgressBar();

  @override
  ConsumerState<_SyncProgressBar> createState() => _SyncProgressBarState();
}

class _SyncProgressBarState extends ConsumerState<_SyncProgressBar> {
  static const Duration _showDelay = Duration(milliseconds: 250);

  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _apply(ref.read(syncControllerProvider).isSyncing);
    ref.listenManual(
      syncControllerProvider.select((s) => s.isSyncing),
      (_, next) => _apply(next),
    );
  }

  void _apply(bool syncing) {
    _timer?.cancel();
    if (!syncing) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    _timer = Timer(_showDelay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Görünmezken oluşturulmaz: boşta sürekli kare üretmesin.
    return SizedBox(
      height: 2,
      child: _visible
          ? LinearProgressIndicator(
              minHeight: 2,
              color: t.accent,
              backgroundColor: t.accent.withValues(alpha: 0.15),
            )
          : null,
    );
  }
}

/// Mail listesi — uygulamanın merkezi.
class MailListScreen extends ConsumerStatefulWidget {
  const MailListScreen({super.key});

  @override
  ConsumerState<MailListScreen> createState() => _MailListScreenState();
}

class _MailListScreenState extends ConsumerState<MailListScreen> {
  final ScrollController _scroll = ScrollController();

  // Liste en üstteyken "Yeni ileti" FAB'ı genişler (ikon + yazı); aşağı
  // kaydırılınca daralıp sadece ikon kalır (Gmail'deki gibi).
  //
  // `ValueNotifier` kullanılır: `setState` ile tutulsaydı üst sınırı her
  // geçişte `_MailListScreenState.build()` tümüyle yeniden çalışır — AppBar
  // ve `ListView.builder`'ın yeniden kurulması dahil — ve bu tam kaydırmanın
  // ortasında gözle görülür bir takılmaya yol açıyordu. `ValueListenableBuilder`
  // yalnızca FAB'ı dinlediği için artık yalnızca o widget yeniden çiziliyor.
  final ValueNotifier<bool> _isAtTop = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _isAtTop.dispose();
    super.dispose();
  }

  // Sayfalama artık burada TETİKLENMEZ (bkz. `_LoadMoreControl`): kaydırma
  // pozisyonuna bağlı otomatik yükleme, hızlı kaydırma sırasında ağ isteği +
  // veritabanı yeniden sorgusuyla aynı kareye denk gelip kare düşürüyor ve
  // yeni satırlar birden "patlayarak" beliriyordu (Outlook mobildeki gibi
  // "Manuel Kontrollü Sayfalama"da bir sonraki sayfa yalnızca kullanıcı
  // düğmeye dokunduğunda, öngörülebilir tek bir anda istenir).
  void _onScroll() {
    if (!_scroll.hasClients) return;
    _isAtTop.value = _scroll.position.pixels <= 8;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accountId = ref.watch(accountIdProvider);
    final activeAccount = ref.watch(activeAccountProvider).value;
    // Yalnızca "Tümünü seç" için ham id listesi gerekiyor — gövde artık
    // `mailListItemsProvider`den okunuyor (bkz. aşağısı), bu yüzden bu akışı
    // burada ikinci kez gruplamıyoruz.
    final messages = ref.watch(messageListProvider);
    final itemsAsync = ref.watch(mailListItemsProvider);
    final selection = ref.watch(selectionProvider);
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    // `SyncState`in tamamı DEĞİL, yalnızca bu ekranın gösterdiği alanlar
    // izlenir: her eşitleme turu `isSyncing`/`lastSyncAt`'i değiştirir ve tüm
    // `SyncState` izlenseydi ekran (AppBar ve liste dahil) her turda baştan
    // kurulurdu.
    final isOffline = ref.watch(syncControllerProvider.select((s) => s.isOffline));
    final syncError = ref.watch(syncControllerProvider.select((s) => s.lastError));
    final isLoadingMore = ref.watch(
      syncControllerProvider.select((s) => s.isLoadingMore),
    );
    final hasMoreLocal = ref.watch(syncControllerProvider.select((s) => s.hasMore));
    final mailbox = ref.watch(currentMailboxProvider);
    final folder = ref.watch(selectedFolderProvider);
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    // Tüm Hesaplar: liste tek bir klasör değil, her hesabın aynı türdeki
    // klasörlerinin birleşimidir (bkz. `SelectedFolder.unified`).
    final unifiedUse = folder?.unifiedUse;
    final folderUse = ref.watch(currentSpecialUseProvider);
    final hasMoreOnServer = unifiedUse != null
        ? ref
              .watch(unifiedMailboxesProvider(unifiedUse))
              .any((m) => m.hasMoreOnServer)
        : mailbox?.hasMoreOnServer == true;

    final isSentLike =
        folderUse == SpecialUse.sent || folderUse == SpecialUse.drafts;

    final scaffold = Scaffold(
      appBar: _buildAppBar(
        context,
        isSelectionMode: isSelectionMode,
        selectionCount: selection.length,
        // Yalnızca "Tümünü seç" için gerekir: seçim modu dışında her yeniden
        // kurulumda binlerce kimlikten liste üretmeye gerek yok.
        visibleIds: isSelectionMode
            ? (messages.value?.map((m) => m.id).toList() ?? const <int>[])
            : const <int>[],
        title: folder?.isFlaggedView == true
            ? 'Sabitlenenler'
            : unifiedUse != null
            ? FolderMapping.displayName(unifiedUse, '')
            : (mailbox?.name ?? 'Kaydet'),
        account: activeAccount,
        isAllAccounts: unifiedUse != null,
      ),
      body: Column(
        children: [
          const _SyncProgressBar(),
          if (isOffline)
            const StatusBanner(
              message:
                  'Çevrimdışısınız. Değişiklikleriniz kaydedildi, '
                  'bağlantı gelince gönderilecek.',
              icon: LucideIcons.cloudOff,
            ),
          if (!isOffline && syncError == null)
            _UnreachableBanner(isAllAccounts: unifiedUse != null),
          if (unifiedUse == null && folderUse == SpecialUse.inbox)
            const _PushStubsSection(),
          if (syncError != null && !isOffline)
            StatusBanner(
              message: syncError.userMessage,
              icon: LucideIcons.triangleAlert,
              color: t.danger,
              // Şifre değişmiş ya da kayıtlı şifre yoksa "yeniden dene" hiçbir
              // şey düzeltmez: kullanıcı şifreyi girer, hesap ve yerel veri
              // korunur.
              actionLabel: syncError is AuthFailure
                  ? 'Şifreyi güncelle'
                  : 'Yeniden dene',
              onAction: () => syncError is AuthFailure
                  ? showUpdatePasswordDialog(context, ref)
                  : ref
                        .read(syncControllerProvider.notifier)
                        .syncCurrentFolder(allAccounts: true),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                final sync = ref.read(syncControllerProvider.notifier);
                // Tüm Hesaplar'da kullanıcı çekip yenileyince her hesap
                // eşitlenir; tek hesap görünümünde parametre etkisizdir.
                await sync.syncCurrentFolder(allAccounts: true);
                // Çekip yenileme klasör listesini de güncel tutar (web
                // istemcisinde eklenen/silinen klasörler).
                await sync.syncFolders(force: true);
              },
              color: t.accent,
              backgroundColor: t.surfaceElevated,
              // `skipLoadingOnReload`: klasör/filtre/hesap değişimi veya
              // "daha fazla yükle" `messageListProvider`'ı BAŞTAN kurar
              // (bkz. sağlayıcının izlediği `accountIdProvider`,
              // `selectedFolderProvider`, `messageFilterProvider`,
              // `pageLimitProvider`) — bu olmadan her reload'da `loading`
              // dalı çalışır ve elde zaten görünür liste varken ekran
              // anlık olarak skeleton'a döner. `true` ile önceki liste
              // ekranda kalır, yeni veri arkada sessizce üzerine yazılır;
              // `loading` dalı yalnızca GERÇEKTEN hiç veri yokken (ör. ilk
              // açılış) çalışır. Arka plan senkronunun kendisi artık ayrı
              // bir gösterge taşımıyor (bkz. kaldırılan
              // `LinearProgressIndicator` — `RefreshIndicator`'ın kendi
              // spinner'ı kullanıcının bizzat çektiği yenilemeyi zaten
              // bildiriyor, senkron her tetiklendiğinde ayrı bir "hâlâ
              // yükleniyor" çubuğuna gerek yok).
              //
              // Dıştaki `AnimatedSwitcher` hesap VEYA klasör değiştiğinde
              // devreye girer (bkz. `KeyedSubtree`'nin bileşik key'i) —
              // filtre/"daha fazla yükle" değişiklikleri hâlâ TETİKLEMEZ,
              // onlar zaten `skipLoadingOnReload` ile sessizce güncelleniyor.
              // İkisinde de (hesap/klasör) veri zaten yerelden anında geldiği
              // için (cache-first mimari) bu salt kozmetik, kısa bir
              // crossfade'dir — yeni bir bekleme durumu YARATMAZ.
              child: AnimatedSwitcher(
                duration: context.motion(Motion.fast),
                switchInCurve: Motion.standard,
                switchOutCurve: Motion.standard,
                child: KeyedSubtree(
                  key: ValueKey((
                    accountId,
                    folder?.mailboxId,
                    folder?.isFlaggedView,
                    unifiedUse,
                  )),
                  child: itemsAsync.when(
                    skipLoadingOnReload: true,
                    loading: () => const _ListSkeleton(),
                    error: (error, _) => EmptyState(
                      icon: LucideIcons.triangleAlert,
                      title: 'Liste yüklenemedi',
                      description: '$error',
                    ),
                    data: (items) => _buildListView(
                      context,
                      items: items,
                      labels: labels,
                      isSentLike: isSentLike,
                      isLoadingMore: isLoadingMore,
                      hasMore: hasMoreLocal && hasMoreOnServer,
                      showAccount: unifiedUse != null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: isSelectionMode
          ? null
          : ValueListenableBuilder<bool>(
              valueListenable: _isAtTop,
              builder: (context, isAtTop, _) =>
                  _ComposeFab(isExpanded: isAtTop, onPressed: _openCompose),
            ),
      bottomNavigationBar: isSelectionMode
          ? _SelectionActionBar(ids: selection.toList())
          : null,
    );
    return KaydetDepthCoverEffect(child: scaffold);
  }

  /// Sabitlenenler bölümü `SliverPersistentHeader` gibi ekrana yapışan ayrı
  /// bir widget DEĞİL, listenin en başındaki normal bir eleman
  /// (`PinnedSectionItem`) olarak eklenir — böylece diğer iletiler arasında
  /// kaydırırken ekranı takip etmez, geri kalan her şeyle birlikte kayıp
  /// gözden kaybolur.
  ///
  /// [items] artık burada hesaplanmıyor — `mailListItemsProvider`den hazır
  /// geliyor (bkz. `app/providers.dart`), bu yüzden seçim modu gibi listenin
  /// içeriğini etkilemeyen bir state değiştiğinde bu metot tekrar
  /// çağrılsa bile gruplama YENİDEN hesaplanmaz.
  Widget _buildListView(
    BuildContext context, {
    required List<MailListItem> items,
    required List<LabelRow> labels,
    required bool isSentLike,
    required bool isLoadingMore,
    required bool hasMore,
    required bool showAccount,
  }) {
    // Tüm Hesaplar'da her satırın hangi hesaba ait olduğu gösterilir.
    final accountsById = showAccount
        ? {
            for (final a
                in ref.watch(allAccountsProvider).value ?? const <AccountRow>[])
              a.id: a,
          }
        : const <int, AccountRow>{};
    // Klasör yüklenirken ya da liste boşken ("yükleniyor"/"boş" yer tutucusu)
    // altta sayfalama kontrolü gösterilmez: ortada hâlâ bir ileti yok.
    final hasMessages = items.any((i) => i is MessageItem);
    final showLoadMore = hasMessages && (hasMore || isLoadingMore);
    return ListView.builder(
      key: const PageStorageKey('mail-list'),
      controller: _scroll,
      // Boş olsa da aşağı çekerek yenileme çalışmalı.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      // Varsayılan 250px'lik ön-inşa alanı hızlı kaydırmada avatar/logoların
      // "pop-in" etmesine yol açıyordu; ~3 ekran yüksekliği önden inşa edilir.
      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
      itemCount: items.length + (showLoadMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return _LoadMoreControl(
            isLoading: isLoadingMore,
            onTap: () => ref.read(syncControllerProvider.notifier).loadMore(),
          );
        }
        return switch (items[index]) {
          PinnedSectionItem() => const _PinnedSection(),
          // İlk indirme sürerken liste boş kalır; "yükleniyor" bilgisini
          // AppBar altındaki `_SyncProgressBar` verir.
          FolderLoadingItem() => SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
          ),
          EmptyListItem(:final filterActive) => SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: _emptyState(filterActive),
          ),
          DateHeaderItem(:final label) => SectionHeader(
            label,
            showDivider: true,
          ),
          MessageItem(:final message) => _SwipeRow(
            key: ValueKey(message.id),
            message: message,
            labels: labels,
            isSentFolder: isSentLike,
            account: accountsById[message.accountId],
            onTap: () => _onRowTap(message),
            onAvatarTap: () =>
                ref.read(selectionProvider.notifier).toggle(message.id),
            onLongPress: () =>
                ref.read(selectionProvider.notifier).toggle(message.id),
          ),
        };
      },
    );
  }

  /// Klasör/filtre sonucu boşsa gösterilecek durum. [filterActive] yanlış
  /// "klasör boş" mesajını (aslında filtreyle eşleşen ileti kalmamış
  /// olabilir, iletiler kaybolmuş değil) önler.
  Widget _emptyState(bool filterActive) {
    final (icon, title, description) = filterActive
        ? (
            LucideIcons.filter,
            'Filtreyle eşleşen ileti yok',
            'Farklı bir filtre deneyin veya filtreyi temizleyin.',
          )
        : (
            LucideIcons.inbox,
            'Bu klasör boş',
            'Yeni iletiler geldiğinde burada görünecek.',
          );
    return EmptyState(icon: icon, title: title, description: description);
  }

  Future<void> _onRowTap(MessageRow message) async {
    if (ref.read(selectionProvider).isNotEmpty) {
      ref.read(selectionProvider.notifier).toggle(message.id);
      return;
    }

    // Taslak ve gönderilememiş iletiler yazma ekranında açılır.
    if (message.isDraft || message.outboxState == OutboxState.failed) {
      await _openCompose(draftId: message.id);
      return;
    }

    await context.pushScreen(MailDetailScreen(messageId: message.id));
  }

  Future<void> _openCompose({int? draftId}) => openCompose(
    context,
    ref,
    draftId: draftId,
    // iOS/Outlook tarzı modern Compose geçişi: Fade + subtle scale + micro
    // vertical hareket. Gelen Kutusu sabit kalır, kararma/küçülme olmaz.
    transitionStyle: KaydetTransitionStyle.compose,
    // "Taslağa kaydedildi" bildirimi "Yeni" düğmesinin üstünde durur.
    noticeBottomInset: _ComposeFab.footprint,
  );

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required bool isSelectionMode,
    required int selectionCount,
    required List<int> visibleIds,
    required String title,
    AccountRow? account,
    bool isAllAccounts = false,
  }) {
    final t = context.tokens;

    if (isSelectionMode) {
      final allSelected =
          visibleIds.isNotEmpty && selectionCount >= visibleIds.length;
      return AppBar(
        // Seçim moduna geçişte üst çubuk zıplamasın diye normal moddaki
        // `_InboxAppBar._barHeight` ile aynı yükseklik kullanılır.
        toolbarHeight: _InboxAppBar._barHeight,
        backgroundColor: t.accentFill,
        foregroundColor: t.onAccentFill,
        leading: IconButton(
          icon: const Icon(LucideIcons.x),
          tooltip: 'Vazgeç',
          onPressed: () => ref.read(selectionProvider.notifier).clear(),
        ),
        title: Text(
          '$selectionCount seçildi',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: t.onAccentFill),
        ),
        actions: [
          TextButton(
            onPressed: () {
              final notifier = ref.read(selectionProvider.notifier);
              if (allSelected) {
                notifier.clear();
              } else {
                notifier.selectAll(visibleIds);
              }
            },
            style: TextButton.styleFrom(foregroundColor: t.onAccentFill),
            child: Text(allSelected ? 'Vazgeç' : 'Tümünü seç'),
          ),
          const SizedBox(width: Space.sm),
        ],
      );
    }

    return _InboxAppBar(
      title: title,
      account: account,
      isAllAccounts: isAllAccounts,
      onMenuTap: () => Scaffold.of(context).openDrawer(),
      onSearchTap: () => context.pushScreen(const SearchScreen()),
      filterButton: const _FilterMenuButton(),
    );
  }
}

/// Bildirimle gelmiş ama henüz IMAP'ten eşitlenmemiş iletiler (bkz.
/// `PushStub`): uygulama uzun süre arka plandayken gelen iletiler, eşitleme
/// bitene kadar yalnızca "Yeni iletiler alınıyor" göstergesi çıkar (ileti
/// içeriği gösterilmez); gerçek ileti gelince kendiliğinden kaybolur.
/// Listenin DIŞINDA, üstte durur — liste/animasyon/seçim mantığına karışmaz.
class _PushStubsSection extends ConsumerWidget {
  const _PushStubsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(accountIdProvider);
    final stubs = [
      for (final s in ref.watch(pushStubsProvider))
        if (s.accountId == accountId) s,
    ];
    if (stubs.isEmpty) return const SizedBox.shrink();

    final t = context.tokens;
    return Material(
      color: t.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.sm,
              Space.lg,
              Space.sm,
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: t.textTertiary,
                  ),
                ),
                const SizedBox(width: Space.sm),
                Text(
                  'Yeni iletiler alınıyor',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: t.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// "Yeni ileti" düğmesi: tek, kalıcı bir widget olarak yumuşakça genişler/
/// daralır (Gmail'deki gibi). Scaffold'ın FAB değiştirirken uyguladığı
/// sert küçül-büyü geçişinden kaçınmak için iki ayrı `FloatingActionButton`
/// arasında geçiş YAPILMAZ — aynı widget kalır, yalnızca genişliği ve
/// etiketin görünürlüğü animasyonlanır.
class _ComposeFab extends StatelessWidget {
  const _ComposeFab({required this.isExpanded, required this.onPressed});

  final bool isExpanded;
  final VoidCallback onPressed;

  static const _duration = Duration(milliseconds: 280);
  static const _curve = Curves.easeOutCubic;

  /// Düğmenin alt güvenli alanın üstünde kapladığı yükseklik: kendi boyu +
  /// `Scaffold`ın varsayılan (`endFloat`) kenar boşluğu. Altta gösterilen
  /// bildirimler bunun üstüne yerleşir (bkz. `KaydetNotice`).
  static const double footprint = Dimens.fabSize + kFloatingActionButtonMargin;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: 'Yeni ileti',
      child: Material(
        color: t.accentFill,
        elevation: 3,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: _duration,
            curve: _curve,
            height: Dimens.fabSize,
            padding: EdgeInsets.symmetric(
              horizontal: isExpanded
                  ? Space.lg
                  : (Dimens.fabSize - IconSize.lg) / 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.plus,
                  size: IconSize.lg,
                  color: t.onAccentFill,
                ),
                ClipRect(
                  child: AnimatedAlign(
                    duration: _duration,
                    curve: _curve,
                    alignment: Alignment.centerLeft,
                    widthFactor: isExpanded ? 1 : 0,
                    child: Padding(
                      padding: const EdgeInsets.only(left: Space.sm),
                      child: Text(
                        'Yeni',
                        maxLines: 1,
                        softWrap: false,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: t.onAccentFill,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Kaydırma hareketleri: sağa ve sola kaydırma eylemleri Ayarlar → Çekme
/// seçenekleri'nden seçilir (varsayılan: sağa arşivle, sola sil). Seçim genel
/// varsayılandır; bulunulan klasöre ve iletinin durumuna göre nihai eylem
/// `SwipeActionResolver` ile belirlenir (ör. Arşiv/Çöp/İstenmeyen'de
/// "Arşivle" → "Gelen Kutusuna taşı", sabitliyse "Sabitle" → "Sabitlemeyi
/// kaldır"). Eylem panelinin rengi/simgesi/etiketi bu nihai eylemi gösterir.
///
/// Silme, kalıcıysa onay ister (bkz. `confirmDelete`). Okundu ve sabitleme
/// gibi satırı kaldırmayan eylemler satırı yerinde bırakır. Eşik aşılıp
/// bırakılınca eylem çalışır; aşılmadan bırakılırsa satır yerine döner (açık
/// kalan bir eylem paneli yoktur).
///
/// FİZİKSEL yönler kullanılır: `Dismissible`ın yönleri metin yönüne göredir
/// (RTL'de `startToEnd` sola kaydırmadır), bu yüzden eşleme
/// `Directionality`'ye bakılarak yapılır.
///
/// Seçim durumunu kendi diliminden (`selectionProvider.select`) okur —
/// ebeveynden parametre olarak almaz. Böylece bir satır seçildiğinde/
/// seçimi kaldırıldığında SADECE o satırın widget'ı yeniden çizilir,
/// listedeki diğer görünür satırlar etkilenmez.
class _SwipeRow extends ConsumerStatefulWidget {
  const _SwipeRow({
    super.key,
    required this.message,
    required this.labels,
    required this.isSentFolder,
    required this.onTap,
    required this.onAvatarTap,
    required this.onLongPress,
    this.useOwnFolder = false,
    this.account,
  });

  final MessageRow message;
  final List<LabelRow> labels;
  final bool isSentFolder;

  /// Tüm Hesaplar görünümünde iletinin ait olduğu hesap (satırda gösterilir);
  /// tek hesap görünümünde `null`.
  final AccountRow? account;

  /// Eylem, görüntülenen klasör yerine iletinin KENDİ klasörüne göre
  /// çözülür. Sabitlenenler bölümü hesabın tüm klasörlerinden ileti içerir
  /// (bkz. [_PinnedSection]); ör. Çöp'teki sabitli ileti "Sil" değil
  /// "Gelen Kutusuna taşı" olmalı.
  final bool useOwnFolder;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;
  final VoidCallback onLongPress;

  @override
  ConsumerState<_SwipeRow> createState() => _SwipeRowState();
}

class _SwipeRowState extends ConsumerState<_SwipeRow> {
  /// Satır genişliğinin bu oranı aşılıp bırakılınca eylem tetiklenir.
  static const double _threshold = 0.35;

  /// Eylem başladı ve satır daralıyor; `Dismissible` ağaçtan çıkmak ZORUNDA
  /// (aksi hâlde Flutter hata verir) — veri akışının satırı kaldırmasını
  /// beklemeden yerine boş bir kutu konur.
  bool _removed = false;

  /// Parmak eşiği aştı: bırakılırsa eylem çalışır (geri bildirim için).
  bool _armed = false;

  void _onUpdate(DismissUpdateDetails details) {
    if (details.reached == _armed) return;
    setState(() => _armed = details.reached);
    if (details.reached) HapticFeedback.selectionClick();
  }

  /// Seçimi klasöre ve iletinin durumuna göre nihai eyleme çevirir
  /// (bkz. `SwipeActionResolver`); arayüz yalnızca bunu çizer ve çalıştırır.
  EffectiveSwipe _effectiveFor(SwipeAction selected, SpecialUse? folder) {
    final message = widget.message;
    return SwipeActionResolver.resolve(
      selected: selected,
      folder: folder,
      isDraftOrLocal: message.isDraft || message.isLocalOnly,
      isSeen: message.isSeen,
      isFlagged: message.isFlagged,
    );
  }

  /// Satırı listeden çıkarmayan eylemler: satır yerinde kalır, eylem
  /// `confirmDismiss` içinde çalışır ve satır geri yerine oturur.
  static bool _staysInPlace(EffectiveSwipe e) =>
      e == EffectiveSwipe.markRead ||
      e == EffectiveSwipe.markUnread ||
      e == EffectiveSwipe.pin ||
      e == EffectiveSwipe.unpin;

  Future<void> _runInPlace(EffectiveSwipe effective) async {
    final repository = ref.read(mailRepositoryProvider);
    final id = widget.message.id;
    switch (effective) {
      case EffectiveSwipe.markRead:
        await repository.setSeen([id], true);
      case EffectiveSwipe.markUnread:
        await repository.setSeen([id], false);
      case EffectiveSwipe.pin:
        await repository.setFlagged([id], true);
      case EffectiveSwipe.unpin:
        await repository.setFlagged([id], false);
      default:
        break;
    }
  }

  /// `confirmDismiss`: silmede (kalıcıysa) onay ister; yerinde kalan
  /// eylemleri burada çalıştırıp `false` döner (satır geri gelir); geri
  /// kalanı için `true` (satır daralıp kaldırılır).
  Future<bool> _confirm(EffectiveSwipe effective) async {
    // İlk kurulum yer tutucusu: eylem yerine Çekme seçeneklerini açar.
    if (effective == EffectiveSwipe.configure) {
      unawaited(context.pushScreen<void>(const SwipeSettingsScreen()));
      return false;
    }
    if (_staysInPlace(effective)) {
      await _runInPlace(effective);
      return false;
    }
    if (effective == EffectiveSwipe.delete) {
      return confirmDelete(context, ref, [widget.message.id]);
    }
    return true;
  }

  Future<void> _onDismissed(
    SwipeAction selected,
    EffectiveSwipe effective,
  ) async {
    setState(() {
      _removed = true;
      _armed = false;
    });
    final id = widget.message.id;
    final database = ref.read(databaseProvider);

    // "Oku ve arşivle": önce okundu işaretlenir, sonra normal arşivle/geri
    // yükle akışı (kendi "Geri al"ıyla) çalışır.
    if (selected == SwipeAction.readAndArchive && !widget.message.isSeen) {
      await ref.read(mailRepositoryProvider).setSeen([id], true);
    }
    if (!mounted) return;

    switch (effective) {
      case EffectiveSwipe.archive:
        await archiveMessages(
          context,
          ref,
          [id],
          bottomInset: _ComposeFab.footprint,
        );
      case EffectiveSwipe.moveToInbox:
        await restoreMessagesToInbox(
          context,
          ref,
          [id],
          bottomInset: _ComposeFab.footprint,
        );
      case EffectiveSwipe.delete:
        await deleteMessagesWithUndo(
          context,
          ref,
          [id],
          bottomInset: _ComposeFab.footprint,
        );
      default:
        break;
    }

    // Eylem satırı gerçekten kaldırmadıysa (ör. sunucu karşılığı olmayan
    // ileti) satır gizli kalıp "kaybolmuş" görünmesin — yerine döner.
    if (!mounted) return;
    if (await database.messageById(id) != null && mounted) {
      setState(() => _removed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_removed) return const SizedBox.shrink();

    final t = context.tokens;
    final isSelected = ref.watch(
      selectionProvider.select(
        (selection) => selection.contains(widget.message.id),
      ),
    );
    // Görüntülenen klasörün türü; Tüm Hesaplar'da birleşik klasörün türü.
    final currentUse = ref.watch(currentSpecialUseProvider);
    // Ayar değişince satırlar canlı güncellenir.
    final rightSelected = ref.watch(
      settingsProvider.select((s) => s.swipeRight),
    );
    final leftSelected = ref.watch(settingsProvider.select((s) => s.swipeLeft));

    final ltr = Directionality.of(context) == TextDirection.ltr;
    // `Dismissible`ın yönleri metin yönüne göredir; FİZİKSEL sağ/sol
    // eşlemesi `Directionality`ye bakılarak yapılır.
    final rightDirection = ltr
        ? DismissDirection.startToEnd
        : DismissDirection.endToStart;
    final leftDirection = ltr
        ? DismissDirection.endToStart
        : DismissDirection.startToEnd;

    final SpecialUse? folder;
    if (widget.useOwnFolder) {
      final boxes = ref.watch(allMailboxesProvider).value ?? const <MailboxRow>[];
      folder = boxes
          .where((b) => b.id == widget.message.mailboxId)
          .firstOrNull
          ?.specialUse;
    } else {
      folder = currentUse;
    }
    final rightEffective = _effectiveFor(rightSelected, folder);
    final leftEffective = _effectiveFor(leftSelected, folder);
    final rightStyle = SwipeStyle.of(rightEffective, t);
    final leftStyle = SwipeStyle.of(leftEffective, t);

    final direction = switch ((rightStyle != null, leftStyle != null)) {
      (true, true) => DismissDirection.horizontal,
      (true, false) => rightDirection,
      (false, true) => leftDirection,
      (false, false) => DismissDirection.none,
    };

    Widget pane(SwipeStyle? style, Alignment alignment) => style == null
        ? const SizedBox.shrink()
        : _SwipeBackground(
            style: style,
            alignment: alignment,
            armed: _armed,
          );
    // Sağa çekince eylem alanı SOLDAN açılır (ve tersi).
    final rightPane = pane(rightStyle, Alignment.centerLeft);
    final leftPane = pane(leftStyle, Alignment.centerRight);

    final message = widget.message;
    return BoundedDismissible(
      key: ValueKey('swipe-${message.id}'),
      direction: direction,
      dismissThresholds: {
        rightDirection: _threshold,
        leftDirection: _threshold,
      },
      resizeDuration: context.motion(Motion.slow),
      movementDuration: context.motion(Motion.base),
      // `background` startToEnd, `secondaryBackground` endToStart içindir.
      background: ltr ? rightPane : leftPane,
      secondaryBackground: ltr ? leftPane : rightPane,
      onUpdate: _onUpdate,
      confirmDismiss: (dir) => _confirm(
        dir == rightDirection ? rightEffective : leftEffective,
      ),
      onDismissed: (dir) => dir == rightDirection
          ? _onDismissed(rightSelected, rightEffective)
          : _onDismissed(leftSelected, leftEffective),
      child: MailRow(
        message: message,
        labels: widget.labels,
        isSelected: isSelected,
        isSentFolder: widget.isSentFolder,
        account: widget.account,
        onTap: widget.onTap,
        onAvatarTap: widget.onAvatarTap,
        onLongPress: widget.onLongPress,
        onUnpin: () =>
            ref.read(mailRepositoryProvider).setFlagged([message.id], false),
        onRemoveLabel: (name) => ref
            .read(mailRepositoryProvider)
            .setLabel(messageIds: [message.id], labelName: name, add: false),
      ),
    );
  }
}

/// Kaydırırken satırın arkasında açılan renkli alan: simge + etiket. Eşik
/// aşılınca simge hafifçe büyüyerek "bırakırsan çalışır" der. Renk, simge ve
/// etiket [SwipeStyle]dan gelir (Çekme seçenekleri önizlemesiyle ortak).
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.style,
    required this.alignment,
    required this.armed,
  });

  final SwipeStyle style;
  final Alignment alignment;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: style.color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
      child: AnimatedScale(
        scale: armed ? 1.15 : 1,
        duration: context.motion(Motion.fast),
        curve: Motion.standard,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(style.icon, size: IconSize.lg, color: style.foreground),
            const SizedBox(height: Space.xs),
            Text(
              style.label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: style.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Listenin üstünde sabitlenmiş TÜM iletiler (Outlook'taki "Pinned" bölümü
/// gibi) — artık bir önizleme değil: burada gösterilen bir ileti aynı anda
/// aşağıdaki kronolojik listede TEKRAR görünmez (bkz. `mailListItemsProvider`
/// içindeki `!m.isFlagged` süzgeci), o yüzden ayrıca "tam listeyi gör"
/// bağlantısına gerek yok.
///
/// Buradaki iletiler geçerli klasörden değil, hesabın tamamından gelir
/// (bkz. [pinnedMessagesProvider]) — bir ileti hangi klasörde olursa olsun
/// sabitlenebilir. Satırlar normal liste gibi kaydırma eylemlerini destekler
/// (bkz. [_SwipeRow]). Bölüm listenin en başındaki NORMAL bir eleman (bkz. [PinnedSectionItem]):
/// ekrana yapışmaz, diğer iletiler arasında kaydırırken o da onlarla
/// birlikte kayıp gözden kaybolur.
///
/// 3'ten fazla sabitli ileti varsa bölüm sonsuza uzamasın diye daraltılabilir
/// bir başlığa döner ("SABİTLENENLER (N)"); azken başlığa gerek yok.
class _PinnedSection extends ConsumerStatefulWidget {
  const _PinnedSection();

  @override
  ConsumerState<_PinnedSection> createState() => _PinnedSectionState();
}

class _PinnedSectionState extends ConsumerState<_PinnedSection> {
  static const _collapseThreshold = 2;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pinned = ref.watch(pinnedMessagesProvider).value ?? const [];
    if (pinned.isEmpty) return const SizedBox.shrink();

    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    final isCollapsible = pinned.length > _collapseThreshold;
    final userExpanded = ref.watch(pinnedSectionExpandedProvider);
    // Az sayıda sabitli iletide daraltma anlamsız — her zaman açık say.
    final expanded = !isCollapsible || userExpanded;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Başlık, sabitli ileti sayısı ne olursa olsun (1 dahil) gösterilir
          // — kullanıcı "Sabitlenenler" bölümünü her zaman net görebilmeli.
          // Yalnızca eşiği aşan sayıda ileti varken daraltılabilir olur.
          isCollapsible
              ? InkWell(
                  onTap: () => ref
                      .read(pinnedSectionExpandedProvider.notifier)
                      .toggle(),
                  child: SectionHeader(
                    'SABİTLENENLER (${pinned.length})',
                    trailing: AnimatedRotation(
                      duration: context.motion(Motion.fast),
                      turns: expanded ? 0.5 : 0,
                      child: Icon(
                        LucideIcons.chevronDown,
                        size: IconSize.sm,
                        color: t.textTertiary,
                      ),
                    ),
                  ),
                )
              : const SectionHeader('SABİTLENENLER'),
          AnimatedSize(
            duration: context.motion(Motion.base),
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: !expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    children: [
                      for (final message in pinned)
                        _PinnedMailRow(
                          key: ValueKey('pinned-${message.id}'),
                          message: message,
                          labels: labels,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Sabitlenenler bölümündeki ileti satırı; kaydırma, seçim ve detay eylemleri
/// normal liste satırıyla aynıdır.
class _PinnedMailRow extends ConsumerWidget {
  const _PinnedMailRow({
    super.key,
    required this.message,
    required this.labels,
  });

  final MessageRow message;
  final List<LabelRow> labels;

  void _openDetail(BuildContext context) =>
      context.pushScreen(MailDetailScreen(messageId: message.id));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tüm Hesaplar'da sabitli satır da hangi hesaba ait olduğunu gösterir.
    final isUnified = ref.watch(isAllAccountsProvider);
    final account = isUnified
        ? ref
              .watch(allAccountsProvider)
              .value
              ?.where((a) => a.id == message.accountId)
              .firstOrNull
        : null;
    return _SwipeRow(
      message: message,
      labels: labels,
      isSentFolder: false,
      useOwnFolder: true,
      account: account,
      onTap: () {
        if (ref.read(selectionProvider).isNotEmpty) {
          ref.read(selectionProvider.notifier).toggle(message.id);
          return;
        }
        _openDetail(context);
      },
      onAvatarTap: () =>
          ref.read(selectionProvider.notifier).toggle(message.id),
      onLongPress: () =>
          ref.read(selectionProvider.notifier).toggle(message.id),
    );
  }
}

/// Seçim modundaki alt eylem çubuğu.
class _SelectionActionBar extends ConsumerWidget {
  const _SelectionActionBar({required this.ids});

  final List<int> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final repository = ref.read(mailRepositoryProvider);
    // Sabitlenenler bölümündeki iletiler başka klasörlerden olabilir; seçim
    // durumları (okundu/sabitli) için onlar da hesaba katılır.
    final messages = [
      ...(ref.watch(messageListProvider).value ?? const <MessageRow>[]),
      ...(ref.watch(pinnedMessagesProvider).value ?? const <MessageRow>[]),
    ];
    final selected = {
      for (final m in messages)
        if (ids.contains(m.id)) m.id: m,
    }.values.toList();
    final allSeen = selected.isNotEmpty && selected.every((m) => m.isSeen);
    final allFlagged =
        selected.isNotEmpty && selected.every((m) => m.isFlagged);
    // Tüm Hesaplar'da seçim birden çok hesaba yayılabilir: klasör ve etiket
    // hesaba özgü olduğundan "Taşı"/"Etiket" yalnızca tek hesaptan seçimde
    // çalışır (arşivle/sil/okundu/sabitle her hesabı kendi içinde işler).
    final selectionAccounts = {for (final m in selected) m.accountId};
    final mixedAccounts = selectionAccounts.length > 1;
    final selectionAccountId =
        selectionAccounts.length == 1 ? selectionAccounts.single : null;

    void done() => ref.read(selectionProvider.notifier).clear();

    return Container(
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _BarAction(
                icon: LucideIcons.archive,
                label: 'Arşivle',
                onTap: () async {
                  await archiveMessages(context, ref, ids);
                  done();
                },
              ),
              _BarAction(
                icon: allSeen ? LucideIcons.mailX : LucideIcons.mailOpen,
                label: allSeen ? 'Okunmadı' : 'Okundu',
                onTap: () async {
                  await repository.setSeen(ids, !allSeen);
                  done();
                },
              ),
              _BarAction(
                icon: allFlagged ? LucideIcons.pinOff : LucideIcons.pin,
                label: allFlagged ? 'Kaldır' : 'Sabitle',
                onTap: () async {
                  await repository.setFlagged(ids, !allFlagged);
                  done();
                },
              ),
              _BarAction(
                icon: LucideIcons.trash2,
                label: 'Sil',
                onTap: () async {
                  final deleted = await deleteWithConfirmation(
                    context,
                    ref,
                    ids,
                  );
                  if (deleted) done();
                },
              ),
              _BarAction(
                icon: LucideIcons.folderInput,
                label: 'Taşı',
                menuChildren: folderMenuItems(ref, (target) async {
                  await repository.moveToFolder(
                    messageIds: ids,
                    targetMailboxId: target.id,
                  );
                  done();
                }, accountId: selectionAccountId, mixedAccounts: mixedAccounts),
              ),
              _BarAction(
                icon: LucideIcons.tag,
                label: 'Etiket',
                menuChildren: labelMenuItems(context, ref, (label) async {
                  await repository.setLabel(
                    messageIds: ids,
                    labelName: label,
                    add: true,
                  );
                  done();
                }, accountId: selectionAccountId, mixedAccounts: mixedAccounts),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Seçim çubuğundaki tek eylem. Ya doğrudan bir eylem yapar ([onTap]) ya da
/// hemen üstüne açılan bir popup gösterir ([menuChildren]) — "Taşı"/"Etiket"
/// gibi bir alt seçim gerektiren eylemler artık tam ekranı kaplayan bir
/// alttan panel yerine bunu kullanır (bkz. bellek: popup'lar modallara
/// tercih edilir).
class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.menuChildren,
  }) : assert(
         (onTap == null) != (menuChildren == null),
         'Ya onTap ya da menuChildren verilmeli, ikisi birden değil.',
       );

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final List<Widget>? menuChildren;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final content = Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: IconSize.md, color: t.textSecondary),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: t.textSecondary),
          ),
        ],
      ),
    );

    final menuItems = menuChildren;
    if (menuItems != null) {
      return Expanded(
        child: MenuAnchor(
          animated: true,
          alignmentOffset: const Offset(0, 8),
          menuChildren: menuItems,
          builder: (context, controller, child) => InkWell(
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: content,
          ),
        ),
      );
    }

    return Expanded(
      child: InkWell(onTap: onTap, child: content),
    );
  }
}

/// Listenin sonundaki "Daha fazla yükle" denetimi.
///
/// Outlook mobil uygulamasındaki "Manuel Kontrollü Sayfalama" gibi bir
/// sonraki sayfa kaydırma sırasında KENDİLİĞİNDEN değil, yalnızca kullanıcı
/// buna dokunduğunda istenir. Ağ isteği kaydırma jestiyle artık aynı anda
/// tetiklenmediği için (bkz. kaldırılan `_onScroll` eşiği) hızlı kaydırmada
/// araya giren durum güncellemeleri kare düşürmez; yeni sayfa yalnızca bu
/// düğmeye basıldığında, öngörülebilir tek bir anda gelir.
///
/// İki durum arasında (mavi, tıklanabilir metin ↔ gri, pasif "Yükleniyor…"
/// metni) yalnızca renk ve tıklanabilirlik değişir — ikisi de aynı
/// `AppText.labelMedium` ölçüsünü kullandığı için geçişte satır yüksekliği
/// sıçramaz.
class _LoadMoreControl extends StatelessWidget {
  const _LoadMoreControl({required this.isLoading, required this.onTap});

  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.lg),
      child: Center(
        child: isLoading
            ? Text(
                'Yükleniyor…',
                style: AppText.labelMedium.copyWith(
                  fontSize: 14 * AppText.scale,
                  color: t.textTertiary,
                ),
              )
            : TextButton(
                onPressed: onTap,
                child: const Text('Daha fazla ileti yükle'),
              ),
      ),
    );
  }
}

/// Listenin gerçek yüklenme durumu — yalnızca `messageListProvider`'ın
/// GERÇEKTEN ilk kez kurulduğu, o hesabın yerelde hiç sorgulanmadığı çok
/// kısa an için çalışır (bkz. `skipLoadingOnReload: true` kullanan çağrı
/// yeri — klasör/filtre/hesap değişimi bunu artık tetiklemiyor). Mail
/// gövdesindeki `_BodyShimmer` ile aynı `ShimmerSurface` mekanizmasını
/// paylaşır: tek bir parlaklık bandı TÜM satırların üzerinde birlikte kayar.
///
/// Satır sayısı sabit değil: `LayoutBuilder` ile bu widget'a ayrılan gerçek
/// viewport yüksekliği (AppBar/SafeArea/alt gezinme zaten ölçüme dahil,
/// çünkü bu widget onların ARASINDAKİ `Expanded` alana yerleşir) satır
/// yüksekliğine (`Dimens.listRowMinHeight`) bölünüp yukarı yuvarlanır —
/// böylece ekran ne kadar uzun olursa olsun iskelet satırları en alta kadar
/// devam eder, sabit "8 satır"ın altında boşluk kalmaz. `ListView.builder`
/// kullanılması (eskiden `Column`) bu yuvarlamanın (son satır viewport'tan
/// az taşabilir) bir taşma hatasına yol açmadan, tembel biçimde çizilmesini
/// sağlar; kaydırma `NeverScrollableScrollPhysics` ile devre dışı bırakılır,
/// yükleniyor durumunda kaydırılacak gerçek içerik yoktur.
class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ShimmerSurface(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height;
          final itemCount = (viewportHeight / Dimens.listRowMinHeight)
              .ceil()
              .clamp(1, 64)
              .toInt();
          return ListView.builder(
            physics: const NeverScrollableScrollPhysics(),
            itemCount: itemCount,
            itemBuilder: (context, index) => const _ListSkeletonRow(),
          );
        },
      ),
    );
  }
}

class _ListSkeletonRow extends StatelessWidget {
  const _ListSkeletonRow();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      // Sabit yükseklik yerine minimum: gerçek MailRow'la aynı kural —
      // Dimens küçüldükçe burada elle senkron tutmaya gerek kalmaz ve
      // içerik sığmadığında taşma hatası vermez.
      constraints: const BoxConstraints(minHeight: Dimens.listRowMinHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: Dimens.avatarSize,
            height: Dimens.avatarSize,
            decoration: BoxDecoration(
              color: t.surface,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                ShimmerBar(width: 140, height: 11),
                SizedBox(height: Space.xs),
                ShimmerBar(widthFactor: 0.85, height: 10),
                SizedBox(height: Space.xs),
                ShimmerBar(widthFactor: 0.65, height: 9),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Filtre menüsü — Gmail'in arama çubuğu yanındaki huni simgesi gibi:
/// düğmenin hemen altına açılan, yumuşak geçişli bir menü (bkz. `animated:
/// true`) — tam ekranı kaplayan bir alttan panel değil. "Etiket ile" ve
/// "Sırala" kendi alt menülerini açar (bkz. [SubmenuButton]), tıpkı
/// referans görüntüdeki gibi.
///
/// Yalnızca bu uygulamada gerçekten filtrelenebilecek alanlar var: okunmamış/
/// sabitli/ek dosyalı bayrakları, etiket ve sıralama. Şifreleme/imza/davet
/// gibi Gmail'e özgü alanların burada karşılığı yok.
///
/// Onay/kaydet düğmesi yoktur: her dokunuş anında [messageFilterProvider]'a
/// yazılır ve liste canlı güncellenir. Onay kutuları (`closeOnActivate:
/// false`) art arda işaretlenebilsin diye menüyü kapatmaz; bir etiket veya
/// sıralama seçmek tek seferlik bir karar olduğu için menüyü (PopupMenuButton
/// mantığında olduğu gibi) kapatır.
class _FilterMenuButton extends ConsumerWidget {
  const _FilterMenuButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final filter = ref.watch(messageFilterProvider);
    final notifier = ref.read(messageFilterProvider.notifier);
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];

    return MenuAnchor(
      animated: true,
      menuChildren: [
        _FilterOptionButton(
          icon: LucideIcons.mailOpen,
          label: 'Okunmamış',
          selected: filter.unreadOnly,
          onPressed: () => notifier.setUnreadOnly(!filter.unreadOnly),
        ),
        _FilterOptionButton(
          icon: LucideIcons.pin,
          label: 'Sabitlenmiş',
          selected: filter.flaggedOnly,
          onPressed: () => notifier.setFlaggedOnly(!filter.flaggedOnly),
        ),
        _FilterOptionButton(
          icon: LucideIcons.paperclip,
          label: 'Ek dosyalı',
          selected: filter.withAttachmentsOnly,
          onPressed: () =>
              notifier.setWithAttachmentsOnly(!filter.withAttachmentsOnly),
        ),
        const Divider(height: 1),
        if (labels.isNotEmpty)
          SubmenuButton(
            animated: true,
            leadingIcon: const Icon(LucideIcons.tag),
            menuChildren: [
              RadioMenuButton<String?>(
                value: null,
                groupValue: filter.labelName,
                onChanged: notifier.setLabel,
                child: const Text('Tümü'),
              ),
              for (final label in labels)
                RadioMenuButton<String?>(
                  value: label.name,
                  groupValue: filter.labelName,
                  onChanged: notifier.setLabel,
                  child: _iconLabel(
                    LucideIcons.tag,
                    label.name,
                    color: t.toneAt(label.toneIndex).foreground,
                  ),
                ),
            ],
            child: const Text('Etiket ile'),
          ),
        SubmenuButton(
          animated: true,
          leadingIcon: const Icon(LucideIcons.arrowUpDown),
          menuChildren: [
            for (final sort in MessageSort.values)
              RadioMenuButton<MessageSort>(
                value: sort,
                groupValue: filter.sort,
                onChanged: (value) {
                  if (value != null) notifier.setSort(value);
                },
                child: Text(_sortLabel(sort)),
              ),
          ],
          child: const Text('Sırala'),
        ),
        if (filter.isActive) ...[
          const Divider(height: 1),
          MenuItemButton(
            onPressed: notifier.clear,
            leadingIcon: Icon(LucideIcons.x, color: t.danger),
            child: Text('Filtreyi temizle', style: TextStyle(color: t.danger)),
          ),
        ],
      ],
      builder: (context, controller, child) {
        // Üst çubuğun kendi ana metin rengi (`onAppBar`) — açık temada beyaz,
        // koyu temada `textPrimary`. Pilin zemini bilerek üst çubuktan
        // (`appBarBg`) ayrışan `accentStrong` tonundadır, aksi halde referans
        // görseldeki gibi düğme header'ın içinde görünmez olurdu.
        final onAppBar =
            Theme.of(context).appBarTheme.foregroundColor ?? t.textPrimary;
        return Padding(
          padding: const EdgeInsets.only(right: Space.xs),
          child: Material(
            color: t.accentStrong,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Filtrele',
                      style: AppText.labelMedium.copyWith(
                        color: onAppBar,
                        fontSize: 13 * AppText.scale,
                      ),
                    ),
                    if (filter.isActive) ...[
                      const SizedBox(width: Space.xs),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: onAppBar,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget _iconLabel(IconData icon, String text, {Color? color}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: IconSize.sm, color: color),
      const SizedBox(width: Space.sm),
      Text(text),
    ],
  );

  static String _sortLabel(MessageSort sort) => switch (sort) {
    MessageSort.dateDesc => 'Tarih (yeni önce)',
    MessageSort.dateAsc => 'Tarih (eski önce)',
    MessageSort.senderAZ => 'Gönderene göre (A-Z)',
    MessageSort.subjectAZ => 'Konuya göre (A-Z)',
  };
}

/// Filtre menüsündeki tek bir aç/kapa satırı — alttaki "Etiket ile"/"Sırala"
/// [SubmenuButton]'larıyla AYNI [MenuItemButton] yuvalarını kullanır
/// (`leadingIcon`/`child`/`trailingIcon`): böylece yazı tipi, ikon boyutu ve
/// satır yüksekliği menünün geri kalanıyla otomatik olarak birebir eşleşir —
/// yalnızca sağdaki ok yerine seçili durumu gösteren bir radyo halkası var
/// (bkz. [_FilterRadioMark]). Altta yatan durum hâlâ bağımsız aç/kapa
/// (checkbox mantığı, [notifier]'daki `setX` çağrıları birbirini
/// etkilemez) — yalnızca görünüm referans görseldeki radyo düğmesine
/// benzetildi.
class _FilterOptionButton extends StatelessWidget {
  const _FilterOptionButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accentColor = selected ? t.accent : null;

    return MenuItemButton(
      onPressed: onPressed,
      closeOnActivate: false,
      leadingIcon: Icon(icon, color: accentColor),
      trailingIcon: _FilterRadioMark(
        selected: selected,
        color: selected ? t.accent : t.textTertiary,
      ),
      child: Text(
        label,
        style: accentColor == null
            ? null
            : TextStyle(color: accentColor, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// [_FilterOptionButton]'ın sağındaki durum göstergesi — referans görseldeki
/// gibi düz bir daire: seçili değilken ince bir halka, seçiliyken dolu bir
/// iç noktayla vurgulanan bir halka.
class _FilterRadioMark extends StatelessWidget {
  const _FilterRadioMark({required this.selected, required this.color});

  final bool selected;
  final Color color;

  static const double _diameter = 20;
  static const double _dotDiameter = 10;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: Motion.standard,
      width: _diameter,
      height: _diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
      child: AnimatedSwitcher(
        duration: context.motion(Motion.fast),
        child: selected
            ? Center(
                key: const ValueKey(true),
                child: Container(
                  width: _dotDiameter,
                  height: _dotDiameter,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                ),
              )
            : const SizedBox.shrink(key: ValueKey(false)),
      ),
    );
  }
}

/// Gelen Kutusu normal-mod üst çubuğu.
///
/// ┌──────────────────────────────────────────────────────┐
/// │  [Avatar]  Başlık                    [Search][Filter]│
/// │            hesap@adres.com                           │
/// └──────────────────────────────────────────────────────┘
///
/// Outlook'taki gibi: hamburger buton yok. Avatar'a dokunmak drawer'ı açar.
/// - Avatar: [KaydetAvatar] — mail satırlarıyla aynı ton sistemi (FNV-1a).
/// - Başlık + email ikili hiyerarşi: [Column] içinde tek [Expanded].
/// - Uzun email adresi ellipsis ile kesilir, butonlara taşmaz.
/// - Tüm renkler [KaydetTokens]'dan gelir; widget içinde ham renk yok.
/// - [PreferredSizeWidget] uygular — normal [AppBar] ile değiştirilebilir.
class _InboxAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _InboxAppBar({
    required this.title,
    required this.account,
    required this.isAllAccounts,
    required this.onMenuTap,
    required this.onSearchTap,
    required this.filterButton,
  });

  final String title;
  final AccountRow? account;

  /// Tüm Hesaplar görünümü: tek bir hesabın avatarı/e-postası yerine
  /// Home simgesi ve "Tüm Hesaplar" yazar.
  final bool isAllAccounts;

  /// Drawer'ı açan callback — avatar'a dokunulduğunda tetiklenir.
  final VoidCallback onMenuTap;
  final VoidCallback onSearchTap;
  final Widget filterButton;

  // Kullanıcı isteğiyle büyütüldü: hangi hesapta olunduğu tek bakışta
  // net görünsün diye avatar ve başlık/email yazı boyutları standart
  // `Dimens.avatarSize`/`AppText.titleMedium`'un üzerine çıkarılır.
  // Bunlar liste satırlarındaki avatarla PAYLAŞILMAZ — yalnızca bu
  // üst çubuğa özeldir, o yüzden global token yerine yerel sabitler.
  static const double _avatarSize = 44;
  static const double _barHeight = 68;

  @override
  Size get preferredSize => const Size.fromHeight(_barHeight);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final account = this.account;

    return Material(
      color: t.appBarBg,
      elevation: theme.appBarTheme.elevation ?? 0,
      shadowColor: theme.appBarTheme.shadowColor,
      surfaceTintColor: theme.appBarTheme.surfaceTintColor,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: _barHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Hesap avatarı (drawer tetikleyici) ───────────────────────
              // Outlook'taki gibi: avatar'a dokunmak hamburger menünün
              // yerini alır. InkWell doğrudan avatar etrafında — circular
              // splash, Material inkwell üstüne yazılır.
              Semantics(
                button: true,
                label: 'Klasörleri göster',
                child: Tooltip(
                  message: 'Klasörler',
                  child: InkWell(
                    onTap: onMenuTap,
                    borderRadius: BorderRadius.circular(Radii.full),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.md,
                        vertical: Space.sm,
                      ),
                      child: isAllAccounts
                          ? Container(
                              width: _avatarSize,
                              height: _avatarSize,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: t.onAccentFill.withValues(alpha: 0.22),
                              ),
                              child: ImageIcon(
                                const AssetImage('assets/icons/home.png'),
                                size: IconSize.lg,
                                color:
                                    theme.appBarTheme.iconTheme?.color ??
                                    theme.appBarTheme.foregroundColor ??
                                    t.onAccentFill,
                              ),
                            )
                          : account != null
                          ? KaydetAvatar(
                              name: account.displayName,
                              email: account.email,
                              size: _avatarSize,
                            )
                          // Hesap yüklenmemişse sade bir yer tutucu ikon.
                          : Icon(
                              LucideIcons.menu,
                              size: _avatarSize,
                              color:
                                  theme.appBarTheme.iconTheme?.color ??
                                  theme.appBarTheme.foregroundColor ??
                                  t.textPrimary,
                            ),
                    ),
                  ),
                ),
              ),

              // ── Başlık + email adresi ─────────────────────────────────
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.titleMedium.copyWith(
                        fontSize: 17 * AppText.scale,
                        fontWeight: FontWeight.w700,
                        color:
                            theme.appBarTheme.titleTextStyle?.color ??
                            t.textPrimary,
                      ),
                    ),
                    if (isAllAccounts || account != null)
                      Text(
                        isAllAccounts ? 'Tüm Hesaplar' : account!.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyMedium.copyWith(
                          fontSize: 13 * AppText.scale,
                          fontWeight: FontWeight.w500,
                          // Üst çubuğun kendi ana metin rengi (`onAppBar`)
                          // hafif saydamlaştırılır — başlıkla aynı beyaz
                          // yerine ikincil bir hiyerarşi kalsın diye.
                          color:
                              (theme.appBarTheme.titleTextStyle?.color ??
                                      t.textSecondary)
                                  .withValues(alpha: 0.82),
                        ),
                      ),
                  ],
                ),
              ),

              // ── Arama butonu ──────────────────────────────────────────
              IconButton(
                icon: const Icon(LucideIcons.search),
                tooltip: 'Ara',
                color:
                    theme.appBarTheme.actionsIconTheme?.color ??
                    theme.appBarTheme.iconTheme?.color ??
                    theme.appBarTheme.foregroundColor ??
                    t.textPrimary,
                onPressed: onSearchTap,
              ),

              // ── Filtre butonu ─────────────────────────────────────────
              filterButton,

              const SizedBox(width: Space.xs),
            ],
          ),
        ),
      ),
    );
  }
}

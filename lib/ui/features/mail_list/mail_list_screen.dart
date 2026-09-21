import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/actions/message_actions.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_launcher.dart';
import '../mail_detail/mail_detail_screen.dart';
import '../search/search_screen.dart';
import 'mail_row.dart';

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
    // Yalnızca "Tümünü seç" için ham id listesi gerekiyor — gövde artık
    // `mailListItemsProvider`den okunuyor (bkz. aşağısı), bu yüzden bu akışı
    // burada ikinci kez gruplamıyoruz.
    final messages = ref.watch(messageListProvider);
    final itemsAsync = ref.watch(mailListItemsProvider);
    final selection = ref.watch(selectionProvider);
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final sync = ref.watch(syncControllerProvider);
    final mailbox = ref.watch(currentMailboxProvider);
    final folder = ref.watch(selectedFolderProvider);
    final filterFlaggedOnly = ref.watch(
      messageFilterProvider.select((f) => f.flaggedOnly),
    );
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];

    final isSentLike =
        mailbox != null &&
        (mailbox.specialUse == SpecialUse.sent ||
            mailbox.specialUse == SpecialUse.drafts);

    final scaffold = Scaffold(
      appBar: _buildAppBar(
        context,
        isSelectionMode: isSelectionMode,
        selectionCount: selection.length,
        visibleIds: messages.value?.map((m) => m.id).toList() ?? const [],
        title: folder?.isFlaggedView == true
            ? 'Sabitlenenler'
            : (mailbox?.name ?? 'Kaydet'),
      ),
      body: Column(
        children: [
          if (sync.isOffline)
            const StatusBanner(
              message:
                  'Çevrimdışısınız. Değişiklikleriniz kaydedildi, '
                  'bağlantı gelince gönderilecek.',
              icon: LucideIcons.cloudOff,
            ),
          if (sync.lastError != null && !sync.isOffline)
            StatusBanner(
              message: sync.lastError!.userMessage,
              icon: LucideIcons.triangleAlert,
              color: t.danger,
              actionLabel: 'Yeniden dene',
              onAction: () =>
                  ref.read(syncControllerProvider.notifier).syncCurrentFolder(),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(syncControllerProvider.notifier).syncCurrentFolder(),
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
                      isLoadingMore: sync.isLoadingMore,
                      hasMore:
                          sync.hasMore && mailbox?.hasMoreOnServer == true,
                      rowLeavesViewOnFlagToggle:
                          (items.isNotEmpty &&
                              items.first is PinnedSectionItem) ||
                          folder?.isFlaggedView == true ||
                          filterFlaggedOnly,
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
              builder: (context, isAtTop, _) => _ComposeFab(
                isExpanded: isAtTop,
                onPressed: _openCompose,
              ),
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
    required bool rowLeavesViewOnFlagToggle,
  }) {
    return ListView.builder(
      key: const PageStorageKey('mail-list'),
      controller: _scroll,
      // Boş olsa da aşağı çekerek yenileme çalışmalı.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      // Varsayılan 250px'lik ön-inşa alanı hızlı kaydırmada avatar/logoların
      // "pop-in" etmesine yol açıyordu; ~3 ekran yüksekliği önden inşa edilir.
      cacheExtent: 1200,
      itemCount: items.length + (hasMore || isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return _LoadMoreControl(
            isLoading: isLoadingMore,
            onTap: () => ref.read(syncControllerProvider.notifier).loadMore(),
          );
        }
        return switch (items[index]) {
          PinnedSectionItem() => const _PinnedSection(),
          EmptyListItem(:final filterActive) => SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: _emptyState(filterActive),
          ),
          DateHeaderItem(:final label) => SectionHeader(label),
          MessageItem(:final message) => _SlidableRow(
            key: ValueKey(message.id),
            message: message,
            labels: labels,
            isSentFolder: isSentLike,
            leavesViewOnFlagToggle: rowLeavesViewOnFlagToggle,
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
    // Outlook/iOS'taki "slide over" gibi: Compose sağdan kayarak gelip
    // Gelen Kutusu'nun üzerine yerleşir; Gelen Kutusu tamamen sabit kalır.
    transitionStyle: KaydetTransitionStyle.horizontalPush,
    // "Taslağa kaydedildi" bildirimi "Yeni" düğmesinin üstünde durur.
    noticeBottomInset: _ComposeFab.footprint,
  );

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required bool isSelectionMode,
    required int selectionCount,
    required List<int> visibleIds,
    required String title,
  }) {
    final t = context.tokens;

    if (isSelectionMode) {
      final allSelected =
          visibleIds.isNotEmpty && selectionCount >= visibleIds.length;
      return AppBar(
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

    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.menu),
        tooltip: 'Klasörler',
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
      title: Text(title),
      actions: [
        const _FilterMenuButton(),
        IconButton(
          icon: const Icon(LucideIcons.search),
          tooltip: 'Ara',
          onPressed: () => context.pushScreen(const SearchScreen()),
        ),
        const SizedBox(width: Space.xs),
      ],
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

/// Kaydırma hareketleriyle arşivle / sil.
///
/// Seçim durumunu kendi diliminden (`selectionProvider.select`) okur —
/// ebeveynden parametre olarak almaz. Böylece bir satır seçildiğinde/
/// seçimi kaldırıldığında SADECE o satırın widget'ı yeniden çizilir,
/// listedeki diğer görünür satırlar etkilenmez.
///
/// [leavesViewOnFlagToggle] doğruysa (Gelen Kutusu'nda sabitlenenler bölümü
/// gösteriliyorken sabitlemek, ya da "Sabitlenenler" sanal klasöründe/
/// "yalnızca sabitlenenler" filtresinde sabitlemeyi kaldırmak — bkz.
/// `MailListScreen.build`), raptiyeye dokunmak satırı listeden aniden
/// ışınlamak yerine önce nazikçe küçültüp söndürür; asıl `isFlagged`
/// durumu bu görsel geçiş bittikten SONRA veritabanına yazılır (bkz.
/// [_PinnedMailRowState._unpin] — aynı desen), böylece satırın listeden
/// çıkışı sert bir sıçrama değil buradan ayrılan bir hareket gibi
/// hissettirir. Diğer durumlarda (satır sabitleme sonrası da görünür
/// kalacaksa) gecikmeye gerek yok — arka plan rengi zaten `MailRow`
/// içindeki `AnimatedContainer` ile yumuşakça geçiyor.
class _SlidableRow extends ConsumerStatefulWidget {
  const _SlidableRow({
    super.key,
    required this.message,
    required this.labels,
    required this.isSentFolder,
    required this.leavesViewOnFlagToggle,
    required this.onTap,
    required this.onAvatarTap,
    required this.onLongPress,
  });

  final MessageRow message;
  final List<LabelRow> labels;
  final bool isSentFolder;
  final bool leavesViewOnFlagToggle;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;
  final VoidCallback onLongPress;

  @override
  ConsumerState<_SlidableRow> createState() => _SlidableRowState();
}

class _SlidableRowState extends ConsumerState<_SlidableRow> {
  bool _hiding = false;

  Future<void> _toggleFlag() async {
    final repository = ref.read(mailRepositoryProvider);
    final nextFlagged = !widget.message.isFlagged;
    if (!widget.leavesViewOnFlagToggle) {
      await repository.setFlagged([widget.message.id], nextFlagged);
      return;
    }
    setState(() => _hiding = true);
    await Future.delayed(context.motion(Motion.base));
    if (!mounted) return;
    await repository.setFlagged([widget.message.id], nextFlagged);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final repository = ref.read(mailRepositoryProvider);
    final isSelected = ref.watch(
      selectionProvider.select(
        (selection) => selection.contains(widget.message.id),
      ),
    );

    return AnimatedSize(
      duration: context.motion(Motion.base),
      curve: Motion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: context.motion(Motion.fast),
        opacity: _hiding ? 0 : 1,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: _hiding ? 0 : 1,
          child: Slidable(
            key: ValueKey('slide-${widget.message.id}'),
            startActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.28,
              children: [
                SlidableAction(
                  onPressed: (_) => repository.archive([widget.message.id]),
                  backgroundColor: t.success,
                  foregroundColor: Colors.white,
                  icon: LucideIcons.archive,
                  label: 'Arşivle',
                ),
              ],
            ),
            endActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.28,
              children: [
                SlidableAction(
                  onPressed: (_) =>
                      deleteWithConfirmation(context, ref, [
                        widget.message.id,
                      ]),
                  backgroundColor: t.dangerFill,
                  foregroundColor: Colors.white,
                  icon: LucideIcons.trash2,
                  label: 'Sil',
                ),
              ],
            ),
            child: MailRow(
              message: widget.message,
              labels: widget.labels,
              isSelected: isSelected,
              isSentFolder: widget.isSentFolder,
              onTap: widget.onTap,
              onAvatarTap: widget.onAvatarTap,
              onLongPress: widget.onLongPress,
              onFlagTap: _toggleFlag,
            ),
          ),
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
/// sabitlenebilir. Kaydırma eylemleri (arşivle/sil) burada yok — bunun
/// dışında listenin en başındaki NORMAL bir eleman (bkz. [PinnedSectionItem]):
/// ekrana yapışmaz, diğer iletiler arasında kaydırırken o da onlarla
/// birlikte kayıp gözden kaybolur.
///
/// 3'ten fazla sabitli ileti varsa bölüm sonsuza uzamasın diye daraltılabilir
/// bir başlığa döner ("SABİTLENENLER (N)"); azken başlığa gerek yok — her
/// satırın hafif mavi vurgulu arka planı (bkz. `MailRow.isFlagged`) neden
/// üstte olduklarını zaten anlatıyor.
class _PinnedSection extends ConsumerStatefulWidget {
  const _PinnedSection();

  @override
  ConsumerState<_PinnedSection> createState() => _PinnedSectionState();
}

class _PinnedSectionState extends ConsumerState<_PinnedSection> {
  static const _collapseThreshold = 3;

  bool? _userExpanded;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pinned = ref.watch(pinnedMessagesProvider).value ?? const [];
    if (pinned.isEmpty) return const SizedBox.shrink();

    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    final isCollapsible = pinned.length > _collapseThreshold;
    // Az sayıda sabitli iletide daraltma anlamsız — her zaman açık say.
    final expanded = !isCollapsible || (_userExpanded ?? false);

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isCollapsible)
            InkWell(
              onTap: () => setState(() => _userExpanded = !expanded),
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
            ),
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

/// Sabitlenenler bölümündeki tek satır: raptiye ikonuna dokunmak iletiyi
/// aniden listeden ışınlamak yerine önce nazikçe küçültüp söndürür — asıl
/// `isFlagged` durumu bu görsel geçiş bittikten SONRA veritabanına yazılır
/// (bkz. [_unpin]), böylece iletinin aşağıdaki kronolojik gruba geri
/// gönderilmesi ani bir sıçrama gibi değil, buradan ayrılan bir hareket
/// gibi hissettirir.
class _PinnedMailRow extends ConsumerStatefulWidget {
  const _PinnedMailRow({
    super.key,
    required this.message,
    required this.labels,
  });

  final MessageRow message;
  final List<LabelRow> labels;

  @override
  ConsumerState<_PinnedMailRow> createState() => _PinnedMailRowState();
}

class _PinnedMailRowState extends ConsumerState<_PinnedMailRow> {
  bool _removing = false;

  Future<void> _unpin() async {
    setState(() => _removing = true);
    await Future.delayed(context.motion(Motion.base));
    if (!mounted) return;
    await ref
        .read(mailRepositoryProvider)
        .setFlagged([widget.message.id], false);
  }

  void _openDetail() =>
      context.pushScreen(MailDetailScreen(messageId: widget.message.id));

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: context.motion(Motion.base),
      curve: Motion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: context.motion(Motion.fast),
        opacity: _removing ? 0 : 1,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: _removing ? 0 : 1,
          child: MailRow(
            message: widget.message,
            labels: widget.labels,
            isSelected: false,
            isSentFolder: false,
            onTap: _openDetail,
            onAvatarTap: _openDetail,
            onLongPress: () {},
            onFlagTap: _unpin,
          ),
        ),
      ),
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
    final messages = ref.watch(messageListProvider).value ?? const [];
    final selected = messages.where((m) => ids.contains(m.id)).toList();
    final allSeen = selected.isNotEmpty && selected.every((m) => m.isSeen);
    final allFlagged =
        selected.isNotEmpty && selected.every((m) => m.isFlagged);

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
                icon: LucideIcons.archive,
                label: 'Arşivle',
                onTap: () async {
                  await repository.archive(ids);
                  done();
                },
              ),
              _BarAction(
                icon: LucideIcons.folderInput,
                label: 'Taşı',
                menuChildren: folderMenuItems(ref, (target) async {
                  await repository.moveToMailbox(
                    messageIds: ids,
                    target: target,
                  );
                  done();
                }),
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
                }),
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
/// paylaşır: tek bir parlaklık bandı 8 satırın TAMAMI üzerinde birlikte
/// kayar.
class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ShimmerSurface(
      child: Column(
        children: [
          for (var i = 0; i < 8; i++)
            Container(
              // Sabit yükseklik yerine minimum: gerçek MailRow'la aynı
              // kural — Dimens küçüldükçe burada elle senkron tutmaya
              // gerek kalmaz ve içerik sığmadığında taşma hatası vermez.
              constraints: const BoxConstraints(
                minHeight: Dimens.listRowMinHeight,
              ),
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
                        ShimmerBar(widthFactor: 1, height: 10),
                      ],
                    ),
                  ),
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
        CheckboxMenuButton(
          value: filter.unreadOnly,
          onChanged: (value) => notifier.setUnreadOnly(value ?? false),
          closeOnActivate: false,
          child: _iconLabel(LucideIcons.mailOpen, 'Okunmamış'),
        ),
        CheckboxMenuButton(
          value: filter.flaggedOnly,
          onChanged: (value) => notifier.setFlaggedOnly(value ?? false),
          closeOnActivate: false,
          child: _iconLabel(LucideIcons.pin, 'Sabitlenmiş'),
        ),
        CheckboxMenuButton(
          value: filter.withAttachmentsOnly,
          onChanged: (value) => notifier.setWithAttachmentsOnly(value ?? false),
          closeOnActivate: false,
          child: _iconLabel(LucideIcons.paperclip, 'Ek dosyalı'),
        ),
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
      builder: (context, controller, child) => IconButton(
        icon: Badge(
          isLabelVisible: filter.isActive,
          smallSize: 8,
          backgroundColor: t.accent,
          child: const Icon(LucideIcons.filter),
        ),
        tooltip: 'Filtrele',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
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

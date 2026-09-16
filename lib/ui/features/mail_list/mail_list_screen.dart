import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/actions/message_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_screen.dart';
import '../mail_detail/mail_detail_screen.dart';
import 'mail_row.dart';

/// Mail listesi — uygulamanın merkezi.
class MailListScreen extends ConsumerStatefulWidget {
  const MailListScreen({super.key});

  @override
  ConsumerState<MailListScreen> createState() => _MailListScreenState();
}

class _MailListScreenState extends ConsumerState<MailListScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchField = TextEditingController();

  // Liste en üstteyken "Yeni ileti" FAB'ı genişler (ikon + yazı); aşağı
  // kaydırılınca daralıp sadece ikon kalır (Gmail'deki gibi).
  //
  // `ValueNotifier` kullanılır: `setState` ile tutulsaydı üst sınırı her
  // geçişte `_MailListScreenState.build()` tümüyle yeniden çalışır —
  // AppBar, tarih gruplama (`_groupByDate`) ve `ListView.builder`'ın
  // yeniden kurulması dahil — ve bu tam kaydırmanın ortasında gözle görülür
  // bir takılmaya yol açıyordu. `ValueListenableBuilder` yalnızca FAB'ı
  // dinlediği için artık yalnızca o widget yeniden çiziliyor.
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
    _searchField.dispose();
    _isAtTop.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // Son ekranın 400 piksel öncesinde bir sonraki sayfayı iste.
    if (position.pixels >= position.maxScrollExtent - 400) {
      ref.read(syncControllerProvider.notifier).loadMore();
    }

    _isAtTop.value = position.pixels <= 8;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final messages = ref.watch(messageListProvider);
    final selection = ref.watch(selectionProvider);
    final isSelectionMode = selection.isNotEmpty;
    final isSearchOpen = ref.watch(isSearchOpenProvider);
    final sync = ref.watch(syncControllerProvider);
    final mailbox = ref.watch(currentMailboxProvider);
    final folder = ref.watch(selectedFolderProvider);
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];

    final isSentLike =
        mailbox != null &&
        (mailbox.specialUse == SpecialUse.sent ||
            mailbox.specialUse == SpecialUse.drafts);

    return Scaffold(
      appBar: _buildAppBar(
        context,
        isSelectionMode: isSelectionMode,
        isSearchOpen: isSearchOpen,
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
          if (sync.isSyncing)
            LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: t.accent,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(syncControllerProvider.notifier).syncCurrentFolder(),
              color: t.accent,
              backgroundColor: t.surfaceElevated,
              child: messages.when(
                loading: () => const _ListSkeleton(),
                error: (error, _) => EmptyState(
                  icon: LucideIcons.triangleAlert,
                  title: 'Liste yüklenemedi',
                  description: '$error',
                ),
                data: (rows) => _buildList(
                  context,
                  rows: rows,
                  labels: labels,
                  selection: selection,
                  isSentLike: isSentLike,
                  isLoadingMore: sync.isLoadingMore,
                  hasMore: sync.hasMore && mailbox?.hasMoreOnServer == true,
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
                onPressed: () => _openCompose(context),
              ),
            ),
      bottomNavigationBar: isSelectionMode
          ? _SelectionActionBar(ids: selection.toList())
          : null,
    );
  }

  Widget _buildList(
    BuildContext context, {
    required List<MessageRow> rows,
    required List<LabelRow> labels,
    required Set<int> selection,
    required bool isSentLike,
    required bool isLoadingMore,
    required bool hasMore,
  }) {
    if (rows.isEmpty) {
      final query = ref.read(searchQueryProvider);
      return ListView(
        // Boş olsa da aşağı çekerek yenileme çalışmalı.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: query.isNotEmpty
                ? const EmptyState(
                    icon: LucideIcons.search,
                    title: 'Sonuç bulunamadı',
                    description: 'Farklı bir arama deneyin.',
                  )
                : const EmptyState(
                    icon: LucideIcons.inbox,
                    title: 'Bu klasör boş',
                    description: 'Yeni iletiler geldiğinde burada görünecek.',
                  ),
          ),
        ],
      );
    }

    final items = _groupByDate(rows);

    return ListView.builder(
      key: const PageStorageKey('mail-list'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: items.length + (hasMore || isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return _LoadMoreIndicator(isLoading: isLoadingMore);
        }
        return switch (items[index]) {
          _HeaderItem(:final label) => SectionHeader(label),
          _MessageItem(:final message) => _SlidableRow(
            key: ValueKey(message.id),
            message: message,
            labels: labels,
            isSelected: selection.contains(message.id),
            isSentFolder: isSentLike,
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

  /// İletileri `dateUtc`'ye göre "Bugün / Dün / Geçen Hafta / …" başlıkları
  /// altında gruplar. `rows` zaten tarihe göre yeniden-eskiye sıralı geldiği
  /// için (bkz. `watchMessages`) tek geçişte ardışık grup değişimini
  /// yakalamak yeterli.
  List<_ListItem> _groupByDate(List<MessageRow> rows) {
    final items = <_ListItem>[];
    String? lastLabel;
    for (final message in rows) {
      final label = formatGroupHeader(message.dateUtc);
      if (label != lastLabel) {
        items.add(_HeaderItem(label));
        lastLabel = label;
      }
      items.add(_MessageItem(message));
    }
    return items;
  }

  Future<void> _onRowTap(MessageRow message) async {
    if (ref.read(selectionProvider).isNotEmpty) {
      ref.read(selectionProvider.notifier).toggle(message.id);
      return;
    }

    // Taslak ve gönderilememiş iletiler yazma ekranında açılır.
    if (message.isDraft || message.outboxState == OutboxState.failed) {
      await _openCompose(context, draftId: message.id);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MailDetailScreen(messageId: message.id),
      ),
    );
  }

  Future<void> _openCompose(BuildContext context, {int? draftId}) async {
    final savedDraftId = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) => ComposeScreen(draftId: draftId),
        fullscreenDialog: true,
      ),
    );
    if (savedDraftId != null && context.mounted) {
      showDraftSavedSnackBar(context, ref, savedDraftId);
    }
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required bool isSelectionMode,
    required bool isSearchOpen,
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

    if (isSearchOpen) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Aramayı kapat',
          onPressed: () {
            _searchField.clear();
            ref.read(isSearchOpenProvider.notifier).close();
          },
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _searchField,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(
            hintText: 'Konu, gönderen veya içerikte ara…',
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (value) =>
              ref.read(searchQueryProvider.notifier).update(value),
        ),
        actions: [
          if (_searchField.text.isNotEmpty)
            IconButton(
              icon: const Icon(LucideIcons.x, size: IconSize.md),
              tooltip: 'Temizle',
              onPressed: () {
                _searchField.clear();
                ref.read(searchQueryProvider.notifier).clear();
                setState(() {});
              },
            ),
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
        IconButton(
          icon: const Icon(LucideIcons.search),
          tooltip: 'Ara',
          onPressed: () => ref.read(isSearchOpenProvider.notifier).open(),
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
class _SlidableRow extends ConsumerWidget {
  const _SlidableRow({
    super.key,
    required this.message,
    required this.labels,
    required this.isSelected,
    required this.isSentFolder,
    required this.onTap,
    required this.onAvatarTap,
    required this.onLongPress,
  });

  final MessageRow message;
  final List<LabelRow> labels;
  final bool isSelected;
  final bool isSentFolder;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final repository = ref.read(mailRepositoryProvider);

    return Slidable(
      key: ValueKey('slide-${message.id}'),
      startActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.28,
        children: [
          SlidableAction(
            onPressed: (_) => repository.archive([message.id]),
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
                deleteWithConfirmation(context, ref, [message.id]),
            backgroundColor: t.dangerFill,
            foregroundColor: Colors.white,
            icon: LucideIcons.trash2,
            label: 'Sil',
          ),
        ],
      ),
      child: MailRow(
        message: message,
        labels: labels,
        isSelected: isSelected,
        isSentFolder: isSentFolder,
        onTap: onTap,
        onAvatarTap: onAvatarTap,
        onLongPress: onLongPress,
        onFlagTap: () =>
            repository.setFlagged([message.id], !message.isFlagged),
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
                onTap: () async {
                  final target = await showFolderPicker(context, ref);
                  if (target == null) return;
                  await repository.moveToMailbox(
                    messageIds: ids,
                    target: target,
                  );
                  done();
                },
              ),
              _BarAction(
                icon: LucideIcons.tag,
                label: 'Etiket',
                onTap: () async {
                  final label = await showLabelPicker(context, ref);
                  if (label == null) return;
                  await repository.setLabel(
                    messageIds: ids,
                    labelName: label,
                    add: true,
                  );
                  done();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Semantics(
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
        ),
      ),
    );
  }
}

class _LoadMoreIndicator extends StatelessWidget {
  const _LoadMoreIndicator({required this.isLoading});

  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxl),
      child: Center(
        child: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.accent,
                ),
              )
            : Text(
                'Daha fazlası için kaydırın',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
              ),
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListView.builder(
      itemCount: 8,
      physics: const NeverScrollableScrollPhysics(),
      itemBuilder: (context, index) => Container(
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
                children: [
                  Container(height: 11, width: 140, color: t.surface),
                  const SizedBox(height: Space.xs),
                  Container(
                    height: 10,
                    width: double.infinity,
                    color: t.surface,
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

/// Silme işlemini yürütür; kalıcı silmede onay ister.
///
/// Çöp Kutusu ve İstenmeyen klasörlerinde silme sunucudan da KALICI olarak
/// siler; geri dönüşü yoktur. Onay istenmezse kullanıcı tek dokunuşla
/// iletisini kalıcı olarak kaybedebilir.
/// Mail listesindeki bir satır: tarih başlığı ya da bir ileti.
sealed class _ListItem {
  const _ListItem();
}

class _HeaderItem extends _ListItem {
  const _HeaderItem(this.label);
  final String label;
}

class _MessageItem extends _ListItem {
  const _MessageItem(this.message);
  final MessageRow message;
}

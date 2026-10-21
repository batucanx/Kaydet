import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/search_providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/models/search_filters.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_launcher.dart';
import '../mail_detail/mail_detail_screen.dart';
import 'search_filter_chips.dart';
import 'search_result_rows.dart';

/// Gelişmiş, çok katmanlı arama ekranı (Outlook'un arama ekranı gibi).
///
/// `MailListScreen`'in arama ikonundan ayrı, tam ekran bir rota olarak
/// açılır — eski AppBar-içi arama kutusunun yerini alır.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// Filtre çipleri (Ekli · Tarih · Klasörler · Gönderen · Alıcı) alanın
  /// sağındaki filtre düğmesiyle açılıp kapanır (web'deki gibi). Bir filtre
  /// etkinken çipler her zaman görünür: etkin bir filtre gizlenmesin.
  bool _filtersOpen = false;

  /// Web'deki gibi: filtre düğmesi çipleri açar; çipler açıkken (ya da bir
  /// filtre etkinken) basmak çipleri kapatır ve düz, filtresiz aramaya döner.
  void _toggleFilters(bool showChips) {
    if (showChips) {
      ref.read(searchFiltersProvider.notifier).clear();
    }
    setState(() => _filtersOpen = !showChips);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Arama geçmişine yalnızca kullanıcı bilinçli bir şekilde "ara"
  /// dediğinde eklenir (klavye arama tuşu) — her tuş vuruşunda değil.
  void _submitToHistory(String term) {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return;
    ref.read(searchHistoryProvider.notifier).add(trimmed);
  }

  void _runTerm(String term) {
    // Kullanıcı bir kişiye/geçmiş terime dokunarak alanın dışına çıktı;
    // klavye açık kalırsa sonuçların alt kısmını örter.
    _focusNode.unfocus();
    _controller.text = term;
    _controller.selection = TextSelection.collapsed(offset: term.length);
    ref.read(searchQueryProvider.notifier).update(term);
    _submitToHistory(term);
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final filters = ref.watch(searchFiltersProvider);
    // Metin olmadan da, tek başına seçim yapan bir filtre (Ekli, Dosyalar,
    // tarih, kişi, klasör) tam bir aramadır ve sonuçları açar (web'deki
    // `isRunnableSearch`): "Dosyalar" Outlook'taki gibi hiç yazı yazılmadan en
    // son ekleri listeler (bkz. `attachmentSearchResultsProvider`).
    final isActive = query.trim().isNotEmpty || filters.selectsOnItsOwn;
    final showChips = _filtersOpen || filters.isActive;
    // Filtreleri yalnızca sonuç görünümü izler; sorgu tamamen silinip boş
    // görünüme dönüldüğünde `autoDispose` onları sıfırlardı. Hesap kapsamı gibi (bunları hep bağlı widget'lar izler) ekran açıkken korunsun.
    ref.listen(searchFiltersProvider, (_, _) {});

    final scaffold = Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Kapat',
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(
            hintText: 'Konu, gönderen veya içerikte ara…',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.full),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.full),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.full),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Space.md,
              vertical: Space.sm,
            ),
          ),
          onChanged: (value) =>
              ref.read(searchQueryProvider.notifier).update(value),
          onSubmitted: _submitToHistory,
        ),
        actions: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(LucideIcons.x, size: IconSize.md),
                    tooltip: 'Temizle',
                    onPressed: () {
                      _controller.clear();
                      ref.read(searchQueryProvider.notifier).clear();
                    },
                  ),
          ),
          _FilterToggleButton(
            open: showChips,
            count: filters.activeCount,
            onPressed: () => _toggleFilters(showChips),
          ),
          const _AccountSelectorButton(),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: context.motion(Motion.base),
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: showChips
                ? const SearchFilterChips()
                : const SizedBox(width: double.infinity),
          ),
          const _RemoteSearchStatus(),
          Expanded(
            child: isActive
                ? const _SearchResultsView()
                : _SearchIdleView(onSelectTerm: _runTerm),
          ),
        ],
      ),
    );
    return KaydetDepthCoverEffect(child: scaffold);
  }
}

// ------------------------------------------------------------ filtre düğmesi

/// Alanın sağındaki filtre düğmesi: filtre çiplerini açar/kapatır. Etkin filtre
/// sayısı bir rozetle gösterilir (web'deki `SearchBar` filtre düğmesi gibi).
class _FilterToggleButton extends StatelessWidget {
  const _FilterToggleButton({
    required this.open,
    required this.count,
    required this.onPressed,
  });

  final bool open;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return IconButton(
      tooltip: count > 0 ? 'Filtre, $count etkin' : 'Filtre',
      isSelected: open,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: t.accent,
        textColor: t.onAccentFill,
        child: const Icon(LucideIcons.slidersHorizontal),
      ),
    );
  }
}

// ---------------------------------------------------------- hesap seçici

/// Arama çubuğunun sağındaki hesap seçici — anchored popup (bkz. bellek:
/// bottom sheet değil, `MenuAnchor` ile açılan menü).
class _AccountSelectorButton extends ConsumerWidget {
  const _AccountSelectorButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final accounts =
        ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final scope = ref.watch(searchScopeProvider);
    final notifier = ref.read(searchScopeProvider.notifier);

    return MenuAnchor(
      animated: true,
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            LucideIcons.inbox,
            color: scope == null ? t.accent : null,
          ),
          onPressed: () => notifier.select(null),
          child: const Text('Tüm Hesaplar'),
        ),
        if (accounts.isNotEmpty) const Divider(height: 1),
        for (final account in accounts)
          MenuItemButton(
            leadingIcon: BrandAvatar(
              name: account.displayName,
              email: account.email,
              isSelected: scope == account.id,
              size: 28,
            ),
            onPressed: () => notifier.select(account.id),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  account.email,
                  style: AppText.bodyMedium.copyWith(color: t.textPrimary),
                ),
                if (account.displayName.trim().isNotEmpty)
                  Text(
                    account.displayName,
                    style: AppText.labelSmall.copyWith(color: t.textTertiary),
                  ),
              ],
            ),
          ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: const Icon(LucideIcons.mail),
        tooltip: 'Hesap seç',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

// ---------------------------------------------------- sunucu araması durumu

/// Sunucu araması (bkz. `remoteSearchProvider`) sürerken ince bir ilerleme
/// çubuğu; sunucuya ulaşılamadıysa tek satırlık bir not. Yerel sonuçlar bunu
/// beklemeden gösterilir.
class _RemoteSearchStatus extends ConsumerWidget {
  const _RemoteSearchStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final remote = ref.watch(remoteSearchProvider);
    return AnimatedSize(
      duration: context.motion(Motion.fast),
      alignment: Alignment.topCenter,
      child: remote.when(
        loading: () => Semantics(
          label: 'Sunucuda aranıyor',
          child: const LinearProgressIndicator(minHeight: 2),
        ),
        error: (_, _) => Container(
          width: double.infinity,
          color: t.surfaceElevated,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.cloudOff,
                size: IconSize.sm,
                color: t.textTertiary,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  'Sunucuda aranamadı; yalnızca cihazdaki iletiler gösteriliyor.',
                  style: AppText.labelSmall.copyWith(color: t.textSecondary),
                ),
              ),
            ],
          ),
        ),
        data: (_) => const Divider(height: 1),
      ),
    );
  }
}

// --------------------------------------------------------------- boş durum

class _SearchIdleView extends ConsumerWidget {
  const _SearchIdleView({required this.onSelectTerm});

  final ValueChanged<String> onSelectTerm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentContacts = ref.watch(recentContactsProvider);
    final history = ref.watch(searchHistoryProvider).value ?? const <String>[];

    if (recentContacts.isEmpty && history.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.search,
        title: 'Arama yap',
        description: 'Gönderen, konu veya içerikte arayın.',
      );
    }

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (recentContacts.isNotEmpty) ...[
          const SectionHeader('HIZLI KİŞİLER'),
          // Sabit yükseklikli bir ListView yerine içeriğe göre yükselen bir
          // Row: iki satırlı etiketler sistem yazı ölçeğiyle büyüyünce şerit
          // taşmaz. Şerit en fazla 12 kişi içerir (bkz. `watchRecentContacts`),
          // tembel yükleme gerekmez.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final contact in recentContacts)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.sm),
                    child: QuickContactAvatar(
                      name: contact.name,
                      email: contact.email,
                      onTap: () => onSelectTerm(
                        contact.name.trim().isNotEmpty
                            ? contact.name
                            : contact.email,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (history.isNotEmpty) ...[
          const SectionHeader('ARAMA GEÇMİŞİ'),
          for (final term in history)
            ListTile(
              leading: const Icon(LucideIcons.history),
              title: Text(term),
              onTap: () => onSelectTerm(term),
            ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------- sonuçlar

class _SearchResultsView extends ConsumerWidget {
  const _SearchResultsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchFiltersProvider);
    final query = ref.watch(searchQueryProvider);

    // "Dosyalar" çipi açıkken ileti yerine ekler listelenir.
    if (filters.filesOnly) return _FilesResults(filters: filters, query: query);

    final mail = ref.watch(mailSearchResultsProvider);
    // Kişiler filtrelenmez; bir filtre etkinken ilgisiz görünmesinler diye
    // yalnızca düz metin aramasında gösterilir.
    final showContacts = query.trim().isNotEmpty && !filters.isActive;
    final contacts = showContacts
        ? ref.watch(contactSearchResultsProvider)
        : const AsyncData<List<ContactRow>>(<ContactRow>[]);

    if (mail.isLoading || contacts.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final mailRows = mail.value ?? const <MessageRow>[];
    final contactRows = contacts.value ?? const <ContactRow>[];
    final mailboxes =
        ref.watch(searchResultMailboxesProvider).value ??
        const <int, MailboxRow>{};

    if (mailRows.isEmpty && contactRows.isEmpty) {
      return EmptyState(
        icon: LucideIcons.searchX,
        title: 'Sonuç bulunamadı',
        description: filters.isActive
            ? 'Seçili filtrelerle eşleşen sonuç yok.'
            : 'Farklı bir arama deneyin.',
        action: filters.isActive
            ? TextButton(
                onPressed: ref.read(searchFiltersProvider.notifier).clear,
                child: const Text('Filtreleri temizle'),
              )
            : null,
      );
    }

    // Posta sonuçları tarihe göre yeniden eskiye tek bir listede (Outlook'taki
    // gibi — alaka sırasıyla bir "en iyi sonuçlar" bölümü ayrılmaz, aksi
    // hâlde liste tarih sırasını bozardı); ardından kişiler. Her başlığın
    // yanında o bölümün sonuç sayısı gösterilir (ör. "TÜM SONUÇLAR (10)").
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (mailRows.isNotEmpty) ...[
          SectionHeader('TÜM SONUÇLAR (${mailRows.length})'),
          for (final message in mailRows)
            MailResultRow(
              message: message,
              mailbox: mailboxes[message.mailboxId],
              onTap: () => _openMessageResult(context, ref, message),
            ),
        ],
        if (contactRows.isNotEmpty) ...[
          SectionHeader('KİŞİLER (${contactRows.length})'),
          for (final contact in contactRows)
            ContactResultRow(
              contact: contact,
              onTap: () => _openContactResult(context, ref, contact),
            ),
        ],
      ],
    );
  }
}

/// "Dosyalar" çipi açıkken sonuçlar: ekler (bkz. [AttachmentResultRow]).
class _FilesResults extends ConsumerWidget {
  const _FilesResults({required this.filters, required this.query});

  final SearchFilters filters;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachments = ref.watch(attachmentSearchResultsProvider);
    if (attachments.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final rows = attachments.value ?? const <AttachmentSearchResult>[];

    if (rows.isEmpty) {
      // Dosyalar gözat modundaysa (sorgu boş, başka filtre yok) "farklı bir
      // arama dene" yanlış izlenim verir — henüz hiçbir şey aranmadı, ek
      // senkronize edilmemiş.
      final browsingEmpty =
          query.trim().isEmpty && filters.activeCount == 1; // yalnız Dosyalar
      return EmptyState(
        icon: LucideIcons.searchX,
        title: browsingEmpty ? 'Ek yok' : 'Sonuç bulunamadı',
        description: browsingEmpty
            ? 'Bu hesapta senkronize edilmiş bir ek bulunmuyor.'
            : 'Seçili filtrelerle eşleşen sonuç yok.',
        action: browsingEmpty
            ? null
            : TextButton(
                onPressed: ref.read(searchFiltersProvider.notifier).clear,
                child: const Text('Filtreleri temizle'),
              ),
      );
    }

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        SectionHeader('TÜM SONUÇLAR (${rows.length})'),
        for (final result in rows)
          AttachmentResultRow(
            result: result,
            onTap: () => _openMessageResult(context, ref, result.message),
          ),
      ],
    );
  }
}

// --------------------------------------------------------------- eylemler

/// Bir sonuca dokunma: ileti başka bir hesaba aitse önce o hesap
/// etkinleştirilir (aksi hâlde detay ekranındaki yanıtla/taşı/sil gibi
/// eylemler yanlış hesabın bağlamında çalışır).
Future<void> _openMessageResult(
  BuildContext context,
  WidgetRef ref,
  MessageRow message,
) async {
  FocusScope.of(context).unfocus();
  if (message.accountId != ref.read(accountIdProvider)) {
    await ref.read(accountRepositoryProvider).switchAccount(message.accountId);
  }
  if (!context.mounted) return;

  if (message.isDraft || message.outboxState == OutboxState.failed) {
    // Taslağa devam etmek Gelen Kutusu'ndaki aynı eylemle aynı hissettirsin
    // (bkz. `MailListScreen._openCompose`) — Compose geçişiyle açılır.
    await openCompose(
      context,
      ref,
      draftId: message.id,
      transitionStyle: KaydetTransitionStyle.compose,
    );
    return;
  }
  await context.pushScreen(MailDetailScreen(messageId: message.id));
}

Future<void> _openContactResult(
  BuildContext context,
  WidgetRef ref,
  ContactRow contact,
) {
  FocusScope.of(context).unfocus();
  return openCompose(context, ref, initialTo: contact.email);
}

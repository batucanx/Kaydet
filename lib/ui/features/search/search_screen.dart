import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/search_providers.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_launcher.dart';
import '../mail_detail/mail_detail_screen.dart';
import 'search_filters_screen.dart';
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
    final category = ref.watch(searchCategoryProvider);
    // Dosyalar sekmesi Outlook'taki gibi hiç yazı yazılmadan da sonuç
    // görünümünü açar: sorgu boşken en son ekleri gözat modunda listeler
    // (bkz. `attachmentSearchResultsProvider`). Diğer kategoriler yalnızca
    // bir sorgu yazılınca aktifleşir.
    final isActive =
        query.trim().isNotEmpty || category == SearchCategory.files;
    // Filtreleri yalnızca sonuç görünümü izler; sorgu tamamen silinip boş
    // görünüme dönüldüğünde `autoDispose` onları sıfırlardı. Kategori ve hesap
    // kapsamı gibi (bunları hep bağlı widget'lar izler) ekran açıkken korunsun.
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
          const _AccountSelectorButton(),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: Column(
        children: [
          const _CategoryChipRow(),
          const Divider(height: 1),
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

// --------------------------------------------------------- filtre çipleri

class _CategoryChipRow extends ConsumerWidget {
  const _CategoryChipRow();

  static const _labels = {
    SearchCategory.all: 'Tümü',
    SearchCategory.mail: 'Posta',
    SearchCategory.contacts: 'Kişiler',
    SearchCategory.files: 'Dosyalar',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(searchCategoryProvider);
    final notifier = ref.read(searchCategoryProvider.notifier);

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        children: [
          for (final category in SearchCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: Space.sm),
              child: _CategoryChip(
                label: _labels[category]!,
                isSelected: selected == category,
                onTap: () => notifier.select(category),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.full),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? t.accentFill : t.surfaceElevated,
          borderRadius: BorderRadius.circular(Radii.full),
        ),
        child: Text(
          label,
          style: AppText.labelMedium.copyWith(
            color: isSelected ? t.onAccentFill : t.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
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
                    child: _RecentContactAvatar(
                      contact: contact,
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

class _RecentContactAvatar extends StatelessWidget {
  const _RecentContactAvatar({required this.contact, required this.onTap});

  final ContactRow contact;
  final VoidCallback onTap;

  /// Outlook'un "Hızlı Kişiler" şeridindeki gibi büyük avatarlar.
  static const double _avatarSize = 64;
  static const double _width = 76;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final label = contact.name.trim().isNotEmpty
        ? contact.name.trim()
        : contact.email;
    // Outlook'taki gibi ilk sözcük üst satırda, kalanı (kısaltılarak) alt
    // satırda. Adı olmayan kişide e-posta adresi tek satırda kalır.
    final split = label.indexOf(RegExp(r'\s'));
    final firstLine = split < 0 ? label : label.substring(0, split);
    final secondLine = split < 0 ? '' : label.substring(split).trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Gelen kutusuyla aynı avatar: tanınan marka alan adlarında (ör.
            // LinkedIn) gerçek logo, kişisel adreslerde ve logo
            // yüklenemediğinde renkli baş harf (bkz. `BrandAvatar`).
            BrandAvatar(
              name: contact.name,
              email: contact.email,
              size: _avatarSize,
            ),
            const SizedBox(height: Space.sm),
            Text(
              firstLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.bodyMedium.copyWith(color: t.textPrimary),
            ),
            if (secondLine.isNotEmpty)
              Text(
                secondLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.bodyMedium.copyWith(color: t.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- sonuçlar

/// Filtreler (bkz. [SearchFiltersScreen]) posta kaynaklı sonuçlara uygulanır:
/// posta, dosyalar ve ikisini de içeren Tümü. Kişiler filtrelenmez, bu
/// sekmede "Filtrele" düğmesi de gösterilmez.
bool _filtersApplyTo(SearchCategory category) =>
    category == SearchCategory.all ||
    category == SearchCategory.mail ||
    category == SearchCategory.files;

/// Sonuçların üstündeki, sağa dayalı "Filtrele" düğmesi (Outlook'taki gibi).
/// Etkin filtre varsa vurgulanır ve sayısını gösterir.
///
/// Sonuç listesinin İLK ÖĞESİ olarak yerleştirilir (bkz. [_SearchResultsView]):
/// kullanıcı aşağı kaydırdıkça listeyle birlikte yukarı çıkar, ekrana yapışık
/// kalmaz.
class _FilterBar extends ConsumerWidget {
  const _FilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final count = ref.watch(searchFiltersProvider.select((f) => f.activeCount));
    final isActive = count > 0;

    // Açık temada `surfaceElevated` zeminle aynı beyazdır; dolgu tek başına
    // düğmeyi zeminden ayırmaz ve yalnızca yazı kalır. Koyu tema zeminden
    // ayrışan bir tona sahip olduğu için olduğu gibi bırakılır; açık temada
    // daha koyu bir dolgu ve ince bir çerçeve düğmeye şeklini verir.
    final restingFill = t.isDark ? t.surfaceElevated : t.surfaceDeep;
    final outline = t.isDark
        ? BorderSide.none
        : BorderSide(color: isActive ? t.accent : t.border);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.sm,
        Space.lg,
        Space.xs,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: isActive ? t.accentSubtle : restingFill,
          shape: StadiumBorder(side: outline),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () {
              // Klavye açık kalırsa sayfa kapanınca arama kutusu odağı geri alıp
              // klavyeyi yeniden açar.
              FocusScope.of(context).unfocus();
              context.pushScreen(
                const SearchFiltersScreen(),
                fullscreenDialog: true,
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.lg,
                vertical: Space.sm,
              ),
              child: Text(
                isActive ? 'Filtrele · $count' : 'Filtrele',
                style: AppText.labelMedium.copyWith(
                  color: isActive ? t.accent : t.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchResultsView extends ConsumerWidget {
  const _SearchResultsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = ref.watch(searchCategoryProvider);

    // "Filtrele" çubuğu (yalnızca posta kaynaklı sekmelerde) sonuç
    // listelerinde listenin ilk öğesidir ve içerikle birlikte kayar. Yükleniyor
    // ve boş durumlarında kaydırılacak bir şey yoktur; çubuk içeriğin üstünde
    // durur — sonuç boşken de filtreler değiştirilebilmeli.
    final filterBar = _filtersApplyTo(category) ? const _FilterBar() : null;
    Widget stateView(Widget content) => Column(
      children: [
        ?filterBar,
        Expanded(child: content),
      ],
    );

    final mail = ref.watch(mailSearchResultsProvider);
    final contacts = ref.watch(contactSearchResultsProvider);
    final attachments = ref.watch(attachmentSearchResultsProvider);

    final loading = switch (category) {
      SearchCategory.mail => mail.isLoading,
      SearchCategory.contacts => contacts.isLoading,
      SearchCategory.files => attachments.isLoading,
      SearchCategory.all =>
        mail.isLoading || contacts.isLoading || attachments.isLoading,
    };
    if (loading) {
      return stateView(const Center(child: CircularProgressIndicator()));
    }

    final mailRows = mail.value ?? const <MessageRow>[];
    final contactRows = contacts.value ?? const <ContactRow>[];
    final attachmentRows =
        attachments.value ?? const <AttachmentSearchResult>[];
    final mailboxes =
        ref.watch(searchResultMailboxesProvider).value ??
        const <int, MailboxRow>{};

    final totalCount = switch (category) {
      SearchCategory.mail => mailRows.length,
      SearchCategory.contacts => contactRows.length,
      SearchCategory.files => attachmentRows.length,
      SearchCategory.all =>
        mailRows.length + contactRows.length + attachmentRows.length,
    };
    if (totalCount == 0) {
      // Boşluğun nedeni filtreler olabilir: bunu söyle ve tek dokunuşla temizlet.
      final filtered =
          _filtersApplyTo(category) &&
          ref.watch(searchFiltersProvider).isActive;
      // Dosyalar gözat modundaysa (sorgu boş) "farklı bir arama dene" yanlış
      // izlenim verir — henüz hiçbir şey aranmadı, ek senkronize edilmemiş.
      final browsingEmptyFiles =
          category == SearchCategory.files &&
          ref.watch(searchQueryProvider).trim().isEmpty;
      return stateView(
        EmptyState(
          icon: LucideIcons.searchX,
          title: browsingEmptyFiles ? 'Ek yok' : 'Sonuç bulunamadı',
          description: filtered
              ? 'Seçili filtrelerle eşleşen sonuç yok.'
              : browsingEmptyFiles
              ? 'Bu hesapta senkronize edilmiş bir ek bulunmuyor.'
              : 'Farklı bir arama deneyin.',
          action: filtered
              ? TextButton(
                  onPressed: ref.read(searchFiltersProvider.notifier).clear,
                  child: const Text('Filtreleri temizle'),
                )
              : null,
        ),
      );
    }

    List<Widget> mailTiles(List<MessageRow> rows) => [
      for (final message in rows)
        MailResultRow(
          message: message,
          mailbox: mailboxes[message.mailboxId],
          onTap: () => _openMessageResult(context, ref, message),
        ),
    ];
    List<Widget> contactTiles(List<ContactRow> rows) => [
      for (final contact in rows)
        ContactResultRow(
          contact: contact,
          onTap: () => _openContactResult(context, ref, contact),
        ),
    ];
    List<Widget> attachmentTiles(List<AttachmentSearchResult> rows) => [
      for (final result in rows)
        AttachmentResultRow(
          result: result,
          onTap: () => _openMessageResult(context, ref, result.message),
        ),
    ];

    if (category == SearchCategory.mail) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          ?filterBar,
          SectionHeader('TÜM SONUÇLAR (${mailRows.length})'),
          ...mailTiles(mailRows),
        ],
      );
    }
    if (category == SearchCategory.contacts) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          SectionHeader('TÜM SONUÇLAR (${contactRows.length})'),
          ...contactTiles(contactRows),
        ],
      );
    }
    if (category == SearchCategory.files) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          ?filterBar,
          SectionHeader('TÜM SONUÇLAR (${attachmentRows.length})'),
          ...attachmentTiles(attachmentRows),
        ],
      );
    }

    // Tümü: posta sonuçları tarihe göre yeniden eskiye tek bir listede
    // (Outlook'taki gibi — alaka sırasıyla bir "en iyi sonuçlar" bölümü
    // ayrılmaz, aksi hâlde liste tarih sırasını bozardı); ardından kişiler
    // ve dosyalar kendi başlıklarıyla. Her başlığın yanında o bölümün sonuç
    // sayısı gösterilir (ör. "TÜM SONUÇLAR (10)") — kullanıcı kaç eşleşme
    // olduğunu saymadan görsün.
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        ?filterBar,
        if (mailRows.isNotEmpty) ...[
          SectionHeader('TÜM SONUÇLAR (${mailRows.length})'),
          ...mailTiles(mailRows),
        ],
        if (contactRows.isNotEmpty) ...[
          SectionHeader('KİŞİLER (${contactRows.length})'),
          ...contactTiles(contactRows),
        ],
        if (attachmentRows.isNotEmpty) ...[
          SectionHeader('DOSYALAR (${attachmentRows.length})'),
          ...attachmentTiles(attachmentRows),
        ],
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
    // (bkz. `MailListScreen._openCompose`) — bu yüzden burada da yatay push.
    await openCompose(
      context,
      ref,
      draftId: message.id,
      transitionStyle: KaydetTransitionStyle.horizontalPush,
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
  return openCompose(
    context,
    ref,
    initialTo: contact.email,
    fullscreenDialog: true,
  );
}

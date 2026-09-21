import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/turkish.dart';
import '../data/database/app_database.dart';
import '../data/services/search_history_store.dart';
import '../domain/models/search_filters.dart';
import '../domain/use_cases/folder_mapping.dart';
import 'providers.dart';

/// Arama ekranının filtre çipleri.
enum SearchCategory { all, mail, contacts, files, events }

/// Aranan metin — 250ms debounce ile yazılır (bkz. eski
/// `SearchQueryNotifier`, aynı desen). `autoDispose`: ekran kapanınca
/// sıfırlanır, bir sonraki açılışta boş başlar.
class SearchQueryNotifier extends Notifier<String> {
  Timer? _debounce;

  @override
  String build() {
    ref.onDispose(() => _debounce?.cancel());
    return '';
  }

  void update(String value) {
    _debounce?.cancel();
    if (value.isEmpty) {
      state = '';
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () {
      state = value;
    });
  }

  void clear() {
    _debounce?.cancel();
    state = '';
  }
}

final searchQueryProvider = NotifierProvider.autoDispose<
  SearchQueryNotifier,
  String
>(SearchQueryNotifier.new);

class SearchCategoryNotifier extends Notifier<SearchCategory> {
  @override
  SearchCategory build() => SearchCategory.all;

  void select(SearchCategory value) => state = value;
}

final searchCategoryProvider = NotifierProvider.autoDispose<
  SearchCategoryNotifier,
  SearchCategory
>(SearchCategoryNotifier.new);

/// Arama kapsamı: hangi hesapta aranıyor. `null` = Tüm Hesaplar (varsayılan).
class SearchScopeNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? accountId) => state = accountId;
}

final searchScopeProvider =
    NotifierProvider.autoDispose<SearchScopeNotifier, int?>(
      SearchScopeNotifier.new,
    );

// --------------------------------------------------------------- filtreler

/// Posta kaynaklı sonuçlara (posta, dosyalar) uygulanan filtreler —
/// "Filtreler" sayfasında (bkz. `SearchFiltersScreen`) "Uygula" ile yazılır.
/// Kişi sonuçları filtrelenmez.
class SearchFiltersNotifier extends Notifier<SearchFilters> {
  @override
  SearchFilters build() {
    // Klasör seçenekleri hesap kapsamına bağlıdır (ör. "Work" yalnızca bir
    // hesapta olabilir): kapsam değişince eski klasör seçimi boş sonuç
    // verebilir, bu yüzden "Tüm Klasörler"e dönülür. Diğer filtreler
    // kapsamdan bağımsızdır, korunur.
    ref.listen(searchScopeProvider, (_, _) {
      if (state.folder != null) state = state.copyWith(folder: () => null);
    });
    return const SearchFilters();
  }

  void apply(SearchFilters filters) => state = filters;

  void clear() => state = const SearchFilters();
}

final searchFiltersProvider =
    NotifierProvider.autoDispose<SearchFiltersNotifier, SearchFilters>(
      SearchFiltersNotifier.new,
    );

/// "Filtreler" sayfasının klasör listesi: arama kapsamındaki (tek hesap ya da
/// tüm hesaplar) seçilebilir klasörlerden türetilir. Hesaplar arasında aynı
/// türdeki klasörler (ör. her hesabın Gelen Kutusu'su) tek seçenekte birleşir.
/// Sıralama yan menüyle aynıdır: standart klasörler, ardından özel klasörler
/// ada göre.
final searchFolderOptionsProvider =
    FutureProvider.autoDispose<List<SearchFolder>>((ref) async {
      final scope = ref.watch(searchScopeProvider);
      final boxes = await ref
          .watch(databaseProvider)
          .selectableMailboxes(accountId: scope);
      final options = {
        for (final box in boxes) SearchFolder.of(box.specialUse, box.name),
      }.toList();
      int kindOrder(SearchFolder folder) =>
          FolderMapping.sortOrderFor(folder.use);
      options.sort((a, b) {
        final byKind = kindOrder(a).compareTo(kindOrder(b));
        if (byKind != 0) return byKind;
        final nameA = trLower(a.customName ?? '');
        return nameA.compareTo(trLower(b.customName ?? ''));
      });
      return options;
    });

// -------------------------------------------------------------- sonuçlar

final mailSearchResultsProvider = FutureProvider.autoDispose<List<MessageRow>>(
  (ref) async {
    final query = ref.watch(searchQueryProvider);
    if (query.trim().isEmpty) return const [];
    final scope = ref.watch(searchScopeProvider);
    final filters = ref.watch(searchFiltersProvider);
    final db = ref.watch(databaseProvider);
    final ids = await db.searchMessageIds(
      accountId: scope,
      query: query,
      filters: filters,
    );
    if (ids.isEmpty) return const [];
    final rows = await db.messagesByIds(ids);
    // Sorgunun tarih sırasını (yeniden eskiye) koru — `messagesByIds` id
    // sırasını korumaz.
    final byId = {for (final row in rows) row.id: row};
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  },
);

/// Sonuçtaki iletilerin klasör etiketi ("Taslak", "Gelen Kutusu"…) için.
final searchResultMailboxesProvider =
    FutureProvider.autoDispose<Map<int, MailboxRow>>((ref) async {
      final messages = await ref.watch(mailSearchResultsProvider.future);
      if (messages.isEmpty) return const {};
      final ids = messages.map((m) => m.mailboxId).toSet().toList();
      final db = ref.watch(databaseProvider);
      final rows = await db.mailboxesByIds(ids);
      return {for (final row in rows) row.id: row};
    });

final contactSearchResultsProvider =
    FutureProvider.autoDispose<List<ContactRow>>((ref) async {
      final query = ref.watch(searchQueryProvider);
      if (query.trim().isEmpty) return const [];
      final scope = ref.watch(searchScopeProvider);
      final db = ref.watch(databaseProvider);
      return db.searchContacts(accountId: scope, query: query);
    });

final attachmentSearchResultsProvider =
    FutureProvider.autoDispose<List<AttachmentSearchResult>>((ref) async {
      final query = ref.watch(searchQueryProvider);
      if (query.trim().isEmpty) return const [];
      final scope = ref.watch(searchScopeProvider);
      final filters = ref.watch(searchFiltersProvider);
      final db = ref.watch(databaseProvider);
      return db.searchAttachments(
        accountId: scope,
        query: query,
        filters: filters,
      );
    });

/// [recentContactsProvider]'ın ham akışı — arama ekranının hesap kapsamına
/// (bkz. [searchScopeProvider]) göre filtrelenir, uygulama genelindeki ETKİN
/// hesaba (`accountIdProvider`) göre DEĞİL. `searchScope` `null` ("Tüm
/// Hesaplar") olduğunda `accountId: null` cihazdaki tüm hesapların
/// kişilerini birlikte döner — aynı ekrandaki posta/dosya arama
/// sonuçlarının (`mailSearchResultsProvider` vb.) zaten uyduğu kapsamla
/// aynı kural.
final _scopedRecentContactsProvider =
    StreamProvider.autoDispose<List<ContactRow>>((ref) {
      final scope = ref.watch(searchScopeProvider);
      final db = ref.watch(databaseProvider);
      return db.watchRecentContacts(accountId: scope);
    });

/// "Hızlı Kişiler" şeridi — arama ekranında SEÇİLİ hesap kapsamının (ya da
/// "Tüm Hesaplar" ise cihazdaki tüm hesapların) en son kullanılan kişileri.
///
/// Önceki sürüm burada `contactsProvider` (uygulama genelindeki ETKİN
/// hesabın kişileri) izleniyordu; bu, arama ekranının kendi hesap seçicisini
/// YOK SAYIYORDU — kullanıcı buradan başka bir hesap seçse bile şerit hep
/// etkin hesabın (ör. Gelen Kutusu'nda açık olan) kişilerini gösteriyordu.
final recentContactsProvider = Provider.autoDispose<List<ContactRow>>((ref) {
  final contacts = ref.watch(_scopedRecentContactsProvider);
  return contacts.value ?? const <ContactRow>[];
});

// ----------------------------------------------------------- arama geçmişi

/// Kalıcı arama geçmişi. `autoDispose` DEĞİL: ekran her açıldığında diskten
/// yeniden okumak yerine oturum boyunca bellekte tutulur.
class SearchHistoryNotifier extends AsyncNotifier<List<String>> {
  SearchHistoryStore? _store;

  @override
  Future<List<String>> build() async {
    final store = await SearchHistoryStore.create();
    _store = store;
    return store.read();
  }

  Future<void> add(String term) async {
    final store = _store;
    if (store == null) return;
    await store.add(term);
    state = AsyncData(store.read());
  }

  Future<void> remove(String term) async {
    final store = _store;
    if (store == null) return;
    await store.remove(term);
    state = AsyncData(store.read());
  }

  Future<void> clear() async {
    final store = _store;
    if (store == null) return;
    await store.clear();
    state = const AsyncData([]);
  }
}

final searchHistoryProvider =
    AsyncNotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );

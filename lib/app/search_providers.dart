import 'dart:async';

import 'package:drift/drift.dart' show TableInfo, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/result.dart';
import '../core/turkish.dart';
import '../data/database/app_database.dart';
import '../data/repositories/sync_engine.dart';
import '../data/services/search_history_store.dart';
import '../domain/models/search_filters.dart';
import '../domain/use_cases/folder_mapping.dart';
import 'providers.dart';

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

final searchQueryProvider =
    NotifierProvider.autoDispose<SearchQueryNotifier, String>(
      SearchQueryNotifier.new,
    );

/// Arama kapsamı: hangi hesapta aranıyor. Varsayılan = o an etkin hesap;
/// `null` = Tüm Hesaplar (kullanıcı sağ üstteki hesap menüsünden seçer).
class SearchScopeNotifier extends Notifier<int?> {
  @override
  int? build() =>
      ref.read(isAllAccountsProvider) ? null : ref.read(accountIdProvider);

  void select(int? accountId) => state = accountId;
}

final searchScopeProvider =
    NotifierProvider.autoDispose<SearchScopeNotifier, int?>(
      SearchScopeNotifier.new,
    );

// --------------------------------------------------------------- filtreler

/// Posta kaynaklı sonuçlara (posta, dosyalar) uygulanan filtreler — arama
/// ekranındaki çiplerle (Ekli · Tarih · Klasörler · Gönderen · Alıcı, bkz.
/// `SearchFilterChips`) her seçimde anında yazılır. Kişi sonuçları
/// filtrelenmez.
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
    return _initial;
  }

  /// "Tüm Klasörler" araması Çöp Kutusu'nu da kapsar (web'deki gibi — çiplerde
  /// bunun için bir anahtar yoktur, bkz. [SearchFilters.includeDeleted]).
  static const _initial = SearchFilters(includeDeleted: true);

  void apply(SearchFilters filters) => state = filters;

  void clear() => state = _initial;
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

// --------------------------------------------------------- sunucu araması

/// Yazı yazmayı bıraktıktan sonra sunucu aramasının başlamasına kadar bekleme
/// (her tuş vuruşunda yüzlerce klasörü taramamak için).
const _remoteSearchDelay = Duration(milliseconds: 600);

/// Sunucu araması: yerelde OLMAYAN (eski) iletiler IMAP `SEARCH` ile bulunur
/// ve yerele "arama sonucu" olarak yazılır (bkz. `SyncEngine.searchRemote`);
/// [mailSearchResultsProvider] tabloyu izlediğinden sonuçlar listeye kendiliğinden
/// eklenir. Yerel sonuçlar bunu BEKLEMEZ.
///
/// Değer: bu aramada yerele eklenen ileti sayısı. Hata: hiçbir klasör
/// aranamadı (ör. çevrimdışı) — ekran yerel sonuçlarla devam eder ve bunu
/// bildirir. Sorgu/filtre değişirse (provider yeniden kurulur) sürmekte olan
/// arama klasörler arasında durdurulur.
final remoteSearchProvider = FutureProvider.autoDispose<int>((ref) async {
  final query = ref.watch(searchQueryProvider);
  final filters = ref.watch(searchFiltersProvider);
  final scope = ref.watch(searchScopeProvider);
  // Sunucuya gidecek bir ölçüt yoksa (yalnızca klasör/"Ekli" ya da boş ekran)
  // bekleme ve ilerleme çubuğu da yok.
  final hasCriteria =
      SyncEngine.remoteSearchWords(query).isNotEmpty ||
      filters.sender != null ||
      filters.recipient != null ||
      filters.hasDate;
  if (filters.filesOnly || !hasCriteria) return 0;
  final accounts = ref.watch(allAccountsProvider).value ?? const [];

  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(_remoteSearchDelay);
  if (cancelled) return 0;

  final result = await ref
      .read(syncEngineProvider)
      .searchRemote(
        accountIds: scope != null ? [scope] : [for (final a in accounts) a.id],
        query: query,
        filters: filters,
        isCancelled: () => cancelled,
      );
  return switch (result) {
    Ok<int>(:final value) => value,
    Err<int>(:final failure) => throw failure,
  };
});

// -------------------------------------------------------------- sonuçlar

/// [run]'ı bir kez çalıştırır, ardından [tables]'ta HER değişiklikte yeniden
/// çalıştırıp yeni sonucu yayar.
///
/// Arama sonuçları tek seferlik sorgulardır; ekran açıkken bir taslak
/// silinir, bir ileti taşınır ya da senkronizasyon bir ileti getirirse liste
/// eski kalırdı (silinen taslak sonuçta görünmeye devam ederdi).
Stream<T> _rerunOnChange<T>(
  AppDatabase db,
  Set<TableInfo<dynamic, dynamic>> tables,
  Future<T> Function() run,
) async* {
  yield await run();
  await for (final _ in db.tableUpdates(TableUpdateQuery.onAllTables(tables))) {
    yield await run();
  }
}

final mailSearchResultsProvider = StreamProvider.autoDispose<List<MessageRow>>((
  ref,
) {
  final query = ref.watch(searchQueryProvider);
  final filters = ref.watch(searchFiltersProvider);
  // Yazı olmadan yalnızca tek başına seçim yapan bir filtre (Ekli, tarih,
  // kişi, klasör) tam bir aramadır — en yeni eşleşen iletiler listelenir.
  if (filters.filesOnly || (query.trim().isEmpty && !filters.selectsOnItsOwn)) {
    return Stream.value(const <MessageRow>[]);
  }
  final scope = ref.watch(searchScopeProvider);
  final db = ref.watch(databaseProvider);
  return _rerunOnChange(db, {db.messages, db.mailboxes}, () async {
    final ids = await db.searchMessageIds(
      accountId: scope,
      query: query,
      filters: filters,
    );
    if (ids.isEmpty) return const <MessageRow>[];
    final rows = await db.messagesByIds(ids);
    // Sorgunun tarih sırasını (yeniden eskiye) koru — `messagesByIds` id
    // sırasını korumaz.
    final byId = {for (final row in rows) row.id: row};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  });
});

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
    StreamProvider.autoDispose<List<ContactRow>>((ref) {
      final query = ref.watch(searchQueryProvider);
      if (query.trim().isEmpty) return Stream.value(const <ContactRow>[]);
      final scope = ref.watch(searchScopeProvider);
      final db = ref.watch(databaseProvider);
      return _rerunOnChange(db, {
        db.contacts,
      }, () => db.searchContacts(accountId: scope, query: query));
    });

/// [query] boşsa Outlook'un Dosyalar sekmesi gibi en son ekleri gözat
/// modunda döner (bkz. [AppDatabase.searchAttachments]) — bu yüzden diğer
/// kategori sağlayıcılarının (posta, kişiler) aksine boş sorguda erken
/// dönmez.
final attachmentSearchResultsProvider =
    StreamProvider.autoDispose<List<AttachmentSearchResult>>((ref) {
      final query = ref.watch(searchQueryProvider);
      final scope = ref.watch(searchScopeProvider);
      final filters = ref.watch(searchFiltersProvider);
      // Ekler yalnızca "Dosyalar" çipi açıkken listelenir.
      if (!filters.filesOnly) {
        return Stream.value(const <AttachmentSearchResult>[]);
      }
      final db = ref.watch(databaseProvider);
      return _rerunOnChange(
        db,
        {db.attachments, db.messages, db.mailboxes},
        () => db.searchAttachments(
          accountId: scope,
          query: query,
          filters: filters,
        ),
      );
    });

/// "Gönderen" / "Alıcı" seçicisinin kişileri: [text] boşsa arama kapsamının
/// en son kullanılan kişileri, doluysa ad/e-postada geçenler (web'deki
/// `PeoplePicker` ile aynı).
final searchPeopleProvider = FutureProvider.autoDispose
    .family<List<ContactRow>, String>((ref, text) async {
      final scope = ref.watch(searchScopeProvider);
      final db = ref.watch(databaseProvider);
      if (text.trim().isEmpty) {
        return db.watchRecentContacts(accountId: scope, limit: 30).first;
      }
      return db.searchContacts(accountId: scope, query: text);
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

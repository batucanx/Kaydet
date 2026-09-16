import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/app_database.dart';
import '../data/database/tables.dart';
import '../data/repositories/account_repository.dart';
import '../data/repositories/mail_connection.dart';
import '../data/repositories/mail_repository.dart';
import '../data/repositories/sync_engine.dart';
import '../data/services/app_settings.dart';
import '../data/services/google_oauth_service.dart';
import '../data/services/imap_service.dart';
import '../data/services/notification_service.dart';
import '../data/services/secure_store.dart';
import '../data/services/smtp_service.dart';

/// Uygulama genelindeki bağımlılık grafiği.
///
/// Riverpod'un kod üretimsiz API'si kullanılır; ek bir üreteç bağımlılığı
/// getirmez ve davranışı aynıdır.

// ---------------------------------------------------------------- altyapı

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final secureStoreProvider = Provider<SecureStore>(
  (ref) => FlutterSecureStore(),
);

final imapServiceProvider = Provider<ImapService>((ref) {
  final service = EnoughMailImapService();
  ref.onDispose(service.dispose);
  return service;
});

final smtpServiceProvider = Provider<SmtpService>(
  (ref) => EnoughMailSmtpService(),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

final googleOAuthServiceProvider = Provider<GoogleOAuthService>((ref) {
  final service = GoogleOAuthService();
  ref.onDispose(service.dispose);
  return service;
});

final mailConnectionProvider = Provider<MailConnection>((ref) {
  final connection = MailConnection(
    database: ref.watch(databaseProvider),
    secureStore: ref.watch(secureStoreProvider),
    imapService: ref.watch(imapServiceProvider),
    googleOAuth: ref.watch(googleOAuthServiceProvider),
  );
  ref.onDispose(connection.disconnect);
  return connection;
});

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => SyncEngine(
    database: ref.watch(databaseProvider),
    connection: ref.watch(mailConnectionProvider),
  ),
);

final mailRepositoryProvider = Provider<MailRepository>(
  (ref) => MailRepository(
    database: ref.watch(databaseProvider),
    connection: ref.watch(mailConnectionProvider),
    syncEngine: ref.watch(syncEngineProvider),
    smtpService: ref.watch(smtpServiceProvider),
  ),
);

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(
    database: ref.watch(databaseProvider),
    secureStore: ref.watch(secureStoreProvider),
    imapService: ref.watch(imapServiceProvider),
    smtpService: ref.watch(smtpServiceProvider),
    connection: ref.watch(mailConnectionProvider),
    googleOAuth: ref.watch(googleOAuthServiceProvider),
  ),
);

/// `main()` içinde gerçek örnekle geçersiz kılınır.
final settingsStoreProvider = Provider<AppSettingsStore>(
  (ref) => throw UnimplementedError('settingsStoreProvider ayarlanmadı'),
);

// ---------------------------------------------------------------- ayarlar

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsStoreProvider).read();

  Future<void> _save(AppSettings next) async {
    state = next;
    await ref.read(settingsStoreProvider).write(next);
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _save(state.copyWith(themeMode: mode));

  /// Bildirimleri açar/kapatır.
  ///
  /// Android 13+ sürümünde bildirim göstermek için çalışma anında izin
  /// gerekir; izin istenmezse ayar açık görünür ama hiçbir bildirim düşmez.
  Future<void> setNotifications(bool enabled) async {
    if (enabled) {
      final granted = await ref
          .read(notificationServiceProvider)
          .requestPermission();
      if (!granted) {
        await _save(state.copyWith(notificationsEnabled: false));
        return;
      }
    }
    await _save(state.copyWith(notificationsEnabled: enabled));
  }

  Future<void> setSyncFrequency(SyncFrequency frequency) =>
      _save(state.copyWith(syncFrequency: frequency));

  Future<void> setShowRemoteImages(bool value) =>
      _save(state.copyWith(showRemoteImages: value));

  Future<void> setConfirmBeforeDelete(bool value) =>
      _save(state.copyWith(confirmBeforeDelete: value));
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

// ----------------------------------------------------------------- hesap

final activeAccountProvider = StreamProvider<AccountRow?>(
  (ref) => ref.watch(databaseProvider).watchActiveAccount(),
);

final accountIdProvider = Provider<int?>(
  (ref) => ref.watch(activeAccountProvider).value?.id,
);

/// Cihazdaki tüm hesaplar — hesap değiştirici listesi için.
final allAccountsProvider = StreamProvider<List<AccountRow>>(
  (ref) => ref.watch(accountRepositoryProvider).watchAllAccounts(),
);

// --------------------------------------------------------------- klasörler

final mailboxesProvider = StreamProvider<List<MailboxRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <MailboxRow>[]);
  return ref.watch(databaseProvider).watchMailboxes(accountId);
});

/// Belirli bir hesabın klasörleri — çoklu hesap yan menüsünde her hesap
/// kendi klasörlerini etkin hesap değişmeden gösterir.
final mailboxesForAccountProvider =
    StreamProvider.family<List<MailboxRow>, int>(
      (ref, accountId) => ref.watch(databaseProvider).watchMailboxes(accountId),
    );

/// Seçili klasör. `null` = sanal "Sabitlenenler" klasörü.
class SelectedFolder {
  const SelectedFolder.mailbox(this.mailboxId) : isFlaggedView = false;
  const SelectedFolder.flagged() : mailboxId = null, isFlaggedView = true;

  final int? mailboxId;
  final bool isFlaggedView;

  @override
  bool operator ==(Object other) =>
      other is SelectedFolder &&
      other.mailboxId == mailboxId &&
      other.isFlaggedView == isFlaggedView;

  @override
  int get hashCode => Object.hash(mailboxId, isFlaggedView);
}

/// Kullanıcının açıkça seçtiği klasör. `null` ise varsayılan uygulanır.
class SelectedFolderNotifier extends Notifier<SelectedFolder?> {
  @override
  SelectedFolder? build() => null;

  void select(SelectedFolder folder) => state = folder;
}

final selectedFolderRawProvider =
    NotifierProvider<SelectedFolderNotifier, SelectedFolder?>(
      SelectedFolderNotifier.new,
    );

/// Görüntülenen klasör.
///
/// Kullanıcının seçimi hâlâ geçerliyse o, değilse Gelen Kutusu kullanılır.
/// Seçim ayrı bir sağlayıcıda tutulur; klasör listesi yenilendiğinde
/// kullanıcının seçimi sıfırlanmaz.
final selectedFolderProvider = Provider<SelectedFolder?>((ref) {
  final chosen = ref.watch(selectedFolderRawProvider);
  final mailboxes = ref.watch(mailboxesProvider).value;

  if (chosen != null) {
    if (chosen.isFlaggedView) return chosen;
    final stillExists =
        mailboxes?.any((m) => m.id == chosen.mailboxId) ?? false;
    if (stillExists) return chosen;
  }

  if (mailboxes == null || mailboxes.isEmpty) return null;
  final inbox = mailboxes.firstWhere(
    (m) => m.specialUse == SpecialUse.inbox,
    orElse: () => mailboxes.first,
  );
  return SelectedFolder.mailbox(inbox.id);
});

/// Seçili klasörün satırı.
final currentMailboxProvider = Provider<MailboxRow?>((ref) {
  final selected = ref.watch(selectedFolderProvider);
  final mailboxes = ref.watch(mailboxesProvider).value;
  if (selected == null || selected.mailboxId == null || mailboxes == null) {
    return null;
  }
  for (final row in mailboxes) {
    if (row.id == selected.mailboxId) return row;
  }
  return null;
});

// ---------------------------------------------------------------- arama

class SearchQueryNotifier extends Notifier<String> {
  Timer? _debounce;

  @override
  String build() {
    ref.onDispose(() => _debounce?.cancel());
    return '';
  }

  /// Her tuş vuruşunda sorgu çalıştırmamak için 250 ms bekletir.
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

final searchQueryProvider = NotifierProvider<SearchQueryNotifier, String>(
  SearchQueryNotifier.new,
);

/// Arama kutusu açık mı?
class SearchOpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() {
    state = false;
    ref.read(searchQueryProvider.notifier).clear();
  }
}

final isSearchOpenProvider = NotifierProvider<SearchOpenNotifier, bool>(
  SearchOpenNotifier.new,
);

// -------------------------------------------------------------- liste

/// Görüntülenen ileti listesi.
///
/// Arama etkinse FTS sonuçları, değilse seçili klasörün içeriği döner.
final messageListProvider = StreamProvider<List<MessageRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  final folder = ref.watch(selectedFolderProvider);
  final query = ref.watch(searchQueryProvider);
  final db = ref.watch(databaseProvider);

  if (accountId == null || folder == null) {
    return Stream.value(const <MessageRow>[]);
  }

  if (query.trim().isNotEmpty) {
    return _searchStream(db, accountId, query);
  }

  if (folder.isFlaggedView) {
    return db.watchFlagged(accountId: accountId);
  }

  return db.watchMessages(
    accountId: accountId,
    mailboxId: folder.mailboxId!,
    limit: ref.watch(pageLimitProvider),
  );
});

Stream<List<MessageRow>> _searchStream(
  AppDatabase db,
  int accountId,
  String query,
) async* {
  final ids = await db.searchMessageIds(accountId: accountId, query: query);
  if (ids.isEmpty) {
    yield const <MessageRow>[];
    return;
  }
  final rows = await db.messagesByIds(ids);
  // FTS alaka sırasını koru.
  final byId = {for (final row in rows) row.id: row};
  yield [
    for (final id in ids)
      if (byId[id] != null) byId[id]!,
  ];
}

/// Yerel listede gösterilen ileti sayısı — kaydırdıkça artar.
class PageLimitNotifier extends Notifier<int> {
  static const int step = 60;

  @override
  int build() => step;

  void grow() => state = state + step;
  void reset() => state = step;
}

final pageLimitProvider = NotifierProvider<PageLimitNotifier, int>(
  PageLimitNotifier.new,
);

/// Klasör başına okunmamış sayısı.
final unreadCountProvider = FutureProvider.family<int, int>((
  ref,
  mailboxId,
) async {
  ref.watch(messageListProvider);
  return ref.watch(databaseProvider).countUnread(mailboxId);
});

/// Belirli bir hesabın sabitlenen ileti sayısı — çoklu hesap yan menüsü
/// için. Etkin hesapta ileti listesi değiştikçe de tazelenir; diğer
/// hesaplar zaten arka planda eşitlenmediğinden bu ekstra tetikleyiciye
/// ihtiyaç duymaz.
final flaggedCountForAccountProvider = FutureProvider.family<int, int>((
  ref,
  accountId,
) async {
  if (accountId == ref.watch(accountIdProvider)) {
    ref.watch(messageListProvider);
  }
  return ref.watch(databaseProvider).countFlagged(accountId);
});

// ------------------------------------------------------------- seçim modu

class SelectionNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void toggle(int messageId) {
    final next = {...state};
    if (!next.remove(messageId)) next.add(messageId);
    state = next;
  }

  void selectAll(Iterable<int> ids) => state = ids.toSet();
  void clear() => state = const {};
  bool contains(int id) => state.contains(id);
}

final selectionProvider = NotifierProvider<SelectionNotifier, Set<int>>(
  SelectionNotifier.new,
);

final isSelectionModeProvider = Provider<bool>(
  (ref) => ref.watch(selectionProvider).isNotEmpty,
);

// ------------------------------------------------------------------ kabuk

/// Etkin modül: 0 İletiler, 1 Takvim, 2 Kişiler, 3 Ayarlar.
///
/// eM Client'ta olduğu gibi bu geçiş alt gezinme çubuğunda değil, hamburger
/// menünün altındaki modül listesinde yapılır (bkz. `FolderDrawer` içindeki
/// modül döşemeleri). Provider olmasının sebebi: hem `AppShell` (hangi
/// gövdeyi gösterdiğine karar verir) hem `FolderDrawer` (hangi modülün
/// vurgulanacağına ve dokunulunca neyi değiştireceğine karar verir) aynı
/// duruma ihtiyaç duyar — ikisi de birbirinin doğrudan atası/çocuğu değil.
class ActiveTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final activeTabProvider = NotifierProvider<ActiveTabNotifier, int>(
  ActiveTabNotifier.new,
);

// -------------------------------------------------------------- etiketler

final labelsProvider = StreamProvider<List<LabelRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <LabelRow>[]);
  return ref.watch(databaseProvider).watchLabels(accountId);
});

// ------------------------------------------------------------ giden kutusu

final outboxProvider = StreamProvider<List<MessageRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <MessageRow>[]);
  return ref.watch(databaseProvider).watchOutbox(accountId);
});

final pendingOperationCountProvider = StreamProvider<int>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(0);
  return ref.watch(databaseProvider).watchPendingCount(accountId);
});

// ------------------------------------------------------------- ileti detayı

final messageProvider = StreamProvider.family<MessageRow?, int>(
  (ref, id) => ref.watch(databaseProvider).watchMessageById(id),
);

final messageBodyProvider = StreamProvider.family<MessageBodyRow?, int>(
  (ref, id) => ref.watch(databaseProvider).watchBody(id),
);

final attachmentsProvider = StreamProvider.family<List<AttachmentRow>, int>(
  (ref, id) => ref.watch(databaseProvider).watchAttachments(id),
);

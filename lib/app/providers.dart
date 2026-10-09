import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/avatar.dart' show domainOf;
import '../core/date_format.dart';
import '../core/result.dart';
import '../core/turkish.dart';
import '../data/database/app_database.dart';
import '../domain/models/mail_models.dart';
import '../domain/use_cases/folder_mapping.dart';
import '../data/repositories/account_repository.dart';
import '../data/repositories/blocked_sender_repository.dart';
import '../data/repositories/sender_filter_sync.dart';
import '../data/services/managesieve_service.dart';
import '../data/repositories/settings_sync_service.dart';
import '../data/services/quick_templates_store.dart';
import '../data/services/settings_sync_state_store.dart';
import '../data/repositories/folder_repository.dart';
import '../data/repositories/mail_connection.dart';
import '../data/repositories/mail_repository.dart';
import '../data/repositories/new_mail_notifier.dart';
import '../data/repositories/sync_engine.dart';
import '../data/services/app_settings.dart';
import '../data/services/imap_service.dart';
import '../data/services/notification_service.dart';
import '../data/services/outgoing_attachment_store.dart';
import '../data/services/secure_store.dart';
import '../data/services/share_intake_service.dart';
import '../data/services/smtp_service.dart';
import 'sync_controller.dart';
import 'remote_push_flag.dart';

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

/// Sistem "Paylaş" menüsünden gelen dosyaların native katmandan alınması
/// (bkz. `ShareNavigator`).
final shareIntakeServiceProvider = Provider<ShareIntakeService>((ref) {
  final service = ShareIntakeService();
  ref.onDispose(service.dispose);
  return service;
});

/// Yazma ekranından eklenen dosyaların kalıcı deposu (bkz.
/// `OutgoingAttachmentStore`).
final outgoingAttachmentStoreProvider = Provider<OutgoingAttachmentStore>(
  (ref) => OutgoingAttachmentStore(),
);

final mailConnectionProvider = Provider<MailConnection>((ref) {
  final connection = MailConnection(
    database: ref.watch(databaseProvider),
    secureStore: ref.watch(secureStoreProvider),
    imapService: ref.watch(imapServiceProvider),
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

final newMailNotifierProvider = Provider<NewMailNotifier>(
  (ref) => NewMailNotifier(
    database: ref.watch(databaseProvider),
    notifications: ref.watch(notificationServiceProvider),
    remotePushShowsAlerts: remotePushShowsAlerts,
  ),
);

final mailRepositoryProvider = Provider<MailRepository>((ref) {
  final notifications = ref.watch(notificationServiceProvider);
  return MailRepository(
    database: ref.watch(databaseProvider),
    connection: ref.watch(mailConnectionProvider),
    syncEngine: ref.watch(syncEngineProvider),
    smtpService: ref.watch(smtpServiceProvider),
    // İleti bu cihazda okunduğunda/arşivlendiğinde/silindiğinde bildirimi de
    // gölgeden kalkar. Bildirim eklentisi yoksa (testler) hata yutulur.
    onMessagesHandled: (ids) =>
        unawaited(notifications.cancelMessages(ids).catchError((Object _) {})),
  );
});

/// Arşivle/sil sunucu işleminin "Geri al" için bekletildiği süre. Testler
/// kısaltmak için geçersiz kılar.
final mailUndoWindowProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 6),
);

/// Gönderilen iletinin "Geri al" (Undo Send) için bekletildiği süre (5 sn).
/// Testler beklemeden göndermek için kısa süreyle geçersiz kılar.
final sendUndoWindowProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// Sunucuda başarısız olup yerelde geri alınan arşivle/sil/taşı eylemleri.
final mailActionFailuresProvider = StreamProvider<MailActionFailure>(
  (ref) => ref.watch(mailRepositoryProvider).actionFailures,
);

/// Ayar eşitlemesinin (etiket/imza) hesap başına kalıcı durumu.
final settingsSyncStateStoreProvider = Provider<SettingsSyncStateStore>(
  (ref) => const PrefsSettingsSyncStateStore(),
);

/// Engellenen göndericilerin iletilerini posta sunucusundaki Sieve filtresiyle de İstenmeyen'e ayırır
/// (ManageSieve; desteklemeyen sunucuda sessizce devre dışı kalır).
final senderFilterSyncProvider = Provider<SenderFilterSync>((ref) {
  final sync = SenderFilterSync(
    database: ref.watch(databaseProvider),
    connection: ref.watch(mailConnectionProvider),
    service: ManageSieveService(),
  );
  ref.onDispose(sync.dispose);
  return sync;
});

/// Etiketleri ve imzaları web istemcisiyle IMAP sunucusu üzerinden eşit tutar.
final settingsSyncServiceProvider = Provider<SettingsSyncService>((ref) {
  final service = SettingsSyncService(
    database: ref.watch(databaseProvider),
    connection: ref.watch(mailConnectionProvider),
    state: ref.watch(settingsSyncStateStoreProvider),
    seedsDefaults: true,
    templates: ref.watch(quickTemplatesStoreProvider),
    senderFilter: ref.watch(senderFilterSyncProvider),
    onTemplatesChanged: () =>
        ref.read(quickTemplatesProvider.notifier).refresh(),
  );
  // Hazır şablonlar bu cihazda değişince (ekle/düzenle/sil) tüm hesapların ayar belgesi yenilenir.
  ref.listen(quickTemplatesProvider, (previous, next) {
    if (previous != null) service.scheduleAll();
  });
  ref.onDispose(service.dispose);
  return service;
});

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(
    database: ref.watch(databaseProvider),
    secureStore: ref.watch(secureStoreProvider),
    imapService: ref.watch(imapServiceProvider),
    smtpService: ref.watch(smtpServiceProvider),
    connection: ref.watch(mailConnectionProvider),
    settingsSync: ref.watch(settingsSyncServiceProvider),
  ),
);

/// Engellenen kullanıcılar: engelle / engeli kaldır (bkz. `BlockedSenderRepository`).
final blockedSenderRepositoryProvider = Provider<BlockedSenderRepository>(
  (ref) => BlockedSenderRepository(
    database: ref.watch(databaseProvider),
    mail: ref.watch(mailRepositoryProvider),
    settingsSync: ref.watch(settingsSyncServiceProvider),
    senderFilter: ref.watch(senderFilterSyncProvider),
  ),
);

final folderRepositoryProvider = Provider<FolderRepository>(
  (ref) => FolderRepository(
    database: ref.watch(databaseProvider),
    connection: ref.watch(mailConnectionProvider),
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

  Future<void> setThemeMode(AppThemeMode mode) =>
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
        await _save(
          state.copyWith(
            notificationsEnabled: false,
            notificationPermissionAsked: true,
          ),
        );
        return;
      }
    }
    await _save(
      state.copyWith(
        notificationsEnabled: enabled,
        notificationPermissionAsked:
            enabled || state.notificationPermissionAsked,
      ),
    );
  }

  /// İlk hesap hazır olduğunda bildirim iznini BİR KEZ ister.
  ///
  /// Varsayılan `notificationsEnabled = true` olduğundan kullanıcı ayarlardaki
  /// anahtara hiç dokunmazsa izin hiç istenmezdi ve Android 13+ cihazda hiçbir
  /// bildirim düşmezdi. Reddedilirse anahtar gerçek durumu yansıtsın diye
  /// kapatılır; kullanıcı istediğinde ayarlardan yeniden açabilir.
  Future<void> requestNotificationPermissionOnce() async {
    if (state.notificationPermissionAsked) return;
    // Bayrak İZİNDEN ÖNCE yazılır: pencere açıkken uygulama kapanırsa ya da
    // ikinci bir tetikleyici gelirse kullanıcı art arda sorulmasın.
    await _save(state.copyWith(notificationPermissionAsked: true));
    if (!state.notificationsEnabled) return;

    final granted = await ref
        .read(notificationServiceProvider)
        .requestPermission();
    if (!granted) {
      await _save(state.copyWith(notificationsEnabled: false));
    }
  }

  Future<void> setSyncFrequency(SyncFrequency frequency) =>
      _save(state.copyWith(syncFrequency: frequency));

  Future<void> setConfirmBeforeDelete(bool value) =>
      _save(state.copyWith(confirmBeforeDelete: value));

  Future<void> setSwipeRight(SwipeAction action) =>
      _save(state.copyWith(swipeRight: action));

  Future<void> setSwipeLeft(SwipeAction action) =>
      _save(state.copyWith(swipeLeft: action));

  Future<void> setShowBrandLogos(bool value) =>
      _save(state.copyWith(showBrandLogos: value));
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// Hesap bazında daraltılmış (alt klasörleri gizlenmiş) klasör id'leri.
class CollapsedFoldersNotifier extends Notifier<Map<int, Set<int>>> {
  @override
  Map<int, Set<int>> build() => const {};

  Set<int> getForAccount(int accountId) {
    return state[accountId] ??
        ref.read(settingsStoreProvider).readCollapsedFolders(accountId);
  }

  Future<void> toggle(int accountId, int mailboxId) async {
    final current = Set<int>.from(getForAccount(accountId));
    if (!current.remove(mailboxId)) {
      current.add(mailboxId);
    }
    state = {...state, accountId: current};
    await ref
        .read(settingsStoreProvider)
        .writeCollapsedFolders(accountId, current);
  }
}

final collapsedFoldersProvider =
    NotifierProvider<CollapsedFoldersNotifier, Map<int, Set<int>>>(
      CollapsedFoldersNotifier.new,
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

/// Kimliği bilinen tek bir hesap — ör. yazma ekranının "Gönderen" seçici
/// popup'ında, GENEL aktif hesabı değiştirmeden belirli bir hesabın adını/
/// e-postasını göstermek için (bkz. `ComposeScreen._fromAccountId`).
final accountByIdProvider = Provider.family<AccountRow?, int>((ref, id) {
  final accounts = ref.watch(allAccountsProvider).value;
  return accounts?.where((a) => a.id == id).firstOrNull;
});

// --------------------------------------------------------------- klasörler

final mailboxesProvider = StreamProvider<List<MailboxRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <MailboxRow>[]);
  return ref.watch(databaseProvider).watchMailboxes(accountId);
});

/// Cihazdaki hesapların e-posta alan adları (küçük harf). Bu alan adları için
/// marka logosu aranmaz: kullanıcının kendi (kurum içi) alan adını ağa
/// duyurmanın anlamı yok (bkz. `BrandAvatar`).
final ownEmailDomainsProvider = Provider<Set<String>>((ref) {
  final accounts = ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
  return {
    for (final account in accounts) ?domainOf(account.email),
  };
});

/// Belirli bir hesabın klasörleri — çoklu hesap yan menüsünde her hesap
/// kendi klasörlerini etkin hesap değişmeden gösterir.
final mailboxesForAccountProvider =
    StreamProvider.family<List<MailboxRow>, int>(
      (ref, accountId) => ref.watch(databaseProvider).watchMailboxes(accountId),
    );

/// One account-scoped, reactive hierarchy shared by folder surfaces.
/// The IMAP delimiter/path is the parent-child identity; no duplicate parent
/// column or per-screen tree cache is needed.
final folderTreeForAccountProvider = Provider.family<List<FolderTreeNode>, int>(
  (ref, accountId) {
    final mailboxes =
        ref.watch(mailboxesForAccountProvider(accountId)).value ??
        const <MailboxRow>[];
    return buildFolderTree(
      mailboxes,
      include: (mailbox) => mailbox.isSelectable,
    );
  },
);

/// Seçili klasör: tek bir hesabın klasörü, sanal "Sabitlenenler" ya da
/// "Tüm Hesaplar" görünümünde tüm hesapların aynı türdeki klasörlerinin
/// birleşimi ([SelectedFolder.unified]).
class SelectedFolder {
  const SelectedFolder.mailbox(this.mailboxId)
    : isFlaggedView = false,
      unifiedUse = null;
  const SelectedFolder.flagged()
    : mailboxId = null,
      isFlaggedView = true,
      unifiedUse = null;
  const SelectedFolder.unified(SpecialUse this.unifiedUse)
    : mailboxId = null,
      isFlaggedView = false;

  final int? mailboxId;
  final bool isFlaggedView;

  /// Doluysa "Tüm Hesaplar" modundayız ve bu, birleştirilen klasör türüdür.
  final SpecialUse? unifiedUse;

  bool get isUnified => unifiedUse != null;

  @override
  bool operator ==(Object other) =>
      other is SelectedFolder &&
      other.mailboxId == mailboxId &&
      other.isFlaggedView == isFlaggedView &&
      other.unifiedUse == unifiedUse;

  @override
  int get hashCode => Object.hash(mailboxId, isFlaggedView, unifiedUse);
}

/// Kullanıcının açıkça seçtiği klasör. `null` ise varsayılan uygulanır.
class SelectedFolderNotifier extends Notifier<SelectedFolder?> {
  @override
  SelectedFolder? build() => null;

  void select(SelectedFolder folder) => state = folder;

  /// Varsayılana (etkin hesabın Gelen Kutusu'na) döner — hesap değiştirme
  /// rayındaki avatara dokunma bunu kullanır (bkz. `FolderDrawer`).
  void reset() => state = null;
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
  final accountId = ref.watch(accountIdProvider);
  // Hesap değişiminde `mailboxesProvider` yeni hesabın stream'i ilk sonucu
  // verene kadar Riverpod'un "yeniden yükleme" davranışı yüzünden hâlâ
  // ESKİ hesabın klasör listesini `.value` olarak döndürür. Bu süzgeç
  // olmadan aşağıdaki varsayılan Gelen Kutusu hesaplaması yeni hesabın
  // ID'siyle eski hesabın klasör ID'sini eşleştirip `messageListProvider`'ı
  // var olmayan bir (yeni hesap, eski klasör) çiftiyle sorgulatıyordu —
  // sonuç her zaman sıfır satır olduğundan liste anlık olarak "Bu klasör
  // boş" gösterip hemen ardından gerçek iletilerle değişiyordu.
  final mailboxes = ref
      .watch(mailboxesProvider)
      .value
      ?.where((m) => m.accountId == accountId)
      .toList();

  if (chosen != null) {
    // Tüm Hesaplar görünümü hiçbir tek hesaba bağlı değildir.
    if (chosen.isFlaggedView || chosen.isUnified) return chosen;
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

// ------------------------------------------------------------ tüm hesaplar

/// "Tüm Hesaplar" görünümünde, yan menüdeki sıraya göre listelenen birleşik
/// klasör türleri. Özel (custom) klasörler hesaba özgüdür, birleştirilmez.
const List<SpecialUse> unifiedFolderUses = [
  SpecialUse.inbox,
  SpecialUse.drafts,
  SpecialUse.archive,
  SpecialUse.sent,
  SpecialUse.trash,
  SpecialUse.junk,
];

/// Tüm Hesaplar modunda mıyız? Home düğmesine dokunmak bunu açar; bir hesap
/// avatarına dokunmak (`SelectedFolderNotifier.reset`) kapatır. Etkin hesap
/// (`accountIdProvider`) bu moddan bağımsız olarak değişmeden kalır — senkron,
/// ayarlar ve yeni ileti gibi hesap-bağlı işler onu kullanmaya devam eder.
final isAllAccountsProvider = Provider<bool>(
  (ref) => ref.watch(selectedFolderProvider)?.isUnified ?? false,
);

/// Cihazdaki TÜM hesapların klasörleri.
final allMailboxesProvider = StreamProvider<List<MailboxRow>>(
  (ref) => ref.watch(databaseProvider).watchAllMailboxes(),
);

/// Her hesabın [use] türündeki klasörü — mevcut klasör eşleştirmesinin
/// (`FolderMapping`, `MailboxRow.specialUse`) sonucu; burada yeni bir eşleme
/// mantığı YOKTUR.
final unifiedMailboxesProvider =
    Provider.family<List<MailboxRow>, SpecialUse>((ref, use) {
      final all = ref.watch(allMailboxesProvider).value ?? const <MailboxRow>[];
      return [
        for (final box in all)
          if (box.specialUse == use && box.isSelectable) box,
      ];
    });

/// Tüm hesaplardaki [use] klasörlerinin okunmamış toplamı.
final unifiedUnreadCountProvider = StreamProvider.family<int, SpecialUse>((
  ref,
  use,
) {
  final ids = ref
      .watch(unifiedMailboxesProvider(use))
      .map((m) => m.id)
      .toList();
  if (ids.isEmpty) return Stream.value(0);
  return ref.watch(databaseProvider).watchUnreadCountIn(ids);
});

/// Görüntülenen klasörün türü: Tüm Hesaplar modunda birleşik türün kendisi,
/// aksi hâlde seçili klasörün türü. Silme onayı, kaydırma eylemi gibi
/// "hangi tür klasördeyim" bilmesi yeten yerler bunu kullanır.
final currentSpecialUseProvider = Provider<SpecialUse?>((ref) {
  final unified = ref.watch(selectedFolderProvider)?.unifiedUse;
  if (unified != null) return unified;
  return ref.watch(currentMailboxProvider)?.specialUse;
});

// -------------------------------------------------------------- filtre

/// Sıralama ölçütü. `dateDesc` sunucu/veritabanı sorgusunun zaten döndürdüğü
/// sıradır (bkz. `AppDatabase.watchMessages`); diğerleri istemcide uygulanır.
enum MessageSort { dateDesc, dateAsc, senderAZ, subjectAZ }

/// Geçerli listeye (klasör/Sabitlenenler/arama) uygulanan ek daraltma —
/// Gmail/Outlook'un arama çubuğu yanındaki filtre simgesindeki gibi.
///
/// Etiket dâhil tüm alanlar zaten yerelde tutulan `MessageRow` üzerinde
/// çalışır; bu yüzden ek bir veritabanı sorgusu gerekmez, `messageListProvider`
/// akıştan gelen listeyi bellekte daraltır (bkz. [MessageFilter.apply]).
class MessageFilter {
  const MessageFilter({
    this.unreadOnly = false,
    this.flaggedOnly = false,
    this.withAttachmentsOnly = false,
    this.labelName,
    this.sort = MessageSort.dateDesc,
  });

  final bool unreadOnly;
  final bool flaggedOnly;
  final bool withAttachmentsOnly;
  final String? labelName;
  final MessageSort sort;

  bool get isActive =>
      unreadOnly ||
      flaggedOnly ||
      withAttachmentsOnly ||
      labelName != null ||
      sort != MessageSort.dateDesc;

  MessageFilter copyWith({
    bool? unreadOnly,
    bool? flaggedOnly,
    bool? withAttachmentsOnly,
    String? Function()? labelName,
    MessageSort? sort,
  }) => MessageFilter(
    unreadOnly: unreadOnly ?? this.unreadOnly,
    flaggedOnly: flaggedOnly ?? this.flaggedOnly,
    withAttachmentsOnly: withAttachmentsOnly ?? this.withAttachmentsOnly,
    labelName: labelName != null ? labelName() : this.labelName,
    sort: sort ?? this.sort,
  );

  List<MessageRow> apply(List<MessageRow> rows) {
    var result = rows;
    if (unreadOnly) result = result.where((m) => !m.isSeen).toList();
    if (flaggedOnly) result = result.where((m) => m.isFlagged).toList();
    if (withAttachmentsOnly) {
      result = result.where((m) => m.hasAttachments).toList();
    }
    if (labelName != null) {
      final name = labelName!;
      result = result
          .where((m) => _decodeLabels(m.labelsJson).contains(name))
          .toList();
    }

    switch (sort) {
      case MessageSort.dateDesc:
        break; // sorgudan zaten bu sırada gelir
      case MessageSort.dateAsc:
        result = result.reversed.toList();
      case MessageSort.senderAZ:
        result = [...result]
          ..sort(
            (a, b) => trLower(a.fromName.isNotEmpty ? a.fromName : a.fromEmail)
                .compareTo(
                  trLower(b.fromName.isNotEmpty ? b.fromName : b.fromEmail),
                ),
          );
      case MessageSort.subjectAZ:
        result = [...result]
          ..sort((a, b) => trLower(a.subject).compareTo(trLower(b.subject)));
    }
    return result;
  }

  static List<String> _decodeLabels(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.whereType<String>().toList();
    } on FormatException {
      // Bozuk veri boş liste sayılır.
    }
    return const [];
  }
}

class MessageFilterNotifier extends Notifier<MessageFilter> {
  @override
  MessageFilter build() => const MessageFilter();

  void setUnreadOnly(bool value) => state = state.copyWith(unreadOnly: value);
  void setFlaggedOnly(bool value) => state = state.copyWith(flaggedOnly: value);
  void setWithAttachmentsOnly(bool value) =>
      state = state.copyWith(withAttachmentsOnly: value);
  void setLabel(String? name) => state = state.copyWith(labelName: () => name);
  void setSort(MessageSort sort) => state = state.copyWith(sort: sort);
  void clear() => state = const MessageFilter();
}

final messageFilterProvider =
    NotifierProvider<MessageFilterNotifier, MessageFilter>(
      MessageFilterNotifier.new,
    );

// -------------------------------------------------------------- liste

/// Görüntülenen ileti listesi: seçili klasörün içeriği (ya da sanal
/// "Sabitlenenler"), üzerine [messageFilterProvider]'daki daraltma/sıralama
/// uygulanır. Arama artık ayrı bir ekranda (`SearchScreen`, bkz.
/// `app/search_providers.dart`) yapılır, burayı etkilemez.
final messageListProvider = StreamProvider<List<MessageRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  final folder = ref.watch(selectedFolderProvider);
  final db = ref.watch(databaseProvider);
  final filter = ref.watch(messageFilterProvider);

  // Tüm Hesaplar: her hesabın aynı türdeki klasörü tek akışta birleşir. Etkin
  // hesaba bağlı değildir; klasör kümesi `unifiedMailboxesProvider`dan gelir.
  if (folder != null && folder.isUnified) {
    final use = folder.unifiedUse!;
    final ids = ref
        .watch(unifiedMailboxesProvider(use))
        .map((m) => m.id)
        .toList();
    if (ids.isEmpty) return Stream.value(const <MessageRow>[]);
    // Çöp Kutusu dahil hepsi tarihe göre karışık sıralanır: `id DESC`
    // (kayıt ekleme sırası) hesap başına toplu eşitlenen iletileri hesap
    // hesap öbekler ve hesapları birbirinden ayrılmış gösterir.
    return db
        .watchMessagesIn(
          mailboxIds: ids,
          limit: ref.watch(pageLimitProvider),
          excludeDrafts: use == SpecialUse.inbox,
        )
        .map((rows) => filter.apply(_dedupeAcrossAccounts(rows)));
  }

  if (accountId == null || folder == null) {
    // Hiç ileti YOK değil, klasör henüz BİLİNMİYOR (hesap değişiminde
    // `selectedFolderProvider` yeni hesabın klasörleri gelene kadar kısa
    // bir an `null` döner — bkz. o sağlayıcının açıklaması). `Stream.value`
    // burada anlık bir `AsyncData([])` üretip listeyi "Bu klasör boş"
    // durumuna düşürüyordu; hiç yayın yapmayan bir akış bu sağlayıcıyı
    // `AsyncLoading` bırakır ve Riverpod önceki hesabın son listesini
    // (bkz. `mailListItemsProvider`'daki `l.hasValue` dalı) o an ekranda
    // tutar — birazdan gerçek klasör/ileti verisi gelince yerini sessizce
    // alır.
    return const Stream<List<MessageRow>>.empty();
  }

  // Çöp Kutusu'nda iletiler orijinal gönderi tarihine göre değil,
  // sildikten sonra çöp kutusuna taşınma sırasına göre (en son silinen
  // en üstte) gösterilir; bunun için `id DESC` proxy olarak kullanılır.
  final isTrash =
      ref.watch(currentMailboxProvider)?.specialUse == SpecialUse.trash;

  final Stream<List<MessageRow>> source = folder.isFlaggedView
      ? db.watchFlagged(accountId: accountId)
      : db.watchMessages(
          accountId: accountId,
          mailboxId: folder.mailboxId!,
          limit: ref.watch(pageLimitProvider),
          orderById: isTrash,
          // Taslaklar yalnızca Taslaklar klasöründe görünür: sunucuda Gelen
          // Kutusu'na `\Draft` bayrağıyla düşen iletiler ve Taslaklar klasörü
          // bilinmediğinde Gelen Kutusu'na yazılan yerel taslaklar gizlenir.
          excludeDrafts:
              ref.watch(currentMailboxProvider)?.specialUse == SpecialUse.inbox,
        );

  return source.map(filter.apply);
});

/// Aynı ileti (aynı `Message-ID` başlığı) birden çok hesabın kutusuna
/// düşmüşse (ör. iki adresine birden gönderilmiş ya da bir takma ad
/// yönlendirmesi) Tüm Hesaplar listesinde yalnızca BİR kez gösterilir —
/// listede önce gelen (sıralamaya göre en üstteki) kopya kalır. Aynı
/// hesaptaki kopyalara dokunulmaz: tek hesap görünümüyle aynı davranır.
List<MessageRow> _dedupeAcrossAccounts(List<MessageRow> rows) {
  final firstAccountOf = <String, int>{};
  final result = <MessageRow>[];
  for (final row in rows) {
    final header = row.messageIdHeader?.trim();
    if (header == null || header.isEmpty) {
      result.add(row);
      continue;
    }
    final owner = firstAccountOf.putIfAbsent(header, () => row.accountId);
    if (owner == row.accountId) result.add(row);
  }
  return result;
}

/// Liste ekranında gösterilecek tek bir öğe: tarih başlığı, ileti, boş
/// durum ya da Sabitlenenler bölümünün kendisi.
sealed class MailListItem {
  const MailListItem();
}

/// Listenin en başındaki Sabitlenenler bölümü (bkz. `_PinnedSection`).
class PinnedSectionItem extends MailListItem {
  const PinnedSectionItem();
}

/// "Bugün / Dün / Geçen Hafta" gibi tarih grubu başlığı.
class DateHeaderItem extends MailListItem {
  const DateHeaderItem(this.label);
  final String label;
}

/// Tek bir ileti satırı.
class MessageItem extends MailListItem {
  const MessageItem(this.message);
  final MessageRow message;
}

/// Klasör ilk kez eşitlenirken (yerel veri henüz eksik) gösterilen tek öğe:
/// ortada dönen yükleme göstergesi. Böylece kullanıcı klasörü boş sanmaz ve
/// iletiler parça parça dolmaz; indirme bitince liste tek seferde gelir.
class FolderLoadingItem extends MailListItem {
  const FolderLoadingItem();
}

/// Klasör/filtre sonucu boşsa gösterilecek tek öğe — [filterActive] hangi
/// boş-durum mesajının gösterileceğini belirler.
class EmptyListItem extends MailListItem {
  const EmptyListItem({required this.filterActive});
  final bool filterActive;
}

/// Liste ekranında gösterilecek nihai öğe dizisi (tarih başlıkları + iletiler
/// + Sabitlenenler bölümü + boş durum).
///
/// SADECE ileti verisi, klasör/hesap ya da sıralama değiştiğinde yeniden
/// hesaplanır — seçim modunda tek tek satır seçmek (`selectionProvider`)
/// veya filtre menüsünü açıp kapatmak (sıralama/aktiflik dışındaki alanlar)
/// bu provider'ı TETİKLEMEZ, çünkü Riverpod yalnızca aşağıda `ref.watch`
/// edilenleri izler. Bu gruplama BİLE İSTEYEREK `MailListScreen.build()`
/// içinde YAPILMAZ: orada yapılsaydı, widget'ın izlediği HERHANGİ bir state
/// değiştiğinde (ör. tek bir satır seçildiğinde) binlerce satırlık liste
/// baştan gruplanırdı.
final mailListItemsProvider = Provider<AsyncValue<List<MailListItem>>>((ref) {
  final messages = ref.watch(messageListProvider);
  final mailbox = ref.watch(currentMailboxProvider);
  final folder = ref.watch(selectedFolderProvider);
  final accountId = ref.watch(accountIdProvider);

  final sort = ref.watch(messageFilterProvider.select((f) => f.sort));
  final filterActive = ref.watch(
    messageFilterProvider.select((f) => f.isActive),
  );
  // Bu klasör DAHA ÖNCE HİÇ eşitlenmedi (bkz. `SyncEngine.syncMailbox`
  // içindeki `neverSynced = mailbox.uidNext == null` — ilk indirme
  // tamamlanana kadar `uidNext` yerelde yazılmaz) VE tam da şu an bir
  // eşitleme sürüyor mu? Klasöre ilk kez girildiğinde (ör. daha önce hiç
  // açılmamış bir Çöp Kutusu) yerel veritabanında GERÇEKTEN sıfır satır
  // vardır — `visible.isEmpty` burada YALAN söylemiyor, henüz IMAP'tan
  // hiçbir şey inmedi. Bu yüzden `rowsMatchFolder` (yukarıdaki, farklı
  // klasörün BAYAT verisini yakalayan kontrol) bunu YAKALAMAZ: `messages`
  // zaten kendi (doğru, boş) klasörü için `AsyncData([])`e ulaşmıştır.
  // Sonuç: kullanıcı IMAP indirmesi bitene kadar (birkaç yüz ms - birkaç
  // saniye) "Bu klasör boş" görür, sonra gerçek iletiler görünür. Bu kontrol
  // olmadan o an için `AsyncData` doğru ama YANILTICI. `uidNext == null` +
  // `isSyncing` ikisi birden doğruyken bu "boş" henüz KESİNLEŞMEMİŞ sayılır
  // ve iskelet gösterilir; eşitleme bitince (mesaj bulunsa da bulunmasa da)
  // iskelet kalkar.
  final unifiedUse = folder?.unifiedUse;
  final unifiedMailboxIds = unifiedUse == null
      ? const <int>{}
      : ref
            .watch(unifiedMailboxesProvider(unifiedUse))
            .map((m) => m.id)
            .toSet();
  final neverSyncedFolder = mailbox != null && mailbox.uidNext == null;
  final syncInFlight = ref.watch(
    syncControllerProvider.select((s) => s.isSyncing),
  );
  // Eşitleme henüz BAŞLAMAMIŞ olsa da (`lastSyncAt` eşitleme başında yazılır)
  // klasör "yükleniyor" sayılır; aksi hâlde klasöre girilip eşitleme
  // başlayana kadarki aralıkta "Bu klasör boş" yanıp sönerdi. Çevrimdışı ya da
  // hatalıysa sonsuz yüklemeye girmemek için boş durum gösterilir.
  final syncUnavailable = ref.watch(
    syncControllerProvider.select((s) => s.isOffline || s.lastError != null),
  );
  final coldFolderStillLoading =
      neverSyncedFolder &&
      (syncInFlight || (mailbox.lastSyncAt == null && !syncUnavailable));

  List<MailListItem> buildItems(List<MessageRow> rows) {
    // Sabitlenenler bölümü yalnızca Gelen Kutusu'nda gösterilir — diğer
    // klasörlere geçildiğinde ya da seçim modunda/bir filtre etkinken
    // kaybolmalı.
    // Tüm Hesaplar Gelen Kutusu'nda da gösterilir (tüm hesapların
    // sabitlenenleri birleşik; bkz. [pinnedMessagesProvider]).
    final showPinned =
        folder != null &&
        !folder.isFlaggedView &&
        (folder.isUnified
            ? folder.unifiedUse == SpecialUse.inbox
            : mailbox?.specialUse == SpecialUse.inbox) &&
        !filterActive;

    final visible = showPinned
        ? rows.where((m) => !m.isFlagged).toList()
        : rows;
    final groupByDate =
        sort == MessageSort.dateDesc || sort == MessageSort.dateAsc;

    final items = <MailListItem>[if (showPinned) const PinnedSectionItem()];

    if (visible.isEmpty) {
      items.add(EmptyListItem(filterActive: filterActive));
      return items;
    }

    if (!groupByDate) {
      items.addAll(visible.map(MessageItem.new));
      return items;
    }

    // `visible` zaten tarihe göre yeniden-eskiye sıralı geldiği için (bkz.
    // `watchMessages`) tek geçişte ardışık grup değişimini yakalamak yeterli.
    String? lastLabel;
    for (final message in visible) {
      final label = formatGroupHeader(message.dateUtc);
      if (label != lastLabel) {
        items.add(DateHeaderItem(label));
        lastLabel = label;
      }
      items.add(MessageItem(message));
    }
    return items;
  }

  // Kasıtlı olarak `messages.whenData(...)` KULLANILMIYOR: o metodun
  // `loading` dalı önceki değeri her zaman atıp çıplak bir `AsyncLoading()`
  // döner (bkz. Riverpod `AsyncValue.whenData` kaynağı) — "daha fazla ileti
  // yükle" `pageLimitProvider`'ı büyüttüğünde `messageListProvider` yeniden
  // kurulur ve az önceki liste burada kaybolurdu. Bu da `MailListScreen`
  // içindeki `skipLoadingOnReload: true`'yu anlamsız kılıp her seferinde tam
  // listeyi `_ListSkeleton` (shimmer) haline döndürüyordu. Burada `messages`
  // yeniden yüklenirken bile (`hasValue`) önceki satırlardan öğeler
  // üretilmeye devam edilip doğrudan `AsyncData` olarak döndürülüyor —
  // gösterilen liste `loadMore` sırasında hiç kaybolmuyor, yalnızca listenin
  // altındaki `_LoadMoreControl` "Yükleniyor…" metnine dönüyor.
  //
  // ANCAK bu "önceki değeri koru" davranışı `messageListProvider`ın
  // izlediği HERHANGİ bir şey değiştiğinde tetiklenir — `pageLimitProvider`
  // kadar `folder`/`accountId` için de geçerlidir. Klasör değiştirildiğinde
  // (ör. Gelen Kutusu → Gönderilenler) `folder`/`mailbox` yukarıda ANINDA
  // yeni klasöre geçer, ama Drift'in yeni klasör için sorgusu bir sonraki
  // mikro görevde sonuçlanır; o arada `l.value` HÂLÂ ESKİ klasörün
  // satırlarıdır. `_rowsMatchFolder` kontrolü olmadan bu eski satırlar yeni
  // klasörün bağlamıyla (`buildItems` içindeki `showPinned`/gruplama) işlenip
  // ekrana yazılıyordu — eski klasör o an boşsa (veya farklı sayıda ileti
  // içeriyorsa) kullanıcı gerçekte boş OLMAYAN yeni klasörde anlık "Bu
  // klasör boş" görüyor, hemen ardından gerçek içerik onun yerini alıyordu.
  // Satırlar seçili klasörle eşleşmiyorsa (ya da boşsa — boş bir listeden
  // hangi klasöre ait olduğu anlaşılamaz, güvenli tarafta kalınır) burada
  // `AsyncLoading` dönülür; `MailListScreen` bunu `_ListSkeleton` ile
  // karşılar — yanlış klasörün (veya yanlış "boş") içeriğini göstermektense
  // kısa bir iskelet, doğru davranış.
  bool rowsMatchFolder(List<MessageRow> rows) {
    if (rows.isEmpty || folder == null) return false;
    if (folder.isUnified) {
      // Tüm Hesaplar: satırlar bu türün herhangi bir hesaptaki klasöründen
      // gelmeli (aksi hâlde tek hesabın önceki klasörünün bayat satırlarıdır).
      return unifiedMailboxIds.contains(rows.first.mailboxId);
    }
    if (accountId == null) return false;
    final sample = rows.first;
    if (sample.accountId != accountId) return false;
    return folder.isFlaggedView
        ? rows.every((m) => m.isFlagged)
        : sample.mailboxId == folder.mailboxId;
  }

  // Soğuk klasörde (ilk indirme sürerken) gelen kısmi/bayat satırlar
  // gösterilmez: indirme bitene kadar yalnızca yükleme göstergesi çıkar.
  if (coldFolderStillLoading && !messages.hasError) {
    return const AsyncData<List<MailListItem>>([FolderLoadingItem()]);
  }

  return messages.map(
    data: (d) => AsyncData(buildItems(d.value)),
    error: (e) => AsyncError(e.error, e.stackTrace),
    loading: (l) {
      final previousRows = l.value;
      if (previousRows != null && rowsMatchFolder(previousRows)) {
        return AsyncData(buildItems(previousRows));
      }
      return AsyncLoading<List<MailListItem>>(progress: l.progress);
    },
  );
});

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
///
/// Doğrudan `AppDatabase.watchUnreadCount`'a bağlıdır — Drift bu sorgunun
/// izlediği tabloyu kendisi takip eder. Eskiden `messageListProvider`'ı
/// (yalnızca O AN görüntülenen klasörün akışı) izleyerek tetikleniyordu; bu
/// hem yanlıştı (arka planda değişen başka bir klasörün rozeti hiç
/// güncellenmezdi) hem de gereksiz maliyetliydi (görüntülenen klasörün
/// listesi her değiştiğinde yan menüdeki TÜM klasörlerin rozeti tekrar
/// sorgulanırdı).
final unreadCountProvider = StreamProvider.family<int, int>(
  (ref, mailboxId) => ref.watch(databaseProvider).watchUnreadCount(mailboxId),
);

/// Belirli bir hesabın sabitlenen ileti sayısı — çoklu hesap yan menüsü
/// için.
///
/// Doğrudan `AppDatabase.watchFlaggedCount`'a bağlıdır (bkz.
/// [unreadCountProvider]'daki aynı gerekçe). Eskiden yalnızca etkin hesapta
/// `messageListProvider`'ı izleyerek yapay bir tetikleyici ekliyordu; artık
/// gerek yok — Drift kendi değişiklik izlemesini yapıyor ve etkin olmayan
/// hesaplarda zaten hiç değişiklik olmadığından stream kendiliğinden sakin
/// kalıyor.
final flaggedCountForAccountProvider = StreamProvider.family<int, int>(
  (ref, accountId) => ref.watch(databaseProvider).watchFlaggedCount(accountId),
);

/// Sabitlenmiş iletiler — normal bir klasör görüntülenirken listenin üstünde
/// gösterilir (bkz. `_PinnedSection`) ve aynı ileti kronolojik listede
/// TEKRARLANMASIN diye oradan çıkarılır (bkz. [mailListItemsProvider]). Tam
/// liste ayrıca "Sabitlenenler" sanal klasöründe de görülebilir (bkz.
/// [SelectedFolder.flagged]).
///
/// Tüm Hesaplar Gelen Kutusu'nda tüm hesapların sabitlenenleri birleşik
/// gelir (aynı `Message-ID` bir kez); aksi hâlde yalnızca etkin hesabınki.
final pinnedMessagesProvider = StreamProvider<List<MessageRow>>((ref) {
  final db = ref.watch(databaseProvider);
  final folder = ref.watch(selectedFolderProvider);

  if (folder != null && folder.isUnified) {
    final accountIds = {
      for (final box in ref.watch(unifiedMailboxesProvider(folder.unifiedUse!)))
        box.accountId,
    }.toList();
    if (accountIds.isEmpty) return Stream.value(const <MessageRow>[]);
    return db
        .watchFlaggedIn(accountIds: accountIds)
        .map(_dedupeAcrossAccounts);
  }

  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <MessageRow>[]);
  return db.watchFlagged(accountId: accountId);
});

/// Gelen Kutusu'ndaki Sabitlenenler bölümünün açık/kapalı (expand/collapse) durumu.
class PinnedSectionExpandedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void setExpanded(bool value) => state = value;
}

final pinnedSectionExpandedProvider =
    NotifierProvider<PinnedSectionExpandedNotifier, bool>(
      PinnedSectionExpandedNotifier.new,
    );

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

/// Etkin modül: 0 İletiler, 1 Kişiler, 2 Ayarlar.
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

/// Uygulamanın kök hedefindeyiz: İletiler modülü + Gelen Kutusu.
///
/// Modül/klasör geçişleri `Navigator` rotası değil, yalnızca bu state'ler
/// olduğu için sistem geri tuşu bunları hiç görmez ve doğrudan uygulamayı
/// kapatır. `AppShell`, bu provider'ı `PopScope.canPop` olarak kullanır:
/// kökteyken geri tuşu varsayılan (uygulamadan çık) davranışına bırakılır,
/// değilse yutulup Gelen Kutusu'na dönülür (bkz. `AppShell` içindeki
/// `PopScope`).
final isAtRootDestinationProvider = Provider<bool>((ref) {
  if (ref.watch(activeTabProvider) != 0) return false;
  final selected = ref.watch(selectedFolderProvider);
  if (selected == null) return true; // klasörler henüz yüklenmedi
  if (selected.isFlaggedView) return false;
  if (selected.isUnified) return selected.unifiedUse == SpecialUse.inbox;
  final mailbox = ref.watch(currentMailboxProvider);
  return mailbox == null || mailbox.specialUse == SpecialUse.inbox;
});

// -------------------------------------------------------------- etiketler

final labelsProvider = StreamProvider<List<LabelRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <LabelRow>[]);
  return ref.watch(databaseProvider).watchLabels(accountId);
});

/// [labelsProvider] ile aynı sorgu, ama belirli bir hesaba göre — Tüm
/// Hesaplar görünümünde bir iletinin etiket menüsü, etkin hesabınkini değil
/// iletinin KENDİ hesabının etiketlerini listelemeli.
final labelsForAccountProvider = StreamProvider.family<List<LabelRow>, int>(
  (ref, accountId) => ref.watch(databaseProvider).watchLabels(accountId),
);

// --------------------------------------------------------------- imzalar

final signaturesProvider = StreamProvider<List<SignatureRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <SignatureRow>[]);
  return ref.watch(databaseProvider).watchSignatures(accountId);
});

/// Yazma ekranı açılışta otomatik eklenen imza. Kullanıcı hiçbirini
/// varsayılan yapmadıysa (ör. eski hesaplarda göç sırasında ilk imza zaten
/// varsayılan işaretlenir) listedeki ilk imzaya düşülür.
final defaultSignatureProvider = Provider<SignatureRow?>((ref) {
  final signatures = ref.watch(signaturesProvider).value;
  if (signatures == null || signatures.isEmpty) return null;
  return signatures.where((s) => s.isDefault).firstOrNull ?? signatures.first;
});

/// [signaturesProvider] ile aynı sorgu, ama GENEL aktif hesap yerine
/// belirli bir hesaba göre — yazma ekranında "Gönderen" olarak başka bir
/// hesap seçildiğinde (bkz. `ComposeScreen._fromAccountId`) Gelen Kutusu'nun
/// hesabını değiştirmeden o hesabın imzalarını göstermek için.
final signaturesForAccountProvider =
    StreamProvider.family<List<SignatureRow>, int>(
      (ref, accountId) =>
          ref.watch(databaseProvider).watchSignatures(accountId),
    );

/// [defaultSignatureProvider]'ın hesaba özel biçimi — bkz.
/// [signaturesForAccountProvider].
final defaultSignatureForAccountProvider = Provider.family<SignatureRow?, int>((
  ref,
  accountId,
) {
  final signatures = ref.watch(signaturesForAccountProvider(accountId)).value;
  if (signatures == null || signatures.isEmpty) return null;
  return signatures.where((s) => s.isDefault).firstOrNull ?? signatures.first;
});

// ------------------------------------------------- engellenen kullanıcılar

/// Etkin hesabın engellediği adresler, en yeni en üstte.
final blockedSendersProvider = StreamProvider<List<BlockedSenderRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <BlockedSenderRow>[]);
  return ref.watch(databaseProvider).watchBlockedSenders(accountId);
});

/// Verilen hesabın engellediği adresler (iletinin hesabı etkin hesaptan farklı olabilir).
final blockedSendersOfAccountProvider =
    StreamProvider.family<List<BlockedSenderRow>, int>(
      (ref, accountId) =>
          ref.watch(databaseProvider).watchBlockedSenders(accountId),
    );

// ---------------------------------------------------------------- kişiler

/// En son kullanılan en üstte (bkz. `AppDatabase.watchContacts`) — hem
/// Kişiler sekmesi hem de yazma ekranının Kime/Bilgi/Gizli otomatik
/// tamamlaması bu tek listeyi kullanır.
final contactsProvider = StreamProvider<List<ContactRow>>((ref) {
  final accountId = ref.watch(accountIdProvider);
  if (accountId == null) return Stream.value(const <ContactRow>[]);
  return ref.watch(databaseProvider).watchContacts(accountId);
});

/// [contactsProvider] ile aynı sorgu, ama belirli bir hesaba göre — bkz.
/// [signaturesForAccountProvider]'daki aynı gerekçe.
final contactsForAccountProvider = StreamProvider.family<List<ContactRow>, int>(
  (ref, accountId) => ref.watch(databaseProvider).watchContacts(accountId),
);

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

/// [MailRepository.ensureBody]'nin indirme DURUMU — `messageBodyProvider`nin
/// aksine veriyi değil, "indirme bitti mi / hata mı / hâlâ sürüyor mu"
/// bilgisini tutar. `_BodyView` bunu ilk izlediği anda (ekran açıldığında)
/// otomatik tetiklenir; gövde zaten yerelde inmişse `ensureBody` tek bir DB
/// okumasıyla anında döner (bkz. `MailRepository.ensureBody`) — gerçek bir
/// ağ isteği yalnızca gövde eksikse yapılır ("Offline-First").
///
/// Sonuç kasıtlı olarak `messageBodyProvider(id).future`den `ref.read` ile
/// okunur (İZLEMEDEN — aksi hâlde akış her güncellendiğinde `ensureBody`
/// gereksiz yere tekrar çalışırdı): bu sayede bu provider, indirme bitmiş
/// olsa BİLE `messageBodyProvider`nin akışı yeni satırı gerçekten yayana
/// kadar `loading` kalmaya devam eder. Böylece "indirme bitti" ile "veri
/// ekranda görünür oldu" arasında `_BodyView`'in shimmer'ı erken kapatıp
/// bir kare "içerik yok" mesajı göstermesine yol açacak bir yarış durumu
/// (race condition) yapısal olarak imkânsız hâle gelir.
///
/// `autoDispose`: ekrandan çıkılınca (bu `messageId` artık izlenmeyince)
/// durum hemen atılır — `messageBodyProvider`nin aksine burada canlı
/// tutmaya değer bir veri yok, sadece bir kerelik işlemin sonucu.
final bodyFetchProvider = FutureProvider.autoDispose
    .family<MessageBodyRow?, int>((ref, id) async {
      final result = await ref.read(mailRepositoryProvider).ensureBody(id);
      if (result case Err(:final failure)) throw failure;
      return ref.read(messageBodyProvider(id).future);
    });

final attachmentsProvider = StreamProvider.family<List<AttachmentRow>, int>(
  (ref, id) => ref.watch(databaseProvider).watchAttachments(id),
);

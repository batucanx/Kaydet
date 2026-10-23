import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import '../services/push_backend_client.dart';

/// Sunucuya en son neyin kaydedildiği. Şifre ya da başka bir sır İÇERMEZ:
/// hesap başına yalnızca "bağlantı parmak izi" tutulur (bkz.
/// `RemotePushSync.fingerprint`).
class RegistrationSnapshot {
  const RegistrationSnapshot({
    this.token,
    this.fingerprints = const {},
    this.unhealthy = const {},
  });

  /// Kayıtların yapıldığı push token'ı (iOS'ta APNs, Android'de FCM).
  final String? token;

  /// Hesap kimliği → o hesabın sunucuya kaydedilen parmak izi.
  final Map<int, String> fingerprints;

  /// Son mutabakatta sunucunun İZLEYEMEDİĞİ hesaplar (bkz.
  /// [RemotePushSyncResult.unhealthyAccountIds]). Arka plan isolate'leri de
  /// okuyabilsin diye kalıcıdır (bkz. [ServerPushCoverage]).
  final Set<int> unhealthy;
}

abstract interface class RegistrationStore {
  RegistrationSnapshot read();

  Future<void> write(RegistrationSnapshot snapshot);
}

class SharedPrefsRegistrationStore implements RegistrationStore {
  SharedPrefsRegistrationStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kToken = 'kaydet.remotePush.token';
  static const _kAccounts = 'kaydet.remotePush.accounts';
  static const _kUnhealthy = 'kaydet.remotePush.unhealthy';

  @override
  RegistrationSnapshot read() {
    final raw = _prefs.getString(_kAccounts);
    final fingerprints = <int, String>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final id = int.tryParse('${entry.key}');
            if (id != null && entry.value is String) {
              fingerprints[id] = entry.value as String;
            }
          }
        }
      } on FormatException catch (_) {
        // Bozuk kayıt: boş say, bir sonraki eşitleme her şeyi yeniden yazar.
      }
    }
    return RegistrationSnapshot(
      token: _prefs.getString(_kToken),
      fingerprints: fingerprints,
      unhealthy: {
        for (final id in _prefs.getStringList(_kUnhealthy) ?? const <String>[])
          if (int.tryParse(id) != null) int.parse(id),
      },
    );
  }

  @override
  Future<void> write(RegistrationSnapshot snapshot) async {
    final token = snapshot.token;
    if (token == null) {
      await _prefs.remove(_kToken);
    } else {
      await _prefs.setString(_kToken, token);
    }
    await _prefs.setString(
      _kAccounts,
      jsonEncode({
        for (final e in snapshot.fingerprints.entries) '${e.key}': e.value,
      }),
    );
    await _prefs.setStringList(_kUnhealthy, [
      for (final id in snapshot.unhealthy) id.toString(),
    ]);
  }
}

/// iOS'ta yeni ileti bildirimini sunucu push'u (APNs) gösterir; aynı iletiyi
/// yerel olarak da bildirmek çift bildirim olurdu. Ama bu YALNIZCA sunucu o
/// hesabı gerçekten izliyorsa doğrudur: kimliği reddedilmiş ya da
/// ulaşılamayan bir hesabın hiçbir APNs push'u gelmez ve yerel bildirim de
/// bastırılırsa hesap tamamen sessiz kalırdı. Bu sınıf, son mutabakatta
/// kaydedilen "izlenemeyen hesaplar" listesinden bu kararı verir.
class ServerPushCoverage {
  ServerPushCoverage([Future<SharedPreferences> Function()? preferences])
    : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  /// Sunucu push'u [accountId] için bildirim gösterir mi? Durum okunamazsa
  /// `true` (eski davranış); bilinen sağlıksız hesapta `false`.
  Future<bool> covers(int accountId) async {
    try {
      final prefs = await _preferences();
      await prefs.reload();
      return !SharedPrefsRegistrationStore(prefs).read().unhealthy.contains(
        accountId,
      );
    } on Object catch (_) {
      return true;
    }
  }
}

/// Bir eşitleme turunun sonucu (bkz. [RemotePushSync.reconcile]).
class RemotePushSyncResult {
  const RemotePushSyncResult({
    required this.ok,
    this.unhealthyAccountIds = const {},
    this.repairedAccountIds = const {},
  });

  /// Her şey eşitlendi mi? `false`: ağ/sunucu hatası, çağıran yeniden denemeli.
  final bool ok;

  /// Sunucuda KAYITLI ama sunucunun şu an izleyemediği hesaplar (kimlik
  /// reddedildi, posta sunucusuna ulaşılamıyor). Sunucu push'u bu hesaplar için
  /// çalışmaz; Android'de yerel ön plan servisi yedek olarak devreye girmelidir.
  final Set<int> unhealthyAccountIds;

  /// Bu turda taze bilgilerle yeniden kaydedilen hesaplar. Durumları henüz
  /// doğrulanmadı; çağıran kısa süre sonra yeniden denetlemelidir.
  final Set<int> repairedAccountIds;
}

/// Cihazdaki hesapları push sunucusuyla eşler.
///
/// Sunucu, IMAP IDLE ile posta kutusunu izleyip yeni iletide APNs/FCM push'u
/// gönderdiğinden hesabın IMAP bilgilerini (şifre dahil) bilmek zorundadır.
/// Bu sınıf yalnızca gerektiğinde konuşur: her çağrıda tüm hesapları
/// yeniden göndermek, sunucudaki IDLE bağlantısını boşuna sıfırlardı.
///
/// Her hesap AYRI kaydedilir ve ayrı raporlanır: bir hesabın kaydı/silinmesi
/// ya da hatası (`clientAccountId` başına satır) diğerlerinin kaydına dokunmaz.
class RemotePushSync {
  RemotePushSync({
    required RemotePushApi api,
    required RegistrationStore store,
    required Future<String?> Function(int accountId) readPassword,
    required this.environment,
    this.log,
    DateTime Function()? now,
  }) : _api = api,
       _store = store,
       _readPassword = readPassword,
       _now = now ?? DateTime.now;

  final RemotePushApi _api;
  final RegistrationStore _store;
  final Future<String?> Function(int accountId) _readPassword;
  final DateTime Function() _now;

  /// `development` (Xcode debug derlemesi) ya da `production`.
  final String environment;

  /// Teşhis günlüğü. Şifre, token ve adres YAZILMAZ; yalnızca ne olduğu.
  final void Function(String message)? log;

  /// Sunucunun izleyemediği bir hesabı yeniden kaydetmek için asgari aralık:
  /// kalıcı olarak reddedilen bir şifreyi sürekli göndermek sağlayıcıda hesabı
  /// kilitletebilir.
  static const Duration repairGap = Duration(minutes: 10);

  final Map<int, DateTime> _lastRepair = {};

  /// Bir hesabın sunucuda yeniden kaydedilmesini gerektiren her şey. Şifre
  /// bilerek yok: değiştiğinde [sync]'e `force` verilir.
  String fingerprint(String token, AccountRow a) =>
      '${_api.baseUrl}|$token|$environment|${a.imapHost}|${a.imapPort}|'
      '${a.imapSecurity.index}|${a.username}';

  /// [reconcile]'ın yalnızca başarı bilgisini döndüren kısa yolu.
  Future<bool> sync({
    required String? token,
    required bool enabled,
    required List<AccountRow> accounts,
    Set<int> force = const {},
  }) async => (await reconcile(
    token: token,
    enabled: enabled,
    accounts: accounts,
    force: force,
  )).ok;

  /// Sunucuyu istenen duruma getirir. Her şey eşitse `ok` olur; ağ/sunucu
  /// hatasında `ok` olmaz (çağıran daha sonra yeniden dener).
  ///
  /// - [enabled] kapalıysa cihazın tüm kayıtları (ve şifreler) sunucudan silinir.
  /// - [token] henüz yoksa hiçbir şey yapılmaz.
  /// - [force]: parmak izi aynı olsa da yeniden gönderilecek hesaplar
  ///   (ör. şifresi değişenler).
  ///
  /// Sunucu bir hesabı "kimlik reddedildi"/"izleyici yok" diye bildiriyorsa o
  /// hesap (en çok her [repairGap]'te bir) cihazdaki güncel şifreyle yeniden
  /// kaydedilir; "kayıtlı" olmak "izleniyor" demek değildir.
  Future<RemotePushSyncResult> reconcile({
    required String? token,
    required bool enabled,
    required List<AccountRow> accounts,
    Set<int> force = const {},
  }) async {
    final snapshot = _store.read();
    final fingerprints = {...snapshot.fingerprints};
    var syncedToken = snapshot.token;
    // Sunucuya ulaşılamadıysa son bilinen sağlık durumu korunur.
    var unhealthyIds = snapshot.unhealthy;

    Future<void> persist() => _store.write(
      RegistrationSnapshot(
        token: syncedToken,
        fingerprints: fingerprints,
        unhealthy: unhealthyIds,
      ),
    );

    if (!enabled) {
      if (syncedToken == null && fingerprints.isEmpty) {
        return const RemotePushSyncResult(ok: true);
      }
      try {
        if (syncedToken != null) await _api.deleteDevice(syncedToken);
      } on Object catch (e) {
        _logFailure('cihaz kaydı silinemedi', e);
        // silinemedi; kayıt durumu korunur, tekrar denenir
        return const RemotePushSyncResult(ok: false);
      }
      fingerprints.clear();
      syncedToken = null;
      unhealthyIds = const {};
      await persist();
      return const RemotePushSyncResult(ok: true);
    }
    if (token == null) return const RemotePushSyncResult(ok: true);

    // Token değişti (FCM yenilemesi, yeniden kurulum, yeni cihaz).
    //
    // Eski kayıt, taşınacak bir hesap varsa SİLİNMEZ: sunucu yeni token'ın ilk
    // kaydında aynı kurulumun eski cihaz satırındaki hesapları yenisine TAŞIR
    // (çalışan izleyici ve son görülen UID korunur). Önce silmek, silme ile yeni
    // kayıt arasında gelen iletilerin "ilk kurulum" sayılıp atlanmasına yol
    // açardı. Taşınacak hesap yoksa eski kayıt yetim kalmasın diye silinir;
    // silinemezse de sorun değil, push sağlayıcısı 410/UNREGISTERED dönünce
    // sunucu kendisi temizler.
    final tokenChanged = syncedToken != null && syncedToken != token;
    if (tokenChanged) {
      if (accounts.isEmpty) {
        try {
          await _api.deleteDevice(syncedToken);
        } on Object catch (_) {}
      }
      fingerprints.clear();
      syncedToken = null;
      await persist();
    }

    var allSynced = true;
    final currentIds = {for (final a in accounts) a.id};

    // 1. Sunucu ile mutabakat: sunucudaki kayıtlı hesapları ve izleme
    // durumlarını sorgula. Sunucu yeniden başladıysa (ör. Railway
    // deploy/restart), veritabanı sıfırlandıysa veya sunucu adresi
    // değiştiyse yerel parmak izi önbelleği yanıltıcı olmasın.
    Map<int, ServerWatchStatus>? remote;
    try {
      remote = {
        for (final entry in await _api.listRegisteredAccounts(token))
          entry.clientAccountId: entry.status,
      };
    } on Object catch (e) {
      log?.call('sunucu hesap listesi sorgulanamadı: $e');
    }

    if (remote != null) {
      // Sunucuda artık OLMAYAN hesapları yerel parmak izi önbelleğinden düşür;
      // böylece aşağıdaki döngüde sunucuya gönderilmeleri tetiklensin.
      final known = remote;
      fingerprints.removeWhere((id, _) => !known.containsKey(id));

      // Sunucuda kalmış ama telefondan silinmiş yetim hesapları sunucudan sil:
      for (final remoteId in known.keys) {
        if (!currentIds.contains(remoteId)) {
          if (!await _deleteOrphan(token, remoteId, fingerprints)) {
            allSynced = false;
          }
        }
      }
    } else {
      for (final id in fingerprints.keys.toList()) {
        if (currentIds.contains(id)) continue;
        if (!await _deleteOrphan(token, id, fingerprints)) allSynced = false;
      }
    }

    final repaired = <int>{};
    final skipped = <int>{}; // şifresi olmayan: ne sunucu ne cihaz izleyebilir
    for (final account in accounts) {
      final fp = fingerprint(token, account);
      final status = remote?[account.id];
      final repairDue =
          status != null &&
          status.repairableByReupload &&
          _repairIsDue(account.id);
      if (fingerprints[account.id] == fp &&
          !force.contains(account.id) &&
          !repairDue) {
        continue;
      }
      final String? password;
      try {
        password = await _readPassword(account.id);
      } on Object catch (e) {
        // Keystore geçici olarak okunamadı: bu hesap atlanır, sonraki
        // mutabakatta yeniden denenir; hiçbir şey silinmez.
        _logFailure('hesap ${account.id}: şifre okunamadı', e);
        allSynced = false;
        continue;
      }
      if (password == null || password.isEmpty) {
        log?.call('hesap ${account.id}: kayıtlı şifre yok, atlandı');
        skipped.add(account.id);
        continue;
      }

      try {
        await _api.upsertAccount(
          RemotePushAccount(
            pushToken: token,
            environment: environment,
            clientAccountId: account.id,
            host: account.imapHost,
            port: account.imapPort,
            secure: account.imapSecurity == SocketSecurity.ssl,
            username: account.username,
            password: password,
          ),
        );
        fingerprints[account.id] = fp;
        syncedToken = token;
        if (repairDue) {
          _lastRepair[account.id] = _now();
          repaired.add(account.id);
          log?.call(
            'hesap ${account.id}: sunucu izleyemiyordu, yeniden kaydedildi',
          );
        } else {
          log?.call('hesap ${account.id}: sunucuya kaydedildi');
        }
      } on PushBackendException catch (e) {
        _logFailure('hesap ${account.id} kaydedilemedi', e);
        allSynced = false;
        // Sunucunun reddettiği tek bir hesap diğerlerini engellemesin; ama
        // yanlış anahtar / kesinti gibi genel sorunlarda boşuna yüklenme.
        if (!e.isRequestRejected) break;
      } on Object catch (e) {
        _logFailure('hesap ${account.id} kaydedilemedi', e);
        allSynced = false;
        break; // ağ yok / zaman aşımı: kalan hesaplar da aynı hatayı alır
      }
    }

    // Token değişiminde sunucu eski cihazın hesaplarını yenisine taşımış olabilir;
    // bu arada cihazdan silinmiş hesaplar yetim kalmasın.
    if (tokenChanged && allSynced) {
      try {
        for (final entry in await _api.listRegisteredAccounts(token)) {
          if (!currentIds.contains(entry.clientAccountId)) {
            await _deleteOrphan(token, entry.clientAccountId, fingerprints);
          }
        }
      } on Object catch (e) {
        _logFailure('taşınan yetim hesaplar temizlenemedi', e);
      }
    }

    // Durumu bozuk ama bu turda onarılmamış hesaplar: sunucu push'u onlar için
    // çalışmıyor. (Az önce onarılanların durumu henüz belirsiz; şifresi
    // olmayanları hiç kimse izleyemez.)
    final unhealthy = <int>{
      if (remote != null)
        for (final entry in remote.entries)
          if (currentIds.contains(entry.key) &&
              entry.value.isUnhealthy &&
              !repaired.contains(entry.key) &&
              !skipped.contains(entry.key))
            entry.key,
    };
    if (remote != null) unhealthyIds = unhealthy;
    await persist();
    return RemotePushSyncResult(
      ok: allSynced,
      unhealthyAccountIds: unhealthy,
      repairedAccountIds: repaired,
    );
  }

  bool _repairIsDue(int accountId) {
    final last = _lastRepair[accountId];
    return last == null || _now().difference(last) >= repairGap;
  }

  Future<bool> _deleteOrphan(
    String token,
    int clientAccountId,
    Map<int, String> fingerprints,
  ) async {
    try {
      await _api.deleteAccount(
        pushToken: token,
        clientAccountId: clientAccountId,
      );
      fingerprints.remove(clientAccountId);
      return true;
    } on Object catch (e) {
      _logFailure('sunucudaki yetim hesap silinemedi', e);
      return false;
    }
  }

  /// Hata türünü yazar; mesajı yazmaz (adres/kimlik bilgisi içerebilir).
  void _logFailure(String what, Object error) {
    if (error is PushBackendException) {
      final hint = switch (error.statusCode) {
        401 => ' (API anahtarı sunucuyla uyuşmuyor)',
        400 => ' (sunucu isteği geçersiz buldu)',
        _ => '',
      };
      log?.call('$what: sunucu HTTP ${error.statusCode} döndü$hint');
    } else {
      log?.call('$what: ${error.runtimeType} (sunucuya ulaşılamadı?)');
    }
  }
}

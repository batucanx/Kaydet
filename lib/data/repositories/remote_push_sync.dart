import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import '../services/push_backend_client.dart';

/// Sunucuya en son neyin kaydedildiği. Şifre ya da başka bir sır İÇERMEZ:
/// hesap başına yalnızca "bağlantı parmak izi" tutulur (bkz.
/// `RemotePushSync.fingerprint`).
class RegistrationSnapshot {
  const RegistrationSnapshot({this.token, this.fingerprints = const {}});

  /// Kayıtların yapıldığı APNs token'ı.
  final String? token;

  /// Hesap kimliği → o hesabın sunucuya kaydedilen parmak izi.
  final Map<int, String> fingerprints;
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
  }
}

/// Cihazdaki hesapları push sunucusuyla eşler.
///
/// Sunucu, IMAP IDLE ile posta kutusunu izleyip yeni iletide APNs push'u
/// gönderdiğinden hesabın IMAP bilgilerini (şifre dahil) bilmek zorundadır.
/// Bu sınıf yalnızca gerektiğinde konuşur: her çağrıda tüm hesapları
/// yeniden göndermek, sunucudaki IDLE bağlantısını boşuna sıfırlardı.
class RemotePushSync {
  RemotePushSync({
    required RemotePushApi api,
    required RegistrationStore store,
    required Future<String?> Function(int accountId) readPassword,
    required this.environment,
    this.log,
  }) : _api = api,
       _store = store,
       _readPassword = readPassword;

  final RemotePushApi _api;
  final RegistrationStore _store;
  final Future<String?> Function(int accountId) _readPassword;

  /// `development` (Xcode debug derlemesi) ya da `production`.
  final String environment;

  /// Teşhis günlüğü. Şifre, token ve adres YAZILMAZ; yalnızca ne olduğu.
  final void Function(String message)? log;

  /// Bir hesabın sunucuda yeniden kaydedilmesini gerektiren her şey. Şifre
  /// bilerek yok: değiştiğinde [sync]'e `force` verilir.
  String fingerprint(String token, AccountRow a) =>
      '${_api.baseUrl}|$token|$environment|${a.imapHost}|${a.imapPort}|'
      '${a.imapSecurity.index}|${a.username}';

  /// Sunucuyu istenen duruma getirir. Her şey eşitse `true` döner; ağ/sunucu
  /// hatasında `false` (çağıran daha sonra yeniden dener).
  ///
  /// - [enabled] kapalıysa cihazın tüm kayıtları (ve şifreler) sunucudan silinir.
  /// - [token] henüz yoksa hiçbir şey yapılmaz.
  /// - [force]: parmak izi aynı olsa da yeniden gönderilecek hesaplar
  ///   (ör. şifresi değişenler).
  Future<bool> sync({
    required String? token,
    required bool enabled,
    required List<AccountRow> accounts,
    Set<int> force = const {},
  }) async {
    final snapshot = _store.read();
    final fingerprints = {...snapshot.fingerprints};
    var syncedToken = snapshot.token;

    Future<void> persist() => _store.write(
      RegistrationSnapshot(token: syncedToken, fingerprints: fingerprints),
    );

    if (!enabled) {
      if (syncedToken == null && fingerprints.isEmpty) return true;
      try {
        if (syncedToken != null) await _api.deleteDevice(syncedToken);
      } on Object catch (e) {
        _logFailure('cihaz kaydı silinemedi', e);
        return false; // silinemedi; kayıt durumu korunur, tekrar denenir
      }
      fingerprints.clear();
      syncedToken = null;
      await persist();
      return true;
    }
    if (token == null) return true;

    // Token değişti (yeniden kurulum, yeni cihaz): eski kayıt sunucuda
    // yetim kalmasın. Silinemezse de sorun değil, APNs 410 dönünce sunucu
    // kendisi temizler.
    if (syncedToken != null && syncedToken != token) {
      try {
        await _api.deleteDevice(syncedToken);
      } on Object catch (_) {}
      fingerprints.clear();
      syncedToken = null;
      await persist();
    }

    var allSynced = true;
    final currentIds = {for (final a in accounts) a.id};

    // 1. Sunucu ile mutabakat: sunucudaki kayıtlı hesap kimliklerini sorgula.
    // Sunucu yeniden başladıysa (ör. Railway deploy/restart), veritabanı
    // sıfırlandıysa veya sunucu adresi değiştiyse yerel parmak izi önbelleği
    // yanıltıcı olmasın.
    List<int>? remoteAccountIds;
    try {
      remoteAccountIds = await _api.listRegisteredAccountIds(token);
    } on Object catch (e) {
      log?.call('sunucu hesap listesi sorgulanamadı: $e');
    }

    if (remoteAccountIds != null) {
      final remoteSet = remoteAccountIds.toSet();
      // Sunucuda artık OLMAYAN hesapları yerel parmak izi önbelleğinden düşür;
      // böylece aşağıdaki döngüde sunucuya gönderilmeleri tetiklensin.
      fingerprints.removeWhere((id, _) => !remoteSet.contains(id));

      // Sunucuda kalmış ama telefondan silinmiş yetim hesapları sunucudan sil:
      for (final remoteId in remoteAccountIds) {
        if (!currentIds.contains(remoteId)) {
          try {
            await _api.deleteAccount(apnsToken: token, clientAccountId: remoteId);
            fingerprints.remove(remoteId);
          } on Object catch (e) {
            _logFailure('sunucudaki yetim hesap silinemedi', e);
            allSynced = false;
          }
        }
      }
    } else {
      for (final id in fingerprints.keys.toList()) {
        if (currentIds.contains(id)) continue;
        try {
          await _api.deleteAccount(apnsToken: token, clientAccountId: id);
          fingerprints.remove(id);
        } on Object catch (e) {
          _logFailure('hesap silinemedi', e);
          allSynced = false;
        }
      }
    }

    for (final account in accounts) {
      final fp = fingerprint(token, account);
      if (fingerprints[account.id] == fp && !force.contains(account.id)) {
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
        continue;
      }

      try {
        await _api.upsertAccount(
          RemotePushAccount(
            apnsToken: token,
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
        log?.call('hesap ${account.id}: sunucuya kaydedildi');
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

    await persist();
    return allSynced;
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

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
  }) : _api = api,
       _store = store,
       _readPassword = readPassword;

  final RemotePushApi _api;
  final RegistrationStore _store;
  final Future<String?> Function(int accountId) _readPassword;

  /// `development` (Xcode debug derlemesi) ya da `production`.
  final String environment;

  /// Bir hesabın sunucuda yeniden kaydedilmesini gerektiren her şey. Şifre
  /// bilerek yok: değiştiğinde [sync]'e `force` verilir.
  String fingerprint(String token, AccountRow a) =>
      '$token|$environment|${a.imapHost}|${a.imapPort}|'
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
      } on Object catch (_) {
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

    for (final id in fingerprints.keys.toList()) {
      if (currentIds.contains(id)) continue;
      try {
        await _api.deleteAccount(apnsToken: token, clientAccountId: id);
        fingerprints.remove(id);
      } on Object catch (_) {
        allSynced = false;
      }
    }

    for (final account in accounts) {
      final fp = fingerprint(token, account);
      if (fingerprints[account.id] == fp && !force.contains(account.id)) {
        continue;
      }
      final password = await _readPassword(account.id);
      if (password == null || password.isEmpty) continue;

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
      } on PushBackendException catch (e) {
        allSynced = false;
        // Sunucunun reddettiği tek bir hesap diğerlerini engellemesin; ama
        // yanlış anahtar / kesinti gibi genel sorunlarda boşuna yüklenme.
        if (!e.isRequestRejected) break;
      } on Object catch (_) {
        allSynced = false;
        break; // ağ yok / zaman aşımı: kalan hesaplar da aynı hatayı alır
      }
    }

    await persist();
    return allSynced;
  }
}

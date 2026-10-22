import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_lock.dart';
import 'secure_store.dart';

/// Bu uygulama kurulumuna özel kimlik: `id` kamuya açık bir takma ad,
/// `secret` yalnızca sunucuya gönderilen gizli anahtardır.
class InstallCredentials {
  const InstallCredentials({required this.id, required this.secret});

  final String id;
  final String secret;
}

abstract interface class InstallCredentialsSource {
  Future<InstallCredentials> load();
}

/// Kimliği ilk kullanımda üretip güvenli depoda (Keychain / Keystore) tutar.
///
/// Okuma hata fırlatırsa (ör. yeniden başlatma sonrası Keystore hazır değil)
/// YENİ kimlik üretilip üzerine yazılmaz: hata yukarı çıkar, bir sonraki
/// denemede yeniden okunur. Aksi hâlde geçici bir hata, sunucuda kayıtlı
/// kimliği kalıcı olarak yitirtirdi. Başarısız yükleme önbelleğe alınmaz.
class SecureInstallCredentials implements InstallCredentialsSource {
  SecureInstallCredentials(this._storage, {Random? random})
    : _random = random ?? Random.secure();

  static const idKey = 'kaydet_install_id';
  static const secretKey = 'kaydet_install_secret';

  final FlutterSecureStorage _storage;
  final Random _random;
  Future<InstallCredentials>? _pending;

  @override
  Future<InstallCredentials> load() async {
    final inFlight = _pending ??= _loadOrCreate();
    try {
      return await inFlight;
    } catch (_) {
      // Başarısız yükleme önbelleğe alınmaz: bir sonraki çağrı yeniden dener.
      if (identical(_pending, inFlight)) _pending = null;
      rethrow;
    }
  }

  // Okuma-yoksa-üret adımı izolatlar arası kilitli: ana uygulama ve arka plan
  // aynı anda ilk kez açıldığında iki ayrı kimlik üretilip biri ezilmesin.
  Future<InstallCredentials> _loadOrCreate() async {
    await ensureSecureStorageReady();
    return SecureStorageLock.run(() async {
      final id = await _storage.read(key: idKey);
      final secret = await _storage.read(key: secretKey);
      if (id != null &&
          id.length >= 32 &&
          secret != null &&
          secret.length >= 32) {
        return InstallCredentials(id: id, secret: secret);
      }
      final created = InstallCredentials(id: _hex(32), secret: _hex(64));
      await _storage.write(key: idKey, value: created.id);
      await _storage.write(key: secretKey, value: created.secret);
      return created;
    });
  }

  String _hex(int length) => List.generate(
    length,
    (_) => _random.nextInt(16).toRadixString(16),
  ).join();
}

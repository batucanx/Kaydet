import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

/// Güvenli depoya (Android Keystore) erişimi izolatlar arasında sıraya sokar.
///
/// Uygulama aynı anda birden çok izolatta çalışır: ana arayüz, ön plan bildirim
/// servisi ve WorkManager arka plan görevi. Her birinin kendi eklenti nesnesi
/// vardır ve ilk erişimde Keystore anahtarını üretip sarar; ikisi aynı anda
/// üretirse sarılı anahtar bozulur (`Key mismatch`, `Failed to unwrap key`,
/// Keystore `-1000`) ve şifreler okunamaz. Uygulamayı görev listesinden
/// kapatıp açmak servisleri yeniden başlatıp bu yarışı tetikler.
///
/// `dart:io` dosya kilidi (`RandomAccessFile.lock`) burada işe yaramaz: POSIX
/// kilitleri süreç başınadır ve aynı sürecin izolatlarını birbirinden ayırmaz.
/// Bu yüzden atomik `create(exclusive: true)` ile bir kilit dosyası kullanılır.
abstract final class SecureStorageLock {
  /// Aynı izolat içindeki iç içe çağrılar kendi kendini kilitlemesin.
  static final Lock _local = Lock(reentrant: true);
  static int _depth = 0;

  /// Kilit dosyası bundan eskiyse sahibi öldü sayılır (süreç kilidi tutarken
  /// öldürüldü).
  static const Duration _stale = Duration(seconds: 10);

  /// Kilit bu süre içinde alınamazsa kilitsiz devam edilir: bir hata yüzünden
  /// uygulamanın şifre okuyamaması, nadir bir yarıştan daha kötüdür.
  static const Duration _maxWait = Duration(seconds: 15);

  static const Duration _poll = Duration(milliseconds: 40);

  static Future<File?>? _fileFuture;

  /// Testler için: kilit dosyasını [dir] altında tutar (path_provider yok).
  static void useDirectoryForTesting(Directory? dir) {
    _fileFuture = dir == null
        ? null
        : Future.value(File(p.join(dir.path, 'secure_storage.lock')));
  }

  static Future<File?> _lockFile() => _fileFuture ??= () async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File(p.join(dir.path, 'secure_storage.lock'));
    } on Object catch (_) {
      return null;
    }
  }();

  /// [action]'ı, diğer izolatlardaki erişimler bitene kadar bekleyip çalıştırır.
  static Future<T> run<T>(Future<T> Function() action) =>
      _local.synchronized(() async {
        if (_depth > 0) return action();
        final file = await _lockFile();
        final held = file != null && await _acquire(file);
        _depth++;
        try {
          return await action();
        } finally {
          _depth--;
          if (held) await _release(file);
        }
      });

  static Future<bool> _acquire(File file) async {
    final deadline = DateTime.now().add(_maxWait);
    while (DateTime.now().isBefore(deadline)) {
      try {
        await file.create(exclusive: true);
        return true;
      } on FileSystemException {
        // Kilit başkasında: sahibi öldüyse dosyayı sil, değilse bekle.
        try {
          final age = DateTime.now().difference(await file.lastModified());
          if (age > _stale) await file.delete();
        } on Object catch (_) {}
        await Future<void>.delayed(_poll);
      } on Object catch (_) {
        return false;
      }
    }
    return false;
  }

  static Future<void> _release(File file) async {
    try {
      await file.delete();
    } on Object catch (_) {}
  }
}

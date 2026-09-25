import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/share_payload.dart';
import '../../domain/use_cases/share_attachment_policy.dart';

/// Sistem "Paylaş" menüsünden gelen dosyaların native katmandan alınması.
///
/// **Neden "çekme" (pull) modeli?** Native taraf, paylaşımı Flutter'a
/// `invokeMethod` ile İTERSE ve o an Dart tarafında dinleyici yoksa (soğuk
/// başlangıç, motor henüz hazır değil) olay kaybolur. Bunun yerine native
/// dosyaları diske yazar ve yanına `manifest.json` koyar; Dart hazır olunca
/// [takePending] ile OKUR. Native tarafın tek "itmesi" içeriksiz bir
/// dürtmedir (`onShareReceived` → [changes]); kaçırılması hiçbir şeyi
/// kaybettirmez, çünkü veri diskte bekler.
///
/// Native taraf (Android: `ShareChannel.kt`, iOS: `ShareChannel.swift`)
/// hâlâ TÜKETİLMEMİŞ paylaşımın diskteki manifestini tutar; [acknowledge]
/// manifesti siler (tüketildi işareti, kalıcıdır) — dosyalar ise artık
/// taslağın eki olduğu için yerinde kalır. Bkz. [sweep].
///
/// Kanal sözleşmesi:
/// - `takePendingShares` → `{root: String, payloads: List<String>}` (her biri
///   manifest JSON'u); durumsuzdur, aynı paylaşımı tüketilene kadar döndürür.
/// - `acknowledgeShare(id)` → manifesti siler.
/// - `discardShare(id)` → dizini (dosyalar dahil) siler.
/// - `inboxRoot` → `share_inbox` dizininin mutlak yolu.
/// - native → Dart: `onShareReceived` (bağımsız değişken yok).
class ShareIntakeService {
  ShareIntakeService({MethodChannel? channel, DateTime Function()? clock})
    : _channel = channel ?? const MethodChannel(channelName),
      _clock = clock ?? DateTime.now;

  static const String channelName = 'tr.com.pazarlik.kaydet/share';

  /// iOS Share Extension'ın ana uygulamayı uyandırmak için açtığı URL şeması
  /// (`kaydetshare://open`). URL veri TAŞIMAZ; dosyalar App Group'tadır.
  /// `ShareInbox.swift`teki `urlScheme` ve `Info.plist`teki
  /// `CFBundleURLSchemes` ile AYNI olmalı.
  static const String iosUrlScheme = 'kaydetshare';

  /// Bu süreden eski, hâlâ tüketilmemiş paylaşım teslim EDİLMEZ (silinir):
  /// kullanıcı günler önce paylaştığı bir şey yüzünden birden yazma ekranı
  /// görmemeli. iOS'ta uygulama açılamazsa paylaşım App Group'ta bekler (bkz.
  /// `ShareViewController`); aynı gün içinde açılırsa yine teslim edilir.
  static const Duration maxPendingAge = Duration(hours: 24);

  /// Tüketilmiş ama artık hiçbir taslağın eki olmayan dosyalar bu süreden
  /// sonra silinir. Süre, açık ama henüz kaydedilmemiş bir yazma ekranının
  /// dosyasının süpürülmesini imkânsız kılacak kadar geniştir.
  static const Duration orphanGrace = Duration(hours: 24);

  final MethodChannel _channel;
  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _listening = false;

  /// Native taraf yeni bir paylaşımın hazır olduğunu bildirdiğinde tetiklenir.
  Stream<void> get changes => _changes.stream;

  /// Native dürtmeleri dinlemeye başlar. [takePending]'den ÖNCE çağrılmalı:
  /// sıra "dinleyiciyi kur → sonra çek" olursa, çekme ile dürtme arasında
  /// hiçbir paylaşım gözden kaçmaz.
  void listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShareReceived') _changes.add(null);
      return null;
    });
  }

  void dispose() {
    if (_listening) _channel.setMethodCallHandler(null);
    _listening = false;
    _changes.close();
  }

  /// Tüketilmemiş paylaşımlar, en eskiden yeniye. Hiçbir koşulda fırlatmaz:
  /// native taraf yoksa (test/masaüstü) ya da hata verirse boş liste döner.
  ///
  /// Durumsuzdur — çağırmak paylaşımı tüketmez. Tüketmek için [acknowledge].
  Future<List<SharePayload>> takePending() async {
    final Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>('takePendingShares');
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (error) {
      debugPrint('Paylaşımlar okunamadı: ${error.code} ${error.message}');
      return const [];
    }
    if (reply is! Map) return const [];

    final root = reply['root'];
    final raw = reply['payloads'];
    if (root is! String || raw is! List) return const [];

    final now = _clock();
    final payloads = <SharePayload>[];
    for (final manifest in raw.whereType<String>()) {
      final payload = SharePayload.tryParse(manifest, root: root);
      if (payload == null) continue;
      if (now.difference(payload.receivedAt) > maxPendingAge) {
        await discard(payload.id);
        continue;
      }
      payloads.add(payload);
    }
    payloads.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    return payloads;
  }

  /// Paylaşımı TÜKETİLDİ işaretler (native manifesti siler). Dosyalar kalır —
  /// artık yazma ekranının/taslağın eki.
  Future<void> acknowledge(String id) => _invokeQuietly('acknowledgeShare', id);

  /// Paylaşımı dosyalarıyla birlikte siler (kullanılacak hiçbir şey kalmadı).
  Future<void> discard(String id) => _invokeQuietly('discardShare', id);

  Future<void> _invokeQuietly(String method, String id) async {
    try {
      await _channel.invokeMethod<void>(method, {'id': id});
    } on MissingPluginException {
      // Native taraf yok (test/masaüstü).
    } on PlatformException catch (error) {
      debugPrint('$method başarısız: ${error.code} ${error.message}');
    }
  }

  /// Diskteki dosyaları [ShareAttachmentPolicy]'ye göre doğrular.
  ///
  /// Native taraf boyutu/adı zaten denetler; ama manifest güvenilmeyen girdi
  /// sayılır: dosya gerçekten var mı, düz bir dosya mı (bağlantı değil), boyutu
  /// bildirilenle uyuşuyor mu, izinli tür mü, toplam sınır aşılıyor mu — burada
  /// yeniden bakılır. Reddedilen dosya diskten silinir ve nedeni `issues`e
  /// eklenir; kabul edilenler gerçek boyutlarıyla döner. Sıra korunur.
  ///
  /// Yalnızca meta veri (tür/boyut) okunur, içerik değil; en çok birkaç
  /// yerel dosya olduğu için eşzamanlı çağrılar arayüzü fark edilir biçimde
  /// bekletmez.
  Future<SharePayload> prepare(SharePayload payload) async {
    final accepted = <SharedFile>[];
    final issues = [...payload.issues];
    var total = 0;

    for (final file in payload.files) {
      final (rejection, size) = _inspect(file, totalSoFar: total);
      if (rejection == null) {
        total += size;
        accepted.add(
          SharedFile(
            fileName: file.fileName,
            mimeType: file.mimeType,
            path: file.path,
            sizeBytes: size,
          ),
        );
        continue;
      }
      issues.add(ShareIssue(code: rejection, fileName: file.fileName));
      try {
        File(file.path).deleteSync();
      } on FileSystemException {
        // Zaten yok/erişilemiyor — süpürücü yine de toplar.
      }
    }
    return payload.copyWith(files: accepted, issues: issues);
  }

  /// Dosyanın diskteki gerçek durumu: (ret nedeni ya da `null`, gerçek boyut).
  (ShareIssueCode?, int) _inspect(SharedFile file, {required int totalSoFar}) {
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return (ShareIssueCode.unreadable, 0);
      }
      final size = File(file.path).lengthSync();
      final rejection =
          ShareAttachmentPolicy.rejectionFor(
            fileName: file.fileName,
            sizeBytes: size,
          ) ??
          (totalSoFar + size > ShareAttachmentPolicy.maxTotalBytes
              ? ShareIssueCode.tooLarge
              : null);
      return (rejection, size);
    } on FileSystemException {
      return (ShareIssueCode.unreadable, 0);
    }
  }

  /// Dizinin en son ne zaman yazıldığı: içindeki dosyaların (manifest dahil)
  /// en yeni değişiklik zamanı — yani kopyalamanın bittiği an. Dizinin kendi
  /// zaman damgası kullanılmaz: dosya silinip eklendikçe değişir ve platforma
  /// göre tutarsızdır. İçi boşsa dizinin kendi zamanına düşülür.
  Future<DateTime> _lastActivity(Directory directory) async {
    DateTime? newest;
    await for (final entity in directory.list(followLinks: false)) {
      final modified = (await entity.stat()).modified;
      if (newest == null || modified.isAfter(newest)) newest = modified;
    }
    return newest ?? (await directory.stat()).modified;
  }

  /// Artık kullanılmayan paylaşım dizinlerini siler.
  ///
  /// [referencedPaths], hâlâ bir taslak/kuyruktaki iletinin eki olan dosya
  /// yollarıdır (bkz. `AppDatabase.outgoingAttachmentPaths`); bunlara
  /// dokunulmaz — kullanıcı bir taslağı haftalarca bekletebilir. Tüketilmemiş
  /// paylaşımlar [maxPendingAge]'den sonra, tüketilmişler ve manifestsiz
  /// (yarım kalmış kopya) dizinler ise hiçbir yerde kullanılmıyorsa
  /// [orphanGrace]'ten sonra silinir; süre, dosyaların kopyalandığı andan
  /// sayılır. Silinen dizin sayısını döndürür.
  Future<int> sweep({required Set<String> referencedPaths}) async {
    final String? root;
    try {
      root = await _channel.invokeMethod<String>('inboxRoot');
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
    if (root == null) return 0;

    final directory = Directory(root);
    if (!directory.existsSync()) return 0;

    // Yollar platforma göre `\` ya da `/` taşıyabilir; kimlik (UUID) zaten
    // benzersiz olduğu için `<gelen kutusu dizin adı>/<id>/` parçasıyla
    // karşılaştırılır.
    final rootName = p.basename(root);
    final references = [
      for (final path in referencedPaths) path.replaceAll(r'\', '/'),
    ];

    final now = _clock();
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = p.basename(entity.path);
      if (!SharePayload.isValidId(id)) continue;

      try {
        final age = now.difference(await _lastActivity(entity));
        final pending = File(p.join(entity.path, 'manifest.json')).existsSync();
        final inUse = references.any((r) => r.contains('$rootName/$id/'));

        final expired = pending
            ? age > maxPendingAge
            : age > orphanGrace && !inUse;
        if (!expired) continue;

        await entity.delete(recursive: true);
        removed++;
      } on FileSystemException catch (error) {
        debugPrint('Paylaşım dizini temizlenemedi: $error');
      }
    }
    return removed;
  }
}

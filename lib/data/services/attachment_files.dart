import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// İndirilen ek dosyalarının yaşam döngüsü.
///
/// Ekler `<uygulama>/ekler/<ileti>/<ek>/<dosya adı>` altına indirilir (eski
/// sürümlerde `<uygulama>/ekler/<ileti>/<dosya adı>`). İleti silindiğinde,
/// klasör ya da hesap kaldırıldığında bu dosyalar da silinmelidir: veritabanı
/// satırı silinince dosya sahipsiz kalır, hem depolamayı doldurur hem de
/// "silinmiş" bir iletinin (ya da çıkış yapılmış bir hesabın) belgeleri
/// cihazda okunabilir durumda kalırdı.
abstract final class AttachmentFiles {
  static const String directoryName = 'ekler';

  /// Gelen verinin ham Base64 ASCII metin olup olmadığını kontrol eder.
  /// `enough_mail` bazı durumlarda MIME aktarım kodlaması başlığı eksikken
  /// Base64 metnini ikili veri yerine ham ASCII dizisi olarak dönebilir.
  /// Bu metodu çalıştırarak ikili dosyanın (PNG, JPG, PDF vb.) bozulmadan
  /// çözüldüğünden emin olunur.
  static Uint8List ensureBinaryDecoded(Uint8List rawData) {
    if (rawData.isEmpty) return rawData;

    for (var i = 0; i < rawData.length; i++) {
      if (rawData[i] > 127) {
        return rawData;
      }
    }

    try {
      final str = ascii.decode(rawData).replaceAll(RegExp(r'\s+'), '');
      if (str.length >= 4 && str.length % 4 == 0) {
        final base64Regex = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
        if (base64Regex.hasMatch(str)) {
          final decoded = base64.decode(str);
          if (decoded.isNotEmpty) {
            return decoded;
          }
        }
      }
    } catch (_) {
      // Çözümleme başarısız olursa ham veriyi koru.
    }

    return rawData;
  }

  /// Ek adını tek bir güvenli yol bileşenine çevirir: yol ayırıcılar ve
  /// kontrol karakterleri `_` olur, yalnızca noktalardan/boşluklardan oluşan
  /// adlar (`.`, `..`) ve boş adlar `dosya`ya döner, uzunluk sınırlanır
  /// (uzantı korunur).
  static String safeFileName(String name) {
    var value = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    // Sondaki nokta/boşluk bazı dosya sistemlerinde geçersizdir; `..` gibi
    // adlar da dizin yolu olarak çözülürdü.
    value = value.replaceAll(RegExp(r'[. ]+$'), '');
    if (value.isEmpty) return 'dosya';

    const maxRunes = 150;
    final runes = value.runes.toList();
    if (runes.length <= maxRunes) return value;
    final extension = p.extension(value);
    final keep = extension.runes.length <= 20 ? extension : '';
    final head = runes.sublist(0, maxRunes - keep.runes.length);
    return '${String.fromCharCodes(head)}$keep';
  }

  /// [path] uygulamanın indirilen ek dizininin (`ekler`) ALTINDA mı?
  ///
  /// Silme yalnızca bu yollara uygulanır: veritabanındaki bir yol (ör. yazma
  /// ekranından eklenen kullanıcı dosyası) hiçbir koşulda buradan silinmez.
  static bool isManaged(String path) {
    final segments = p.split(p.normalize(path));
    final index = segments.lastIndexOf(directoryName);
    return index != -1 && index < segments.length - 1;
  }

  /// [paths] içindeki yönetilen dosyaları siler ve boşalan ara klasörleri
  /// (`ekler` dizininin kendisine dokunmadan) temizler. Hiçbir hata fırlatmaz:
  /// silinemeyen dosya bir sonraki temizlikte yeniden denenir.
  static Future<void> deleteAll(Iterable<String> paths) async {
    for (final path in paths.toSet()) {
      if (!isManaged(path)) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
        await _pruneEmptyParents(file.parent);
      } on FileSystemException {
        // Dosya kilitli/erişilemiyor; sonraki temizlikte yeniden denenir.
      }
    }
  }

  static Future<void> _pruneEmptyParents(Directory directory) async {
    var current = directory;
    while (p.basename(current.path) != directoryName) {
      try {
        // Zaten silinmiş bir klasör atlanır ama üstü yine denetlenir.
        if (await current.exists()) {
          if (!await current.list().isEmpty) return;
          await current.delete();
        }
      } on FileSystemException {
        return;
      }
      final parent = current.parent;
      if (parent.path == current.path) return;
      current = parent;
    }
  }
}

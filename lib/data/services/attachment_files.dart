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

  static final RegExp _digitsOnlyRegex = RegExp(r'^\d{8,18}$');
  static final RegExp _nestedPrefixRegex = RegExp(
    r'^(kaydet_pick_\d+_|kaydet_resized_\d+_)+',
    caseSensitive: false,
  );

  static const Set<String> _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.heif', '.bmp', '.tiff',
  };
  static const Set<String> _videoExtensions = {
    '.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v', '.3gp',
  };
  static const Set<String> _audioExtensions = {
    '.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac', '.wma',
  };

  /// Seçicilerden (galeri, kamera, dosya yöneticisi) ya da geçici dizinden gelen
  /// dosya adını temizler; işletim sisteminin veya eklentilerin ürettiği
  /// geçici/karmaşık isimleri (`image_picker_8ACDFDA1-...`, `scaled_...`,
  /// `kaydet_pick_...`) ayıklar ve orijinal adı korur.
  ///
  /// Orijinal ad bulunamazsa veya ad tamamen bir UUID/geçici isimden ibaretse,
  /// dosyanın değiştirilme zamanına göre standart ve temiz bir isim (ör.
  /// `IMG_20260928_145023.jpg`) üretir. Uzantı her zaman korunur.
  static String cleanPickedName(String rawName, {String? sourcePath}) {
    var name = rawName.trim();

    // 1. URL encoded karakterleri çöz (%20 -> boşluk, %C3%B6 -> ö vb.)
    if (name.contains('%')) {
      try {
        name = Uri.decodeComponent(name);
      } catch (_) {}
    }

    // 2. Yol ayırıcılar varsa yalnızca dosya adı bileşenini al
    name = name.split(RegExp(r'[\\/]')).last.trim();

    // 3. Bizim eklediğimiz geçici ön ekleri temizle (kaydet_pick_..., kaydet_resized_...)
    name = name.replaceAll(_nestedPrefixRegex, '');

    // 4. Android ImageResizer "scaled_" ön ekini temizle
    if (name.toLowerCase().startsWith('scaled_')) {
      name = name.substring('scaled_'.length);
    }

    // 5. Uzantıyı belirle ve koru
    var ext = p.extension(name);
    var base = p.basenameWithoutExtension(name);

    if (ext.isEmpty && sourcePath != null) {
      ext = p.extension(sourcePath);
      if (ext.isEmpty) {
        ext = _detectExtensionFromMagicBytes(sourcePath) ?? '';
      }
    }

    // 6. Generated / temporary isim kontrolü:
    // - Yalnızca eklentilerin ürettiği geçici isimler (image_picker_...)
    // - Dosya adı boş olanlar (.jpg gibi)
    // - Uzantısız ham MediaStore ID'leri (1000000033 gibi)
    // Kullanıcının dosya yöneticisinden veya galeriden seçtiği gerçek dosya
    // adları (rakamlar, UUID veya özel isimler) ASLA değiştirilmez; sistemden
    // nasıl geliyorsa öyle korunur.
    final isImagePicker = base.toLowerCase().startsWith('image_picker');
    final isDigitsOnly = _digitsOnlyRegex.hasMatch(base);
    final isNamelessMediaId = ext.isEmpty && isDigitsOnly;

    if (isImagePicker || isNamelessMediaId || base.isEmpty) {
      final dt = _timestampForSource(sourcePath);
      final ts = _formatTimestamp(dt);
      final prefix = _prefixForExtension(ext);
      final finalExt = ext.isNotEmpty ? ext : '.jpg';
      return '$prefix$ts$finalExt';
    }

    // Eğer uzantı yoksa ve kaynak yoldan tespit edildiyse ekle
    if (p.extension(name).isEmpty && ext.isNotEmpty) {
      name = '$name$ext';
    }

    return name;
  }

  static String _prefixForExtension(String ext) {
    final lower = ext.toLowerCase();
    if (_imageExtensions.contains(lower)) return 'IMG_';
    if (_videoExtensions.contains(lower)) return 'VID_';
    if (_audioExtensions.contains(lower)) return 'AUDIO_';
    return 'Belge_';
  }

  static DateTime _timestampForSource(String? sourcePath) {
    if (sourcePath != null) {
      try {
        final file = File(sourcePath);
        if (file.existsSync()) {
          return file.lastModifiedSync();
        }
      } catch (_) {}
    }
    return DateTime.now();
  }

  static String _formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y$m${d}_$h$min$s';
  }

  static String? _detectExtensionFromMagicBytes(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raf = file.openSync(mode: FileMode.read);
      try {
        final bytes = raf.readSync(16);
        if (bytes.length >= 3 &&
            bytes[0] == 0xFF &&
            bytes[1] == 0xD8 &&
            bytes[2] == 0xFF) {
          return '.jpg';
        }
        if (bytes.length >= 8 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47 &&
            bytes[4] == 0x0D &&
            bytes[5] == 0x0A &&
            bytes[6] == 0x1A &&
            bytes[7] == 0x0A) {
          return '.png';
        }
        if (bytes.length >= 4 &&
            bytes[0] == 0x25 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x44 &&
            bytes[3] == 0x46) {
          return '.pdf';
        }
        if (bytes.length >= 3 &&
            bytes[0] == 0x47 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46) {
          return '.gif';
        }
        if (bytes.length >= 12 &&
            bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45 &&
            bytes[10] == 0x42 &&
            bytes[11] == 0x50) {
          return '.webp';
        }
        if (bytes.length >= 4 &&
            bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04) {
          return '.zip';
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    return null;
  }
}


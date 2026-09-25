import 'package:path/path.dart' as p;

import '../models/share_payload.dart';

/// Paylaşım yoluyla gelen dosyaların e-postaya eklenip eklenemeyeceği kuralı.
///
/// Mevcut ek seçicilerin (galeri/kamera/dosya) bir sınırı yok; ama paylaşım,
/// üçüncü taraf uygulamadan gelen GÜVENİLMEYEN girdidir ve `SmtpService` eki
/// tümüyle belleğe okuyup base64'e çevirir (bkz. `EnoughMailSmtpService`) —
/// sınırsız dosya telefonda bellek yetersizliğine yol açar.
///
/// Boyut sabitleri native taraftaki kopyalama sınırıyla AYNI olmalı:
/// `ShareInbox.kt` (`MAX_FILE_BYTES`, `MAX_TOTAL_BYTES`) ve
/// `ShareInbox.swift` (`maxFileBytes`, `maxTotalBytes`). Native sınır diski
/// doldurmayı önler, buradaki ikinci savunma hattı ise manifestin sınırı
/// aşan bir dosya bildirdiği durumu yakalar.
abstract final class ShareAttachmentPolicy {
  /// Tek dosya için üst sınır — çoğu sunucu 25 MB'ta durur (base64 şişmesi
  /// dahil ~33 MB); daha büyüğü gönderimde reddedilir.
  static const int maxFileBytes = 25 * 1024 * 1024;

  /// Tek paylaşımdaki tüm dosyaların toplamı.
  static const int maxTotalBytes = 50 * 1024 * 1024;

  /// Posta sağlayıcılarının (Gmail, Outlook…) ortak olarak reddettiği,
  /// yürütülebilir/kurulum türleri. Ad sonuna bakılır; çift uzantı
  /// (`fatura.pdf.exe`) yine son uzantıya göre yakalanır.
  static const Set<String> blockedExtensions = {
    '.ade', '.adp', '.apk', '.appx', '.appxbundle', '.bat', '.cab', '.chm', //
    '.cmd', '.com', '.cpl', '.dll', '.dmg', '.exe', '.hta', '.ins', '.iso',
    '.isp', '.jar', '.jse', '.lib', '.lnk', '.mde', '.msc', '.msi', '.msix',
    '.msixbundle', '.msp', '.mst', '.pif', '.ps1', '.scr', '.sct', '.shb',
    '.sys', '.vb', '.vbe', '.vbs', '.vxd', '.wsc', '.wsf', '.wsh',
  };

  /// Tek dosya için ret nedeni; eklenebiliyorsa `null`.
  static ShareIssueCode? rejectionFor({
    required String fileName,
    required int sizeBytes,
  }) {
    if (blockedExtensions.contains(p.extension(fileName).toLowerCase())) {
      return ShareIssueCode.blockedType;
    }
    if (sizeBytes <= 0) return ShareIssueCode.empty;
    if (sizeBytes > maxFileBytes) return ShareIssueCode.tooLarge;
    return null;
  }

  /// Kullanıcıya gösterilecek TEK cümle; birden çok dosya reddedildiyse
  /// özetler. Reddedilen yoksa `null`.
  static String? describe(List<ShareIssue> issues) {
    if (issues.isEmpty) return null;
    if (issues.length == 1) {
      final issue = issues.single;
      final name = issue.fileName == null ? 'Dosya' : '“${issue.fileName}”';
      return switch (issue.code) {
        ShareIssueCode.tooLarge =>
          '$name çok büyük (en fazla ${maxFileBytes >> 20} MB) ve eklenmedi.',
        ShareIssueCode.blockedType =>
          '$name güvenlik nedeniyle e-postaya eklenemez.',
        ShareIssueCode.empty => '$name boş olduğu için eklenmedi.',
        ShareIssueCode.storage =>
          '$name cihaza kaydedilemediği için eklenmedi.',
        ShareIssueCode.unreadable ||
        ShareIssueCode.unknown => '$name okunamadığı için eklenmedi.',
      };
    }
    return '${issues.length} dosya eklenemedi (çok büyük, desteklenmeyen ya da '
        'okunamayan dosyalar).';
  }
}

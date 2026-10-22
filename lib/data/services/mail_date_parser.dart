import 'package:enough_mail/enough_mail.dart' as em;

/// `Date` başlığı ve IMAP `INTERNALDATE` değerleri için toleranslı ayrıştırıcı.
///
/// `enough_mail`'in [em.DateCodec.decodeDate] yalnızca katı RFC 5322 biçimini
/// (`Wed, 21 Oct 2026 13:18:00 +0300`) doğru okur:
///  - `+03:00` (iki noktalı dilim) tanınmaz ve sessizce UTC sayılır — ileti
///    3 saat kayık görünür;
///  - ISO 8601 (`2026-10-21T13:18:00+03:00`) `null` döner.
/// `null` dönen tarih eskiden eşitleme anına düşüyordu; bu yüzden hatalı
/// başlıklı iletiler listede "şimdi geldi" gibi en üstte görünüyordu.
///
/// Sonuç her zaman UTC'dir; ayrıştırılamazsa `null` döner.
DateTime? parseMailDate(String? raw) {
  if (raw == null) return null;
  var text = raw.trim();
  if (text.isEmpty) return null;

  // `(TRT)` gibi açıklama parantezleri.
  text = text.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
  // `GMT+0300` / `UTC+03:00` → `+0300`.
  text = text.replaceFirstMapped(
    RegExp(r'\s(?:GMT|UTC|UT)\s*([+-]\d{2}):?(\d{2})\s*$', caseSensitive: false),
    (m) => ' ${m[1]}${m[2]}',
  );
  // `+03:00` → `+0300`.
  text = text.replaceFirstMapped(
    RegExp(r'\s([+-]\d{2}):(\d{2})\s*$'),
    (m) => ' ${m[1]}${m[2]}',
  );

  final iso = RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}').hasMatch(text)
      ? DateTime.tryParse(text)
      : null;
  if (iso != null) return iso.toUtc();

  try {
    return em.DateCodec.decodeDate(text)?.toUtc();
  } catch (_) {
    return null;
  }
}

/// IMAP `INTERNALDATE` (`21-Oct-2026 13:18:00 +0300`) değerini ayrıştırır.
///
/// Sunucunun iletiyi aldığı an; `Date` başlığı eksik/bozuk iletilerde
/// geliş zamanına en yakın, kararlı değerdir (webmail'ler de buna düşer).
DateTime? parseInternalDate(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  return parseMailDate(text.replaceFirst('-', ' ').replaceFirst('-', ' '));
}

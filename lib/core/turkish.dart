/// Türkçe metin işlemleri.
///
/// Dart'ın `toLowerCase()` / `toUpperCase()` metotları locale duyarsızdır:
/// `'İSTANBUL'.toLowerCase()` → `'i̇stanbul'` (birleşik nokta kalır),
/// `'ısı'.toUpperCase()` → `'ISI'` yerine hatalı sonuç verir.
/// Bu yüzden Türkçe metin her yerde buradaki yardımcılardan geçer.
library;

/// Türkçe küçük harfe çevirir (I→ı, İ→i).
String trLower(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    switch (rune) {
      case 0x0049: // I
        buffer.writeCharCode(0x0131); // ı
      case 0x0130: // İ
        buffer.writeCharCode(0x0069); // i
      default:
        buffer.write(String.fromCharCode(rune).toLowerCase());
    }
  }
  return buffer.toString();
}

/// Türkçe büyük harfe çevirir (i→İ, ı→I).
String trUpper(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    switch (rune) {
      case 0x0069: // i
        buffer.writeCharCode(0x0130); // İ
      case 0x0131: // ı
        buffer.writeCharCode(0x0049); // I
      default:
        buffer.write(String.fromCharCode(rune).toUpperCase());
    }
  }
  return buffer.toString();
}

const Map<int, String> _foldMap = {
  0x00E7: 'c', // ç
  0x00C7: 'c', // Ç
  0x011F: 'g', // ğ
  0x011E: 'g', // Ğ
  0x0131: 'i', // ı
  0x0130: 'i', // İ
  0x00F6: 'o', // ö
  0x00D6: 'o', // Ö
  0x015F: 's', // ş
  0x015E: 's', // Ş
  0x00FC: 'u', // ü
  0x00DC: 'u', // Ü
  0x00E2: 'a', // â
  0x00C2: 'a', // Â
  0x00EE: 'i', // î
  0x00CE: 'i', // Î
  0x00FB: 'u', // û
  0x00DB: 'u', // Û
};

/// Arama için metni normalleştirir: Türkçe küçük harf + aksan katlama.
///
/// Böylece "sahan" araması "Şahan"ı, "gorusme" araması "Görüşme"yi bulur.
/// Bu fonksiyonun çıktısı FTS5 indeksine yazılan ve sorguda kullanılan
/// biçimdir — iki taraf da aynı fonksiyondan geçmek zorundadır.
String foldForSearch(String input) {
  final buffer = StringBuffer();
  for (final rune in trLower(input).runes) {
    final folded = _foldMap[rune];
    if (folded != null) {
      buffer.write(folded);
    } else {
      buffer.write(String.fromCharCode(rune));
    }
  }
  return buffer.toString();
}

/// Yanıt/iletme ön ekleri (katlanmış biçimde).
const Set<String> _replyPrefixes = {
  're',
  'fw',
  'fwd',
  'yan',
  'ynt',
  'ilt',
  'yanit',
  'iletilen',
  'yonlendirilen',
};

/// Konu başlığındaki yanıt/iletme ön eklerini temizler.
///
/// Hem İngilizce (Re:, Fwd:, Fw:) hem Türkçe (Yan:, Ynt:, İlt:, Yanıt:)
/// ön ekleri, `Re[2]:` gibi sayaçlı biçimler ve art arda tekrarlar kaldırılır.
/// Konuşma gruplama (threading) bu normalleştirilmiş konuyu kullanır.
///
/// Ön ek karşılaştırması [foldForSearch] üzerinden yapılır: düzenli ifadenin
/// `caseSensitive: false` seçeneği `İ` (U+0130) harfini `i` ile eşleştirmez,
/// bu yüzden "İlt:" ön eki yakalanmaz. Katlama bu farkı ortadan kaldırır.
String normalizeSubject(String? subject) {
  if (subject == null) return '';
  // Katlanmış başlıklar satır sonu içerebilir; tek satıra indirilir.
  var text = subject.replaceAll(RegExp(r'\s+'), ' ').trim();

  final prefix = RegExp(
    r'^([\p{L}]{2,12})\s*(\[\d+\])?\s*:\s*',
    unicode: true,
  );

  while (true) {
    final match = prefix.firstMatch(text);
    if (match == null) break;
    final token = foldForSearch(match.group(1)!);
    if (!_replyPrefixes.contains(token)) break;
    text = text.substring(match.end).trim();
  }
  return text;
}

/// Bir e-posta adresinden görünen ad üretir.
///
/// `ahmet.yilmaz@firma.com` → `Ahmet Yilmaz`
///
/// Büyük harfe çevirme Türkçe kurallarıyla yapılır: `ismail` → `İsmail`.
/// Bu yüzden `info` → `İnfo` olur. Hedef kitle Türkçe yazan kullanıcılar
/// olduğu için Türkçe kural doğru varsayılandır; `Ismail` yazmak her Türk
/// kullanıcı için hatalıdır.
String displayNameFromEmail(String email) {
  final at = email.indexOf('@');
  final local = at > 0 ? email.substring(0, at) : email;
  final parts = local
      .split(RegExp(r'[._\-+]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return email;
  return parts
      .map((p) => p.length == 1
          ? trUpper(p)
          : '${trUpper(p[0])}${trLower(p.substring(1))}')
      .join(' ');
}

/// Avatar harfi: ada göre ilk anlamlı karakter.
String avatarInitial(String? name, String? email) {
  final source = (name != null && name.trim().isNotEmpty)
      ? name.trim()
      : (email ?? '').trim();
  if (source.isEmpty) return '?';
  for (final rune in source.runes) {
    final ch = String.fromCharCode(rune);
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch)) {
      return trUpper(ch);
    }
  }
  return '?';
}

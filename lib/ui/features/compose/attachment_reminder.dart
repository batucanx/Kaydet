import 'package:kaydet/core/turkish.dart';

/// Gönderilmekte olan bir iletide metin veya konu içerisinde ek dosyalardan
/// bahsedilip bahsedilmediğini kontrol eder.
///
/// Profesyonel e-posta istemcilerinde (Gmail, Outlook) olduğu gibi, kullanıcı
/// iletide "ekledim", "ektedir", "attached" gibi ifadeler kullanıp dosya
/// eklemeyi unuttuysa gönderme öncesinde kullanıcıyı uyararak olası
/// mahcubiyetlerin önüne geçer.
abstract final class AttachmentReminder {
  /// Ek dosya bildiren Türkçe ve İngilizce anahtar kelimeler / kökler.
  ///
  /// Kelime sınırları (`\b` veya noktalama/boşluk) ile eşleştirilir; böylece
  /// "ekim", "ekip", "ekstra", "ekran", "ekonomik", "teşekkür" gibi sözcükler
  /// yanlış pozitif (false positive) üretmez.
  static final RegExp _keywordRegex = RegExp(
    r'(?:^|[\s\p{P}])('
    // Türkçe ek bildiren kalıplar
    r'ek(?:te|tedir|teki|teydi|tedirler|lerin|leri)?|'
    r'ekli(?:dir)?|'
    r'ekledim|ekliyorum|eklemiştim|ekledik|ekliyoruz|'
    r'ilişik(?:te|tedir|teki)?|'
    // İngilizce ek bildiren kalıplar
    r'attach(?:ed|ment|ments|ing)?|'
    r'enclos(?:ed|ing|ure)?'
    r')(?:$|[\s\p{P}])',
    unicode: true,
  );

  /// Alıntı başlıklarını tespit eder: yanıt/iletme gövdesindeki eski iletiler
  /// kullanıcının yazdığı yeni metinden ayrılmalıdır.
  static final RegExp _quoteHeaderRegex = RegExp(
    r'(?:tarihinde .* yazdı:|---------- İletilen ileti ----------|Original Message|From:)',
    caseSensitive: false,
  );

  /// Verilen metinde ek bildiren anahtar sözcük olup olmadığını kontrol eder.
  static bool containsKeyword(String text) {
    if (text.trim().isEmpty) return false;
    // Türkçe İ / I dönüşümlerini doğru karşılamak için trLower kullanılır
    final normalized = trLower(text);
    return _keywordRegex.hasMatch(normalized);
  }

  /// Yanıt veya iletmede alıntılanan eski metni ayıklayıp yalnızca kullanıcının
  /// YENİ yazdığı gövdeyi döndürür.
  static String extractUserTypedBody(String fullBody) {
    final lines = fullBody.split('\n');
    final userLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      // Standart Markdown / e-posta alıntı satırı
      if (trimmed.startsWith('>')) {
        continue;
      }
      // Alıntı başlığına rastlandığı anda gerisi eski iletidir
      if (_quoteHeaderRegex.hasMatch(trimmed)) {
        break;
      }
      userLines.add(line);
    }

    return userLines.join('\n').trim();
  }

  /// Bir iletide unutulmuş ek uyarısı gösterilmesi gerekip gerekmediğini denetler.
  ///
  /// [hasAttachments] `true` ise veya ne konuda ne de kullanıcının yazdığı
  /// gövdede anahtar kelime yoksa `false` döner.
  static bool shouldWarn({
    required String subject,
    required String body,
    required bool hasAttachments,
    bool isReplyOrForward = false,
  }) {
    if (hasAttachments) return false;

    // Konuyu kontrol et
    if (containsKeyword(subject)) return true;

    // Gövdeyi kontrol et (yanıt/iletme ise alıntıyı çıkar)
    final textToCheck = isReplyOrForward ? extractUserTypedBody(body) : body;
    return containsKeyword(textToCheck);
  }
}

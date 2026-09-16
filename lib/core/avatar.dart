/// Gönderene göre kararlı avatar rengi seçimi.
///
/// React prototipindeki `name.charCodeAt(0) % 15` yaklaşımı yetersizdi:
/// aynı harfle başlayan tüm isimler ("Ahmet", "Ali", "Ayşe") aynı rengi
/// alıyordu. Burada e-posta adresinin tamamı FNV-1a ile özetlenir; aynı
/// kişi her zaman aynı rengi alır, farklı kişiler dengeli dağılır.
abstract final class AvatarHash {
  static const int _fnvOffsetBasis = 0x811C9DC5;
  static const int _fnvPrime = 0x01000193;
  static const int _mask32 = 0xFFFFFFFF;

  /// 32-bit FNV-1a özeti.
  static int hash32(String input) {
    var value = _fnvOffsetBasis;
    for (final unit in input.codeUnits) {
      value = (value ^ unit) & _mask32;
      value = (value * _fnvPrime) & _mask32;
    }
    return value;
  }

  /// Verilen anahtar için ton indeksi.
  ///
  /// Anahtar olarak e-posta adresi tercih edilir (kararlı ve benzersiz);
  /// yoksa görünen ada düşülür.
  static int toneIndex(String? email, String? name, int toneCount) {
    if (toneCount <= 0) return 0;
    final key = (email != null && email.trim().isNotEmpty)
        ? email.trim().toLowerCase()
        : (name ?? '').trim().toLowerCase();
    if (key.isEmpty) return 0;
    return hash32(key) % toneCount;
  }
}

/// E-posta adresinden alan adını ayıklar (`ali@sirket.com` → `sirket.com`).
String? domainOf(String? email) {
  if (email == null) return null;
  final trimmed = email.trim().toLowerCase();
  final at = trimmed.indexOf('@');
  if (at < 0 || at == trimmed.length - 1) return null;
  final domain = trimmed.substring(at + 1);
  return domain.isEmpty ? null : domain;
}

/// Kişisel/ücretsiz e-posta sağlayıcıları.
///
/// Bu alan adları için marka logosu aranmaz: aynı sağlayıcıyı kullanan
/// herkes aynı logoyu (ör. Gmail'in "G"si) alır, bu da kişiyi tanımaz —
/// bunun yerine her zaman ada dayalı renkli baş harf gösterilir.
abstract final class PersonalEmailDomains {
  static const Set<String> _domains = {
    'gmail.com',
    'googlemail.com',
    'outlook.com',
    'hotmail.com',
    'hotmail.com.tr',
    'live.com',
    'msn.com',
    'yahoo.com',
    'yahoo.com.tr',
    'icloud.com',
    'me.com',
    'mac.com',
    'yandex.com',
    'yandex.com.tr',
    'protonmail.com',
    'proton.me',
    'mail.ru',
    'gmx.com',
    'gmx.net',
    'aol.com',
  };

  static bool isPersonal(String domain) => _domains.contains(domain);
}

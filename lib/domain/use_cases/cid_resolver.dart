import 'dart:convert';
import 'dart:typed_data';

/// HTML gövdesindeki `cid:` başvurularını, iletinin gömülü (inline) görsel
/// parçalarından üretilen `data:` adresleriyle değiştirir.
///
/// WebView `cid:` şemasını tanımaz; çözülmezse imza/logo/e-fatura logosu gibi
/// gömülü görseller kırık görünür. Çözümleme gövde indirilirken (parçalar
/// zaten elde iken) yapılır; sonuç yerel veritabanına yazılır, sunucuya bir
/// şey gitmez.
abstract final class CidResolver {
  /// Tek bir görselin üst sınırı. Daha büyükleri `data:` olarak gömülmez
  /// (veritabanı satırı ve WebView belgesi şişmesin); başvuru olduğu gibi kalır.
  static const int maxImageBytes = 3 * 1024 * 1024;

  /// Bir iletide gömülecek toplam görsel üst sınırı.
  static const int maxTotalBytes = 8 * 1024 * 1024;

  /// Content-ID → (medya türü, bayt) ile [html] içindeki `cid:` başvurularını
  /// çözer. Anahtarlar [normalizeId] ile normalleştirilmiş olmalıdır.
  ///
  /// Şu yerlerdeki başvurular bulunur: `src`, `background`, `poster`
  /// nitelikleri ve CSS `url(...)` (satır içi stil ile `<style>`). `cid:`
  /// şeması ve Content-ID büyük/küçük harfe duyarsızdır; yüzde kodlu
  /// (`%40`) ve `<...>` sarmalı adresler de eşleşir. Bulunamayan başvuru
  /// olduğu gibi bırakılır.
  static String resolve(
    String html,
    Map<String, ({String mimeType, Uint8List bytes})> parts,
  ) {
    if (parts.isEmpty || !_hasCid.hasMatch(html)) return html;
    final uriCache = <String, String>{};
    return html.replaceAllMapped(_reference, (m) {
      final id = normalizeId(m.group(1)!);
      final part = parts[id];
      if (part == null) return m[0]!;
      return uriCache.putIfAbsent(
        id,
        () => 'data:${part.mimeType};base64,${base64.encode(part.bytes)}',
      );
    });
  }

  /// `<Logo@X.com>`, `cid:Logo%40X.com` → `logo@x.com`.
  static String normalizeId(String raw) {
    var id = raw.trim();
    if (id.toLowerCase().startsWith('cid:')) id = id.substring(4);
    if (id.startsWith('<') && id.endsWith('>') && id.length > 1) {
      id = id.substring(1, id.length - 1);
    }
    try {
      id = Uri.decodeComponent(id);
    } on FormatException {
      // Geçersiz yüzde kodlaması: ham hâliyle eşleştirilir.
    }
    return id.trim().toLowerCase();
  }

  static final RegExp _hasCid = RegExp('cid:', caseSensitive: false);

  // `cid:` + tırnak, boşluk, `)`, `>` ya da `&quot;` öncesine kadar her şey.
  // `\b` yerine açık öncül: `acid:` gibi sözcük sonları eşleşmesin.
  static final RegExp _reference = RegExp(
    r'(?<![\w-])cid:((?:(?!&quot;|&#34;|&#39;)[^\s"\x27)<>])+)',
    caseSensitive: false,
  );
}

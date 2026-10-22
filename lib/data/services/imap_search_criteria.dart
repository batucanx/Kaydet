import 'dart:convert';

import '../../core/turkish.dart';

/// IMAP `SEARCH` ölçütünü (RFC 3501) güvenli biçimde kurar — sunucu tarafı
/// arama (bkz. `SyncEngine.searchRemote`) için.
///
/// Kullanıcı metni asla ham olarak ölçüte eklenmez: yalnızca yazdırılabilir
/// ASCII içeren değerler tırnaklanır (`"` ve `\` kaçırılır); Türkçe harf gibi
/// ASCII dışı ya da satır sonu içeren değerler IMAP *literal*i (`{bayt}`)
/// olarak gönderilir ve ölçüt `CHARSET UTF-8` ile başlar. Literal içeren
/// ölçüt `\n` ile satırlara bölünür: `enough_mail` her satırı sunucunun
/// devam (`+`) yanıtından sonra gönderir.
abstract final class ImapSearchCriteria {
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// [words] içindeki her sözcük başlıkta ya da gövdede geçmeli (`TEXT`);
  /// [from] gönderen, [recipient] Kime/Bilgi/Gizli alanlarından birinde
  /// aranır. [since] (dahil) ve [before] (hariç) YEREL takvim günleridir.
  /// Silinmek üzere işaretli (`\Deleted`) iletiler hariç tutulur.
  ///
  /// Hiçbir koşul verilmezse `null` döner (her şeyi aramak anlamsız).
  static String? build({
    List<String> words = const [],
    String? from,
    String? recipient,
    DateTime? since,
    DateTime? before,
  }) {
    final clean = [
      for (final word in words)
        if (word.trim().isNotEmpty) word.trim(),
    ];
    if (clean.isEmpty &&
        from == null &&
        recipient == null &&
        since == null &&
        before == null) {
      return null;
    }

    final parts = <String>[];
    for (final word in clean) {
      parts.add('TEXT ${_string(word)}');
    }
    if (from != null) parts.add('FROM ${_string(from)}');
    if (recipient != null) {
      final r = _string(recipient);
      parts.add('OR OR TO $r CC $r BCC $r');
    }
    if (since != null) parts.add('SINCE ${_date(since)}');
    if (before != null) parts.add('BEFORE ${_date(before)}');
    parts.add('UNDELETED');

    final body = parts.join(' ');
    final needsCharset = body.contains('\n');
    return needsCharset ? 'CHARSET UTF-8 $body' : body;
  }

  /// IMAP sunucusu UTF-8 charset veya literal desteklemediğinde (veya hata
  /// döndüğünde) uygulamanın çökmemesi ve aramanın sürmesi için sessizce geri
  /// çekilen (graceful fallback) saf ASCII ölçüt. Türkçe karakterler
  /// `foldForSearch` ile ASCII karşılıklarına (`ş->s, ç->c...`) dönüştürülür.
  static String? buildFallbackAscii({
    List<String> words = const [],
    String? from,
    String? recipient,
    DateTime? since,
    DateTime? before,
  }) {
    final clean = [
      for (final word in words)
        if (word.trim().isNotEmpty) foldForSearch(word.trim()),
    ];
    final asciiFrom =
        from == null || from.trim().isEmpty ? null : foldForSearch(from.trim());
    final asciiRecipient = recipient == null || recipient.trim().isEmpty
        ? null
        : foldForSearch(recipient.trim());

    if (clean.isEmpty &&
        asciiFrom == null &&
        asciiRecipient == null &&
        since == null &&
        before == null) {
      return null;
    }

    final parts = <String>[];
    for (final word in clean) {
      parts.add('TEXT ${_asciiString(word)}');
    }
    if (asciiFrom != null) parts.add('FROM ${_asciiString(asciiFrom)}');
    if (asciiRecipient != null) {
      final r = _asciiString(asciiRecipient);
      parts.add('OR OR TO $r CC $r BCC $r');
    }
    if (since != null) parts.add('SINCE ${_date(since)}');
    if (before != null) parts.add('BEFORE ${_date(before)}');
    parts.add('UNDELETED');

    return parts.join(' ');
  }

  static String _asciiString(String value) {
    final escaped = value
        .replaceAll(_backslash, '$_backslash$_backslash')
        .replaceAll('"', '$_backslash"');
    return '"$escaped"';
  }

  /// `1-Oct-2026` (IMAP `date`): gün başında sıfırsız, ay İngilizce kısaltma.
  static String _date(DateTime day) =>
      '${day.day}-${_months[day.month - 1]}-${day.year}';

  static final _backslash = String.fromCharCode(92);

  static final _plainAscii = RegExp(r'^[\x20-\x7E]*$');

  static String _string(String value) {
    if (_plainAscii.hasMatch(value)) {
      final escaped = value
          .replaceAll(_backslash, '$_backslash$_backslash')
          .replaceAll('"', '$_backslash"');
      return '"$escaped"';
    }
    // Literal: `{bayt}` + satır sonu + veri. Veri ölçütün devamıyla aynı satırda
    // sürer (sonraki parça `\n`den sonra gelir).
    final flat = value.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return '{${utf8.encode(flat).length}}\n$flat';
  }
}


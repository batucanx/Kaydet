/// Engellenen göndericilerin iletilerini SUNUCUDA İstenmeyen klasörüne ayıran Sieve kuralı.
///
/// Kaydet, kullanıcının etkin Sieve betiğinin İÇİNDE tek bir işaretli blok tutar ve bloğun dışına
/// asla dokunmaz (kullanıcının kendi filtreleri olabilir; ManageSieve'de aynı anda tek betik etkindir).
/// Bu dosya yalnızca metin kısmıdır: bloğu üret, var olan betiğe doğru yere ekle, değiştir, kaldır, geri oku.
///
/// KAYNAK: web projesindeki `packages/domain/src/sieve/block.ts`. İki gerçekleme BİREBİR aynı çıktıyı
/// vermek ZORUNDADIR; ortak test tablosu `test/fixtures/sieve_vectors.json` (web'deki `vectors.json`un kopyası).
///
/// Yerleşim: Sieve'de her `require` komutu diğer komutlardan ÖNCE gelmelidir; bu yüzden blok, betiğin
/// başındaki son `require` satırının hemen ardına (hiç yoksa en başa) konur ve kendi
/// `require ["fileinto"];` satırını taşır.
library;

/// İşaret önekleri: blok bunlarla bulunur, ASLA değişmemelidir.
const String sieveBegin = '# BEGIN KAYDET BLOCKED SENDERS';
const String sieveEnd = '# END KAYDET BLOCKED SENDERS';
const String _beginLine = '$sieveBegin (managed by Kaydet, do not edit)';

String _quote(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

String _unquote(String value) => value.replaceAllMapped(
  RegExp(r'\\(.)', dotAll: true),
  (m) => m.group(1)!,
);

/// Küçük harfli, tekrarsız, sıralı: aynı küme her zaman aynı betiği verir.
List<String> normalizeBlockedEmails(Iterable<String> emails) {
  final set = {
    for (final e in emails)
      if (e.trim().isNotEmpty) e.trim().toLowerCase(),
  };
  return set.toList()..sort();
}

/// Blok (LF satır sonları, sonda satır sonu yok). [emails] boş olmamalı.
String buildBlockedSendersBlock(Iterable<String> emails, String junkMailbox) {
  final list = normalizeBlockedEmails(emails);
  return [
    _beginLine,
    'require ["fileinto"];',
    'if address :is :all "from" [${list.map(_quote).join(', ')}] {',
    '  fileinto ${_quote(junkMailbox)};',
    '  stop;',
    '}',
    sieveEnd,
  ].join('\n');
}

class _Located {
  const _Located(this.start, this.end);
  final int start;

  /// END satırının (ve satır sonunun) hemen ardı.
  final int end;
}

_Located? _locate(String text) {
  final begin = text.indexOf(sieveBegin);
  if (begin < 0) return null;
  final start = begin == 0 ? 0 : text.lastIndexOf('\n', begin - 1) + 1;
  final endMarker = text.indexOf(sieveEnd, begin);
  if (endMarker < 0) return null;
  final lineEnd = text.indexOf('\n', endMarker);
  return _Located(start, lineEnd < 0 ? text.length : lineEnd + 1);
}

final RegExp _requireWord = RegExp(r'^require(?![A-Za-z0-9_])', caseSensitive: false);

/// Baştaki son `require` komutunun bulunduğu satırın hemen ardı (hiç yoksa 0).
int _afterLeadingRequires(String text) {
  var pos = 0;
  var after = 0;
  final n = text.length;
  while (pos < n) {
    final ch = text[pos];
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      pos++;
    } else if (ch == '#') {
      final eol = text.indexOf('\n', pos);
      pos = eol < 0 ? n : eol + 1;
    } else if (ch == '/' && pos + 1 < n && text[pos + 1] == '*') {
      final close = text.indexOf('*/', pos + 2);
      pos = close < 0 ? n : close + 2;
    } else if (_requireWord.hasMatch(
      text.substring(pos, pos + 8 > n ? n : pos + 8),
    )) {
      // sonlandıran ';'ye kadar, tırnaklı dizgeleri atlayarak (içindeki ';' veridir)
      var i = pos + 7;
      var inString = false;
      while (i < n) {
        final c = text[i];
        if (inString) {
          if (c == r'\') {
            i++;
          } else if (c == '"') {
            inString = false;
          }
        } else if (c == '"') {
          inString = true;
        } else if (c == ';') {
          break;
        }
        i++;
      }
      if (i >= n) return after;
      final eol = text.indexOf('\n', i);
      pos = eol < 0 ? n : eol + 1;
      after = pos;
    } else {
      break;
    }
  }
  return after;
}

/// Engelli göndericiler bloğu [emails] olan betik: yoksa eklenir, varsa yerinde değiştirilir,
/// [emails] boşsa kaldırılır. Bloğun dışındaki her şey (satır sonları dahil) AYNEN döner.
String applyBlockedSendersBlock(
  String script,
  Iterable<String> emails,
  String junkMailbox,
) {
  final eol = script.contains('\r\n') ? '\r\n' : '\n';
  final text = script.replaceAll('\r\n', '\n');
  final found = _locate(text);
  final list = normalizeBlockedEmails(emails);
  String out;
  if (list.isEmpty) {
    if (found == null) return script;
    var end = found.end;
    if (end < text.length && text[end] == '\n') end++; // bloğun eklendiği boş satır
    out = text.substring(0, found.start) + text.substring(end);
  } else {
    final block = buildBlockedSendersBlock(list, junkMailbox);
    if (found != null) {
      out = '${text.substring(0, found.start)}$block\n${text.substring(found.end)}';
    } else {
      final pos = _afterLeadingRequires(text);
      final prefix = text.substring(0, pos);
      final suffix = text.substring(pos);
      final lead = prefix.isEmpty || prefix.endsWith('\n') ? '' : '\n';
      final gap = suffix.isEmpty || suffix.startsWith('\n') ? '' : '\n';
      out = '$prefix$lead$block\n$gap$suffix';
    }
  }
  return eol == '\n' ? out : out.replaceAll('\n', eol);
}

final RegExp _fromList = RegExp(
  r'"from"\s*\[((?:[^\]"]|"(?:[^"\\]|\\.)*")*)\]',
  dotAll: true,
);
final RegExp _quoted = RegExp(r'"((?:[^"\\]|\\.)*)"', dotAll: true);

/// Betikteki Kaydet bloğunun engellediği adresler; blok yoksa `null`.
List<String>? readBlockedSendersBlock(String script) {
  final text = script.replaceAll('\r\n', '\n');
  final found = _locate(text);
  if (found == null) return null;
  final block = text.substring(found.start, found.end);
  final list = _fromList.firstMatch(block);
  if (list == null) return const [];
  return [
    for (final m in _quoted.allMatches(list.group(1)!)) _unquote(m.group(1)!),
  ];
}

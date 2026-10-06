/// Her iki Kaydet istemcisinin IMAP sunucusunda tuttuğu ayar belgesi.
///
/// Gizli bir klasörde (`Kaydet-Settings`) TEK ileti olarak durur: konu
/// `Kaydet settings (do not delete)`, `X-Kaydet-Settings: 1` başlığı ve base64
/// kodlu `text/plain` JSON gövde. Yazan, yeni sürümü ekler ve sonra eskileri
/// siler; okuyan en yüksek `rev`i alır. İki istemci aynı anda yazarsa iki ileti
/// kalır: yüksek `rev` kazanır, diğerinin değişikliği bir sonraki eşitlemede
/// yeniden birleştirilir.
///
/// Bu kodun anlamadığı DAHA YENİ bir `v` taşıyan belgenin üzerine ASLA yazılmaz:
/// daha yeni bir uygulama bu sürümün düşüreceği veriyi eklemiş olabilir.
///
/// KAYNAK: web projesindeki `packages/domain/src/settings/document.ts`.
library;

import 'dart:convert';

import 'settings_merge.dart';

const String settingsMailboxName = 'Kaydet-Settings';
const String settingsFormat = 'kaydet-settings';
/// v2, `templates` (hazır şablonlar), v3 `blockedSenders` (engellenen kullanıcılar) ekledi. Eski
/// belgeler (v1, v2) hâlâ okunur, eksik koleksiyonlar boş sayılır; her yazım v3'tür ve daha eski bir
/// sürümü bilen uygulama bunu "daha yeni" sayıp eşitlemeye dokunmaz (bilmediği koleksiyonu düşürürdü).
const int settingsVersion = 3;
const String settingsSubject = 'Kaydet settings (do not delete)';
const String settingsHeader = 'X-Kaydet-Settings';

/// Kabul edilen belge üst sınırı (karakter): bozuk ya da kötü niyetli belgeyi durdurur.
const int settingsMaxChars = 512 * 1024;

class SettingsDocument {
  const SettingsDocument({
    required this.rev,
    required this.updatedAt,
    required this.writer,
    required this.data,
  });

  final int rev;
  final String updatedAt;
  final String writer;
  final SettingsData data;

  Map<String, Object?> toJson() => {
    'format': settingsFormat,
    'v': settingsVersion,
    'rev': rev,
    'updatedAt': updatedAt,
    'writer': writer,
    'labels': data.labels,
    'signatures': data.signatures,
    'templates': data.templates,
    'blockedSenders': data.blockedSenders,
  };
}

sealed class LatestSettings {
  const LatestSettings();
}

/// Geçerli belge yok.
class NoSettings extends LatestSettings {
  const NoSettings();
}

/// Bu kodun bilmediği daha yeni bir biçim var.
class NewerSettings extends LatestSettings {
  const NewerSettings();
}

class FoundSettings extends LatestSettings {
  const FoundSettings(this.document);
  final SettingsDocument document;
}

enum _ParseKind { document, newer, invalid }

class _Parsed {
  const _Parsed(this.kind, [this.document]);
  final _ParseKind kind;
  final SettingsDocument? document;
}

bool _validCollection(Object? raw) {
  if (raw is! Map) return false;
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String || key.isEmpty || key.length > 300) return false;
    if (entry.value is! Map) return false;
  }
  return true;
}

_Parsed _parse(String text) {
  if (text.length > settingsMaxChars) return const _Parsed(_ParseKind.invalid);
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return const _Parsed(_ParseKind.invalid);
  }
  if (json is! Map<String, Object?>) return const _Parsed(_ParseKind.invalid);
  if (json['format'] != settingsFormat) return const _Parsed(_ParseKind.invalid);
  final v = json['v'];
  if (v is! int) return const _Parsed(_ParseKind.invalid);
  if (v > settingsVersion) return const _Parsed(_ParseKind.newer);
  if (v < 1) return const _Parsed(_ParseKind.invalid);

  final rev = json['rev'];
  final updatedAt = json['updatedAt'];
  final writer = json['writer'];
  if (rev is! int || rev < 0) return const _Parsed(_ParseKind.invalid);
  if (updatedAt is! String || updatedAt.length > 40) {
    return const _Parsed(_ParseKind.invalid);
  }
  if (writer is! String || writer.length > 60) {
    return const _Parsed(_ParseKind.invalid);
  }
  // `templates` v1'de, `blockedSenders` v1/v2'de yoktur: eksikse boş sayılır.
  if (!_validCollection(json['labels']) ||
      !_validCollection(json['signatures']) ||
      (json['templates'] != null && !_validCollection(json['templates'])) ||
      (json['blockedSenders'] != null &&
          !_validCollection(json['blockedSenders']))) {
    return const _Parsed(_ParseKind.invalid);
  }
  return _Parsed(
    _ParseKind.document,
    SettingsDocument(
      rev: rev,
      updatedAt: updatedAt,
      writer: writer,
      data: SettingsData.fromJson(json),
    ),
  );
}

/// Birleştirilecek belge: bulunan iletiler arasında en yüksek sürüm.
LatestSettings pickLatestSettings(Iterable<String> texts) {
  SettingsDocument? best;
  for (final text in texts) {
    final parsed = _parse(text);
    if (parsed.kind == _ParseKind.newer) return const NewerSettings();
    final doc = parsed.document;
    if (parsed.kind == _ParseKind.document &&
        doc != null &&
        (best == null || doc.rev > best.rev)) {
      best = doc;
    }
  }
  return best == null ? const NoSettings() : FoundSettings(best);
}

String serializeSettingsDocument(SettingsDocument document) =>
    jsonEncode(document.toJson());

/// [path]in son parçası gizli ayar klasörü mü (her derinlikte, her ayraçla)?
bool isSettingsMailbox(String path, String delimiter) {
  var leaf = path;
  if (delimiter.isNotEmpty && path.contains(delimiter)) {
    leaf = path.substring(path.lastIndexOf(delimiter) + delimiter.length);
  }
  return leaf == settingsMailboxName;
}

/// Belgeyi taşıyan küçük RFC 5322 iletisi. Gövde UTF-8 metindir, base64 kodludur
/// (her sunucu ve istemci kitaplığı birebir aynı baytları geri verir). Web
/// tarafı aynı biçimi yazar ve okur.
String buildSettingsMime({
  required String from,
  required String text,
  required DateTime date,
  required String messageId,
}) {
  final encoded = base64.encode(utf8.encode(text));
  final lines = <String>[
    for (var i = 0; i < encoded.length; i += 76)
      encoded.substring(i, i + 76 > encoded.length ? encoded.length : i + 76),
  ];
  return [
    'From: $from',
    'To: $from',
    'Subject: $settingsSubject',
    'Date: ${_rfc822(date.toUtc())}',
    'Message-ID: <$messageId@kaydet.settings>',
    'MIME-Version: 1.0',
    '$settingsHeader: 1',
    'Content-Type: text/plain; charset=utf-8',
    'Content-Transfer-Encoding: base64',
    '',
    ...lines,
    '',
  ].join('\r\n');
}

String _rfc822(DateTime utc) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[utc.weekday - 1]}, ${two(utc.day)} ${months[utc.month - 1]} '
      '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} +0000';
}

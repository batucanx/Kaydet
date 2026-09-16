import 'dart:convert';

import '../../core/turkish.dart';
import '../../data/database/tables.dart';

/// Servis sınırındaki tipler.
///
/// `enough_mail` tipleri yalnızca `data/services/` içinde kullanılır; bu
/// dosyadaki tipler o sınırı geçer. Paket bir gün değişirse yalnızca
/// servis uygulamaları yeniden yazılır, uygulamanın geri kalanı etkilenmez.

/// E-posta adresi + görünen ad.
class EmailAddress {
  const EmailAddress({required this.email, this.name});

  final String email;
  final String? name;

  /// Görünen ad yoksa adresten üretir.
  String get display {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return displayNameFromEmail(email);
  }

  /// RFC 5322 biçimi: `Ad Soyad <adres@alan.com>`
  String get formatted {
    final n = name?.trim();
    if (n == null || n.isEmpty) return email;
    return '$n <$email>';
  }

  Map<String, dynamic> toMap() => {'e': email, if (name != null) 'n': name};

  static EmailAddress fromMap(Map<String, dynamic> map) => EmailAddress(
        email: (map['e'] ?? '') as String,
        name: map['n'] as String?,
      );

  static String encodeList(List<EmailAddress> list) =>
      jsonEncode(list.map((a) => a.toMap()).toList());

  static List<EmailAddress> decodeList(String? json) {
    if (json == null || json.isEmpty || json == '[]') return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(EmailAddress.fromMap)
          .where((a) => a.email.isNotEmpty)
          .toList();
    } on FormatException {
      return const [];
    }
  }

  /// `"Ad Soyad" <a@b.com>, c@d.com` biçimindeki metni ayrıştırır.
  static List<EmailAddress> parseInput(String raw) {
    if (raw.trim().isEmpty) return const [];
    final result = <EmailAddress>[];
    // Tırnak içindeki virgülleri korumak için basit bir durum makinesi.
    final buffer = StringBuffer();
    var inQuotes = false;
    final chunks = <String>[];
    for (final rune in raw.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '"') {
        inQuotes = !inQuotes;
        buffer.write(ch);
      } else if ((ch == ',' || ch == ';') && !inQuotes) {
        chunks.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    chunks.add(buffer.toString());

    for (final chunk in chunks) {
      final text = chunk.trim();
      if (text.isEmpty) continue;
      final match = RegExp(r'^(.*?)<([^>]+)>$').firstMatch(text);
      if (match != null) {
        var name = match.group(1)!.trim();
        if (name.startsWith('"') && name.endsWith('"') && name.length > 1) {
          name = name.substring(1, name.length - 1);
        }
        result.add(EmailAddress(
          email: match.group(2)!.trim(),
          name: name.isEmpty ? null : name,
        ));
      } else {
        result.add(EmailAddress(email: text));
      }
    }
    return result;
  }

  static final RegExp _emailPattern = RegExp(
    r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}"
    r'[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$',
  );

  bool get isValid => _emailPattern.hasMatch(email);

  static bool isValidEmail(String value) => _emailPattern.hasMatch(value.trim());

  @override
  String toString() => formatted;

  @override
  bool operator ==(Object other) =>
      other is EmailAddress &&
      other.email.toLowerCase() == email.toLowerCase();

  @override
  int get hashCode => email.toLowerCase().hashCode;
}

/// Sunucudan okunan klasör bilgisi.
class RemoteMailbox {
  const RemoteMailbox({
    required this.path,
    required this.name,
    required this.delimiter,
    required this.specialUse,
    this.encodedPath = '',
    this.isSelectable = true,
    this.isSubscribed = true,
  });

  final String path;
  final String encodedPath;
  final String name;
  final String delimiter;
  final SpecialUse specialUse;
  final bool isSelectable;
  final bool isSubscribed;
}

/// Klasör seçildiğinde dönen durum.
class MailboxState {
  const MailboxState({
    required this.uidValidity,
    required this.uidNext,
    required this.messageCount,
    this.highestModSeq,
    this.permanentFlags = const [],
  });

  final int uidValidity;
  final int uidNext;
  final int messageCount;
  final int? highestModSeq;
  final List<String> permanentFlags;

  /// Sunucu özel anahtar kelime (etiket) kabul ediyor mu?
  bool get supportsKeywords => permanentFlags.contains(r'\*');
}

/// Sunucudan çekilen ileti başlığı (envelope).
class FetchedEnvelope {
  const FetchedEnvelope({
    required this.uid,
    required this.date,
    required this.subject,
    required this.from,
    required this.to,
    required this.cc,
    required this.bcc,
    required this.flags,
    required this.sizeBytes,
    required this.hasAttachments,
    this.messageId,
    this.inReplyTo,
    this.references,
    this.preview = '',
  });

  final int uid;
  final DateTime date;
  final String subject;
  final EmailAddress? from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final List<EmailAddress> bcc;
  final List<String> flags;
  final int sizeBytes;
  final bool hasAttachments;
  final String? messageId;
  final String? inReplyTo;
  final String? references;
  final String preview;

  bool get isSeen => flags.contains(r'\Seen');
  bool get isFlagged => flags.contains(r'\Flagged');
  bool get isAnswered => flags.contains(r'\Answered');
  bool get isDraft => flags.contains(r'\Draft');
  bool get isDeleted => flags.contains(r'\Deleted');

  /// `\` ile başlamayan bayraklar kullanıcı etiketleridir.
  List<String> get keywords =>
      flags.where((f) => !f.startsWith(r'\')).toList();
}

/// Sunucudan çekilen ileti gövdesi.
class FetchedBody {
  const FetchedBody({
    this.plainText,
    this.html,
    this.attachments = const [],
  });

  final String? plainText;
  final String? html;
  final List<FetchedAttachment> attachments;
}

/// Ek dosya üst verisi.
class FetchedAttachment {
  const FetchedAttachment({
    required this.partId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.contentId,
    this.isInline = false,
  });

  final String partId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String? contentId;
  final bool isInline;
}

/// Sunucu yetenekleri.
class ServerCapabilities {
  const ServerCapabilities({
    required this.raw,
    required this.supportsIdle,
    required this.supportsMove,
    required this.supportsCondStore,
    required this.supportsQresync,
    required this.supportsUidPlus,
  });

  final List<String> raw;
  final bool supportsIdle;
  final bool supportsMove;
  final bool supportsCondStore;
  final bool supportsQresync;
  final bool supportsUidPlus;

  static const ServerCapabilities unknown = ServerCapabilities(
    raw: [],
    supportsIdle: false,
    supportsMove: false,
    supportsCondStore: false,
    supportsQresync: false,
    supportsUidPlus: false,
  );
}

/// Bir klasördeki bayrak durumu (artımlı senkronizasyon için).
class RemoteFlagState {
  const RemoteFlagState({required this.uid, required this.flags});
  final int uid;
  final List<String> flags;
}

/// Gönderilecek ileti.
class OutgoingMessage {
  const OutgoingMessage({
    required this.from,
    required this.to,
    required this.subject,
    required this.plainText,
    this.cc = const [],
    this.bcc = const [],
    this.html,
    this.attachmentPaths = const [],
    this.inReplyTo,
    this.references,
    this.messageId,
    this.isDraft = false,
  });

  final EmailAddress from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final List<EmailAddress> bcc;
  final String subject;
  final String plainText;
  final String? html;
  final List<String> attachmentPaths;
  final String? inReplyTo;
  final String? references;
  final String? messageId;
  final bool isDraft;

  List<EmailAddress> get allRecipients => [...to, ...cc, ...bcc];
}

/// Sunucu kimlik doğrulaması: düz şifre veya OAuth2 erişim token'ı.
///
/// IMAP/SMTP servisleri bu türe göre dallanır — şifreyle klasik
/// `LOGIN`/`AUTH PLAIN`, token'la `AUTHENTICATE XOAUTH2` gönderir. Değer ne
/// olursa olsun veritabanına asla yazılmaz; yalnızca [SecureStore]'a
/// (Android Keystore) gider, tıpkı şifrenin bugüne kadar gittiği yere.
sealed class MailCredential {
  const MailCredential();
}

/// Klasik kullanıcı adı + şifre.
final class PasswordCredential extends MailCredential {
  const PasswordCredential(this.password);
  final String password;
}

/// OAuth2 erişim token'ı (Gmail; ileride Outlook Graph API ayrı bir yoldan
/// eklenecek, bkz. `docs/plan/05-em-client-paritesi.md`).
///
/// Süresi dolduğunda (~1 saat) [AccountRepository] yenileme akışını
/// tetikler — bu sınıf yalnızca o anki geçerli token'ı taşır.
final class OAuthCredential extends MailCredential {
  const OAuthCredential(this.accessToken);
  final String accessToken;
}

/// Bağlantı ayarları — güvenli depodan gelen kimlik bilgisiyle birleştirilir.
class MailServerConfig {
  const MailServerConfig({
    required this.host,
    required this.port,
    required this.security,
    required this.username,
    required this.credential,
  });

  final String host;
  final int port;
  final SocketSecurity security;
  final String username;
  final MailCredential credential;

  bool get isImplicitTls => security == SocketSecurity.ssl;
}

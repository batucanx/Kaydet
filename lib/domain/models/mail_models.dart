import 'dart:convert';

import '../../core/turkish.dart';

/// Servis sınırındaki tipler.
///
/// `enough_mail` tipleri yalnızca `data/services/` içinde kullanılır; bu
/// dosyadaki tipler o sınırı geçer. Paket bir gün değişirse yalnızca
/// servis uygulamaları yeniden yazılır, uygulamanın geri kalanı etkilenmez.

/// Sunucu bağlantı güvenliği.
enum SocketSecurity { none, startTls, ssl }

/// IMAP özel klasör türü.
///
/// Sunucudaki klasör adı ne olursa olsun (`INBOX.Sent`, `Gönderilmiş Öğeler`,
/// `Sent Items`...) uygulama bu türle çalışır.
enum SpecialUse { inbox, sent, drafts, trash, junk, archive, custom }

/// Giden kutusundaki iletinin durumu.
enum OutboxState { none, queued, sending, failed, sent }

/// Kuyruğa alınmış sunucu işlemi.
enum PendingOpType {
  markSeen,
  markUnseen,
  flag,
  unflag,
  addKeyword,
  removeKeyword,
  move,
  deletePermanently,
  appendDraft,
  deleteDraft,
  send,
}

/// Kuyruk durumu.
enum PendingOpStatus { pending, running, failed, done }

/// Outlook tarzı yerel önbellek sınırlaması: her klasör en fazla
/// `Mailboxes.retentionLimit` (varsayılan [defaultLimit]) kadar ileti
/// tutar. Kullanıcı "daha fazla göster" dedikçe (bkz.
/// `SyncController.loadMore`) sınır [step] kadar büyür. Sınırın
/// [deleteBeyondFactor] katını aşan iletiler tamamen silinir; limit ile
/// bu üst eşik arasında kalanlar sadece cihaza inmiş eklerini kaybeder
/// (bkz. `MailRepository.trimMailbox`) — sabitlenmiş, taslak veya
/// gönderilmeyi bekleyen iletiler bu kurallardan HİÇBİR ZAMAN etkilenmez.
abstract final class RetentionPolicy {
  static const int defaultLimit = 500;
  static const int step = 500;
  static const int deleteBeyondFactor = 2;
}

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

  static final RegExp _nameNeedsQuotes = RegExp(r'[,;"<>]');

  /// RFC 5322 biçimi: `Ad Soyad <adres@alan.com>`
  ///
  /// Ad `,` `;` `"` `<` `>` içeriyorsa tırnaklanır: [parseInput] virgülü
  /// yalnızca tırnak içindeyse korur, tırnaksız yazılan
  /// `Yılmaz, Ahmet <a@x.com>` iki ayrı alıcıya (geçersiz `Yılmaz` + `Ahmet`)
  /// bölünürdü. Taslak yeniden açılırken ve yanıtlarken bu metin ayrıştırılır.
  String get formatted {
    final n = name?.trim();
    if (n == null || n.isEmpty) return email;
    if (_nameNeedsQuotes.hasMatch(n)) {
      return '"${n.replaceAll('"', '')}" <$email>';
    }
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
        result.add(
          EmailAddress(
            email: match.group(2)!.trim(),
            name: name.isEmpty ? null : name,
          ),
        );
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

  static bool isValidEmail(String value) =>
      _emailPattern.hasMatch(value.trim());

  @override
  String toString() => formatted;

  @override
  bool operator ==(Object other) =>
      other is EmailAddress && other.email.toLowerCase() == email.toLowerCase();

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

  /// `$Forwarded` — standart olmayan ama yaygın kabul gören iletme
  /// göstergesi (RFC 5788). IMAP anahtar kelimeleri büyük/küçük harfe
  /// duyarsızdır, bu yüzden karşılaştırma katlanarak yapılır.
  bool get isForwarded =>
      flags.any((f) => f.toLowerCase() == r'$forwarded');

  /// `\` ile başlamayan ve `$Forwarded` olmayan bayraklar kullanıcı
  /// etiketleridir — `$Forwarded` bir kullanıcı etiketi değil, iletme
  /// durumu göstergesidir ve etiket listesinde görünmemelidir.
  List<String> get keywords => flags
      .where((f) => !f.startsWith(r'\') && f.toLowerCase() != r'$forwarded')
      .toList();
}

/// Sunucudan çekilen ileti gövdesi.
class FetchedBody {
  const FetchedBody({this.plainText, this.html, this.attachments = const []});

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
    this.supportsNotify = false,
  });

  final List<String> raw;
  final bool supportsIdle;
  final bool supportsMove;
  final bool supportsCondStore;
  final bool supportsQresync;
  final bool supportsUidPlus;
  final bool supportsNotify;

  static const ServerCapabilities unknown = ServerCapabilities(
    raw: [],
    supportsIdle: false,
    supportsMove: false,
    supportsCondStore: false,
    supportsQresync: false,
    supportsUidPlus: false,
    supportsNotify: false,
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

/// Sunucu kimlik doğrulaması.
///
/// Değer veritabanına asla yazılmaz; yalnızca [SecureStore]'a (Android
/// Keystore) gider.
sealed class MailCredential {
  const MailCredential();
}

/// Klasik kullanıcı adı + şifre.
final class PasswordCredential extends MailCredential {
  const PasswordCredential(this.password);
  final String password;
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

import 'dart:typed_data';

import 'mail_models.dart';

/// EML iletisi başlıkları.
class EmlHeaders {
  final String subject;
  final EmailAddress from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final List<EmailAddress> bcc;
  final EmailAddress? replyTo;
  final String? messageId;
  final String? inReplyTo;
  final String? references;
  final DateTime date;
  final Map<String, String> rawHeaders;

  const EmlHeaders({
    required this.subject,
    required this.from,
    required this.to,
    this.cc = const [],
    this.bcc = const [],
    this.replyTo,
    this.messageId,
    this.inReplyTo,
    this.references,
    required this.date,
    this.rawHeaders = const {},
  });
}

/// EML iletisi gövde içeriği.
class EmlBody {
  final String? textPlain;
  final String? textHtml;
  final bool isHtmlPreferred;

  const EmlBody({
    this.textPlain,
    this.textHtml,
    this.isHtmlPreferred = true,
  });

  /// Görüntülenecek öncelikli gövde.
  String? get primaryContent =>
      (isHtmlPreferred && textHtml != null && textHtml!.trim().isNotEmpty)
          ? textHtml
          : (textPlain != null && textPlain!.trim().isNotEmpty
              ? textPlain
              : textHtml);

  bool get isEmpty =>
      (textPlain == null || textPlain!.trim().isEmpty) &&
      (textHtml == null || textHtml!.trim().isEmpty);
}

/// EML içindeki ek dosya.
class EmlAttachment {
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final Uint8List bytes;
  final bool isInline;
  final String? contentId;
  final bool isNestedEml;
  final EmlMessage? nestedMessage;

  const EmlAttachment({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.bytes,
    this.isInline = false,
    this.contentId,
    this.isNestedEml = false,
    this.nestedMessage,
  });
}

/// Ayrıştırılmış tam EML e-posta mesajı.
class EmlMessage {
  final EmlHeaders headers;
  final EmlBody body;
  final List<EmlAttachment> attachments;
  final String rawSource;

  const EmlMessage({
    required this.headers,
    required this.body,
    required this.attachments,
    this.rawSource = '',
  });

  String get subject => headers.subject;
  EmailAddress get from => headers.from;
  List<EmailAddress> get to => headers.to;
  List<EmailAddress> get cc => headers.cc;
  List<EmailAddress> get bcc => headers.bcc;
  EmailAddress? get replyTo => headers.replyTo;
  String? get messageId => headers.messageId;
  DateTime get date => headers.date;
  String? get htmlBody => body.textHtml;
  String? get textBody => body.textPlain;

  /// Yalnızca indirilebilir/görüntülenebilir normal ekler (inline CID görseller hariç).
  List<EmlAttachment> get downloadableAttachments =>
      attachments.where((a) => !a.isInline).toList();
}

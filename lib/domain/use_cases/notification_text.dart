/// Yeni ileti bildiriminin metni — Outlook düzeni: başlıkta gönderen, kapalı
/// görünümde konu, açılınca konu + gövde önizlemesi.
///
/// Saf Dart: bildirim eklentisinden ve veritabanından bağımsız olduğu için
/// biçimlendirme kuralları tek başına sınanabilir.
class MailNotificationText {
  const MailNotificationText({
    required this.sender,
    required this.subject,
    required this.preview,
  });

  factory MailNotificationText.from({
    required String fromName,
    required String fromEmail,
    required String subject,
    required String preview,
  }) {
    final name = fromName.trim();
    final email = fromEmail.trim();
    final cleanSubject = _collapse(subject);
    final cleanPreview = _collapse(preview);

    return MailNotificationText(
      sender: name.isNotEmpty
          ? name
          : (email.isNotEmpty ? email : '(gönderen yok)'),
      subject: cleanSubject.isEmpty ? '(konu yok)' : cleanSubject,
      // Önizleme konuyla aynıysa (gövdesiz ya da yalnızca konu tekrarı olan
      // iletiler) ikinci kez göstermek yalnızca gürültü olur.
      preview: cleanPreview == cleanSubject ? '' : cleanPreview,
    );
  }

  final String sender;
  final String subject;
  final String preview;

  /// Bildirim genişletildiğinde gösterilen metin.
  String get expandedBody => preview.isEmpty ? subject : '$subject\n$preview';

  static String _collapse(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

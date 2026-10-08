/// Push bildiriminden gelen, henüz IMAP'ten eşitlenmemiş ileti özeti.
///
/// iOS'taki Notification Service Extension uygulama arka planda ya da kapalı
/// olsa bile her bildirimdeki ileti özetini App Group'a yazar (bkz.
/// `ios/NotificationService`). Uygulama açılınca liste, eşitlemeyi beklemeden
/// bu kayıtlarla "yeni iletiler" olarak gösterilir. Gövde, ek ve bayrak yoktur;
/// gerçek ileti eşitlemeyle gelince kayıt kaldırılır.
class PushStub {
  const PushStub({
    required this.accountId,
    required this.uid,
    required this.from,
    required this.subject,
    required this.date,
  });

  final int accountId;
  final int uid;
  final String from;
  final String subject;
  final DateTime date;
}

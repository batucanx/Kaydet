import 'package:drift/drift.dart';

/// Sunucu bağlantı güvenliği.
enum SocketSecurity { none, startTls, ssl }

/// Hesabın kimlik doğrulama biçimi.
///
/// `password` varsayılandır (mevcut hesapların tümü bu — geriye dönük
/// uyumluluk için indeks 0). `googleOAuth` şifre yerine [SecureStore]'da
/// saklanan OAuth token'ını kullanır (bkz. `google_oauth_service.dart`).
enum AuthMethod { password, googleOAuth }

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

@DataClassName('AccountRow')
class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get email => text()();
  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get username => text()();

  TextColumn get imapHost => text()();
  IntColumn get imapPort => integer().withDefault(const Constant(993))();
  IntColumn get imapSecurity =>
      intEnum<SocketSecurity>().withDefault(const Constant(2))();

  TextColumn get smtpHost => text()();
  IntColumn get smtpPort => integer().withDefault(const Constant(465))();
  IntColumn get smtpSecurity =>
      intEnum<SocketSecurity>().withDefault(const Constant(2))();

  TextColumn get signature => text().nullable()();
  IntColumn get colorSeed => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Kimlik doğrulama biçimi — `password` (0) veya `googleOAuth` (1).
  /// Gerçek şifre/token değeri burada değil, [SecureStore]'da tutulur.
  IntColumn get authMethod =>
      intEnum<AuthMethod>().withDefault(const Constant(0))();

  /// Sunucu özel anahtar kelime (etiket) destekliyor mu? `null` = bilinmiyor.
  BoolColumn get supportsKeywords => boolean().nullable()();
  TextColumn get capabilitiesJson =>
      text().withDefault(const Constant('[]'))();

  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {email},
      ];
}

@DataClassName('MailboxRow')
class Mailboxes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();

  TextColumn get path => text()();
  TextColumn get encodedPath => text().withDefault(const Constant(''))();
  TextColumn get name => text()();
  IntColumn get specialUse =>
      intEnum<SpecialUse>().withDefault(const Constant(6))();
  TextColumn get delimiter => text().withDefault(const Constant('.'))();

  /// IMAP UIDVALIDITY — değişirse yerel önbellek geçersizdir.
  IntColumn get uidValidity => integer().nullable()();
  IntColumn get uidNext => integer().nullable()();
  IntColumn get highestModSeq => integer().nullable()();

  IntColumn get totalCount => integer().withDefault(const Constant(0))();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  BoolColumn get isSubscribed => boolean().withDefault(const Constant(true))();
  BoolColumn get isSelectable => boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(100))();

  /// Sunucuda daha eski ileti kaldı mı? (sayfalama sonu göstergesi)
  BoolColumn get hasMoreOnServer =>
      boolean().withDefault(const Constant(true))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {accountId, path},
      ];
}

@DataClassName('MessageRow')
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();
  IntColumn get mailboxId =>
      integer().references(Mailboxes, #id, onDelete: KeyAction.cascade)();

  /// Sunucudaki UID. Yerel (henüz gönderilmemiş) iletilerde `null`.
  IntColumn get uid => integer().nullable()();

  TextColumn get messageIdHeader => text().nullable()();
  TextColumn get inReplyTo => text().nullable()();
  TextColumn get referencesRaw => text().nullable()();

  /// Yerel hesaplanan konuşma kimliği.
  TextColumn get threadId => text().withDefault(const Constant(''))();

  TextColumn get fromName => text().withDefault(const Constant(''))();
  TextColumn get fromEmail => text().withDefault(const Constant(''))();
  TextColumn get toAddrJson => text().withDefault(const Constant('[]'))();
  TextColumn get ccJson => text().withDefault(const Constant('[]'))();
  TextColumn get bccJson => text().withDefault(const Constant('[]'))();

  TextColumn get subject => text().withDefault(const Constant(''))();
  TextColumn get subjectNormalized =>
      text().withDefault(const Constant(''))();
  TextColumn get preview => text().withDefault(const Constant(''))();

  DateTimeColumn get dateUtc => dateTime()();

  BoolColumn get isSeen => boolean().withDefault(const Constant(false))();
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();
  BoolColumn get isAnswered => boolean().withDefault(const Constant(false))();
  BoolColumn get isDraft => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  BoolColumn get hasAttachments =>
      boolean().withDefault(const Constant(false))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  DateTimeColumn get bodyFetchedAt => dateTime().nullable()();
  TextColumn get labelsJson => text().withDefault(const Constant('[]'))();

  /// Sunucuda karşılığı olmayan yerel ileti (taslak / giden kutusu).
  BoolColumn get isLocalOnly => boolean().withDefault(const Constant(false))();
  IntColumn get outboxState =>
      intEnum<OutboxState>().withDefault(const Constant(0))();
  TextColumn get outboxError => text().nullable()();

  /// Yanıt/iletme oluştururken kaynak iletiye bağlanmak için.
  IntColumn get replyToMessageId => integer().nullable()();
}

@DataClassName('MessageBodyRow')
class MessageBodies extends Table {
  IntColumn get messageId =>
      integer().references(Messages, #id, onDelete: KeyAction.cascade)();
  TextColumn get plainText => text().nullable()();
  TextColumn get html => text().nullable()();
  DateTimeColumn get fetchedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {messageId};
}

@DataClassName('AttachmentRow')
class Attachments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get messageId =>
      integer().references(Messages, #id, onDelete: KeyAction.cascade)();

  /// IMAP BODYSTRUCTURE parça yolu (ör. `2.1`).
  TextColumn get partId => text().withDefault(const Constant(''))();
  TextColumn get fileName => text().withDefault(const Constant('dosya'))();
  TextColumn get mimeType =>
      text().withDefault(const Constant('application/octet-stream'))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  TextColumn get contentId => text().nullable()();
  BoolColumn get isInline => boolean().withDefault(const Constant(false))();

  /// İndirildiyse cihazdaki yol.
  TextColumn get localPath => text().nullable()();

  /// Gönderilecek yerel dosya (compose ekranından eklenen).
  BoolColumn get isOutgoing => boolean().withDefault(const Constant(false))();
}

@DataClassName('LabelRow')
class Labels extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  IntColumn get toneIndex => integer().withDefault(const Constant(0))();

  /// Sunucuya yazılıyorsa IMAP anahtar kelimesi.
  TextColumn get imapKeyword => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {accountId, name},
      ];
}

@DataClassName('PendingOperationRow')
class PendingOperations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();
  IntColumn get type => intEnum<PendingOpType>()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get status =>
      intEnum<PendingOpStatus>().withDefault(const Constant(0))();
}

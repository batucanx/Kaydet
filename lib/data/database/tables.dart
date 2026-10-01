import 'package:drift/drift.dart';

import '../../domain/models/mail_models.dart';

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

  /// Kullanılmıyor — [Signatures] tablosu yerini aldı (bkz. v3→v4 göçü).
  /// Sütun eski satırlarla geriye dönük uyumluluk için duruyor, silinmiyor.
  TextColumn get signature => text().nullable()();
  IntColumn get colorSeed => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Sunucu özel anahtar kelime (etiket) destekliyor mu? `null` = bilinmiyor.
  BoolColumn get supportsKeywords => boolean().nullable()();
  TextColumn get capabilitiesJson => text().withDefault(const Constant('[]'))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

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

  /// Klasör Yönetimi ekranının "Sık Kullanılanlar" bölümü — salt yerel bir
  /// tercih, sunucuda karşılığı yoktur ve senkronizasyon bu sütuna asla
  /// dokunmaz (bkz. `AppDatabase.upsertMailbox`).
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  /// Sunucuda daha eski ileti kaldı mı? (sayfalama sonu göstergesi)
  BoolColumn get hasMoreOnServer =>
      boolean().withDefault(const Constant(true))();

  /// Bu klasör için yerelde tutulacak toplam ileti sayısının üst sınırı
  /// (Outlook tarzı önbellek tavanı, bkz. `RetentionPolicy`). Kullanıcı
  /// "daha fazla göster" ile sunucudan daha eskiyi istedikçe büyür (bkz.
  /// `SyncController.loadMore`); aşan iletiler `MailRepository.trimMailbox`
  /// tarafından kademeli olarak temizlenir.
  IntColumn get retentionLimit =>
      integer().withDefault(const Constant(RetentionPolicy.defaultLimit))();

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
  TextColumn get subjectNormalized => text().withDefault(const Constant(''))();
  TextColumn get preview => text().withDefault(const Constant(''))();

  DateTimeColumn get dateUtc => dateTime()();

  BoolColumn get isSeen => boolean().withDefault(const Constant(false))();
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();
  BoolColumn get isAnswered => boolean().withDefault(const Constant(false))();
  BoolColumn get isDraft => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  /// IMAP `$Forwarded` anahtar kelimesi — standart bir bayrak değildir ama
  /// yaygın istemcilerin (Thunderbird, K-9, Gmail) kullandığı fiili ortak
  /// anahtar kelimedir (RFC 5788). `\Answered`'ın aksine sunucu desteği
  /// garanti değildir; bkz. `MailRepository._markSourceMessage`.
  BoolColumn get isForwarded => boolean().withDefault(const Constant(false))();

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
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {messageId};
}

/// İletinin çevirisi. Aynı ileti + kaynak dil + hedef dil için tek kayıt
/// vardır (tekil anahtar) ve çeviri bir kez alınınca çevrimdışı da gösterilir.
/// İleti silinince kayıt da silinir (cascade).
///
/// `translatedHtml`, HTML iletilerde çevrilmiş HTML'dir; yalnızca düz metin
/// iletilerde çevrilmiş düz metindir (hangisi olduğunu iletinin kendi gövdesi
/// belirler).
@DataClassName('TranslatedEmailCacheRow')
class TranslatedEmailCache extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get messageId =>
      integer().references(Messages, #id, onDelete: KeyAction.cascade)();

  /// Kaynak dil kodu; `auto` = sağlayıcı algıladı.
  TextColumn get sourceLanguage => text().withDefault(const Constant('auto'))();
  TextColumn get targetLanguage => text()();
  TextColumn get translatedSubject => text().withDefault(const Constant(''))();
  TextColumn get translatedHtml => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {messageId, sourceLanguage, targetLanguage},
  ];
}

/// İletinin algılanan kaynak dili (bkz. `TranslationRepository.detectLanguage`):
/// aynı ileti her açılışta yeniden algılanmasın (algılama da kota harcar).
/// İleti silinince kayıt da silinir (cascade).
@DataClassName('MessageLanguageRow')
class MessageLanguages extends Table {
  IntColumn get messageId =>
      integer().references(Messages, #id, onDelete: KeyAction.cascade)();

  /// Azure dil kodu (`en`, `de`, `zh-Hans`…).
  TextColumn get language => text()();
  DateTimeColumn get detectedAt => dateTime().withDefault(currentDateAndTime)();

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

/// Bir hesabın imzaları — kullanıcı 1 veya daha fazla imza tanımlayabilir.
/// Yazma ekranı açılışta [isDefault] olanı otomatik ekler; kullanıcı
/// isterse yazarken başka birini seçip ekleyebilir (bkz. `ComposeScreen`).
@DataClassName('SignatureRow')
class Signatures extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get body => text().withDefault(const Constant(''))();

  /// Hesap başına en fazla bir tane olabilir — bkz. kısmi tekil indeks
  /// `idx_signatures_default` (`AppDatabase._createIndexes`).
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// Görsel kaynağı: 'none' | 'local' | 'remote'
  TextColumn get imageType => text().withDefault(const Constant('none'))();

  /// Galeriden seçilen yerel görselin uygulama içindeki saklama yolu.
  TextColumn get localImagePath => text().nullable()();

  /// Uzak görsel URL'si (ör. https://www.hasem.net/imza_silme/murat.png).
  TextColumn get remoteImageUrl => text().nullable()();

  /// Görselin görüntüleme genişliği (px). Varsayılan 200.
  IntColumn get imageWidth => integer().withDefault(const Constant(200))();

  /// Görselin metne göre konumu: 'top' (metnin üstünde) | 'bottom' (metnin altında).
  TextColumn get imagePosition =>
      text().withDefault(const Constant('bottom'))();
}

/// Öğrenilen kişiler — CardDAV değil, tamamen yerel: bir adrese ileti
/// gönderildiğinde veya Gelen Kutusu'na bir adresten ileti geldiğinde
/// otomatik eklenir/güncellenir (bkz. `MailRepository.queueSend`,
/// `SyncEngine._storeEnvelopes`). Yazma ekranındaki Kime/Bilgi/Gizli
/// otomatik tamamlaması ve Kişiler sekmesi bu tabloyu kullanır.
@DataClassName('ContactRow')
class Contacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();

  /// Her zaman küçük harfle saklanır (bkz. `AppDatabase.upsertContact`) —
  /// e-posta karşılaştırması uygulama genelinde büyük/küçük harfe duyarsız
  /// (bkz. `EmailAddress.==`).
  TextColumn get email => text()();
  TextColumn get name => text().withDefault(const Constant(''))();

  /// Otomatik tamamlamada sıralama için: en çok ve en son kullanılan kişi
  /// en üstte çıkar.
  IntColumn get timesUsed => integer().withDefault(const Constant(1))();
  DateTimeColumn get lastUsedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {accountId, email},
  ];
}

@DataClassName('PendingOperationRow')
class PendingOperations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId =>
      integer().references(Accounts, #id, onDelete: KeyAction.cascade)();
  IntColumn get type => intEnum<PendingOpType>()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get status =>
      intEnum<PendingOpStatus>().withDefault(const Constant(0))();
}

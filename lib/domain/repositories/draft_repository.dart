import '../../core/result.dart';

/// Taslak (Draft) verilerinin soyut sözleşmesi.
///
/// UI katmanı doğrudan veri tabanına veya IMAP servisine erişmez; taslak
/// işlemleri bu sözleşme üzerinden Domain ve Data katmanları arasında yürütülür.
abstract interface class DraftRepository {
  /// Taslağı yerel Drift veritabanına anında kaydeder.
  ///
  /// Kullanıcı yazarken veya ekran kapanırken arayüz donmadan derhal yerel
  /// kayıt yapılır (çökme koruması, 0ms latency). Dönen değer yerel satır
  /// kimliğidir (`messageId`).
  Future<int> saveDraftLocal({
    required int accountId,
    int? draftId,
    required String to,
    required String cc,
    required String bcc,
    required String subject,
    required String body,
    String? html,
    List<String> attachmentPaths = const [],
    int? replyToMessageId,
    String? inReplyTo,
    String? references,
  });

  /// Yerel taslağı sunucudaki (IMAP) Taslaklar klasörüyle eşitler.
  ///
  /// - Çevrimiçi ise: Yeni taslağı IMAP Drafts klasörüne `APPEND` eder.
  ///   Sunucuda daha önce oluşturulmuş bir sürümü (`imapUid`) varsa o eski UID'yi
  ///   IMAP'ten siler (`EXPUNGE`). Yerel satırın `uid` bilgisini yeni UID ile günceller
  ///   ve `isLocalOnly = false` yapar.
  /// - Çevrimdışı ise: İşlemi `PendingOperations` kuyruğuna yazar/günceller.
  ///   İnternet bağlantısı sağlandığında otomatik senkronize edilir.
  ///
  /// Her autosave'de veya art arda gelen çağrılarda sunucuda MÜKERRER taslak
  /// oluşmasını engellemek için aynı taslak üzerindeki çağrıları sıraya koyar.
  Future<Result<void>> syncDraftRemote(int draftId);

  /// Taslağı hem yerelden hem de sunucudan kalıcı olarak kaldırır.
  ///
  /// Varsa bekleyen senkronizasyon işlemini iptal eder, sunucuda UID'si varsa
  /// IMAP'ten kalıcı olarak siler ve yerel Drift kaydını temizler.
  Future<void> discardDraft(int draftId);

  /// İleti başarıyla gönderildiğinde (SMTP başarılı), sunucudaki Taslaklar
  /// klasöründe kalan taslak kopyasını kalıcı olarak temizler.
  Future<void> cleanupSentDraft({
    required int accountId,
    required int draftId,
    int? serverUid,
  });

  /// Sunucudan (örneğin Web istemcisinden) gelen ve gövdesi henüz cihazda
  /// olmayan bir taslağın gövdesini ve eklerini IMAP'ten indirir.
  Future<Result<void>> ensureDraftBodyLoaded(int draftId);
}

import '../../core/result.dart';
import '../../domain/use_cases/html_translation.dart';
import '../database/app_database.dart';
import '../services/translation_client.dart';

/// Bir iletinin çevirisi.
class MailTranslation {
  const MailTranslation({
    required this.subject,
    required this.content,
    required this.fromCache,
    this.nearLimit = false,
  });

  final String subject;

  /// HTML iletide çevrilmiş HTML, düz metin iletide çevrilmiş düz metin.
  final String content;

  /// Yerel önbellekten geldi (ağ kullanılmadı).
  final bool fromCache;

  /// Aylık çeviri kullanımı uyarı eşiğine yaklaştı (yalnızca yeni çeviride).
  final bool nearLimit;
}

/// İleti çevirisi — ÖNBELLEK ÖNCELİKLİ.
///
/// Sıra: yerel önbellek → (yoksa) sunucu. Önbellekte çeviri varsa ağa hiç
/// çıkılmaz, bu yüzden çevrimdışıyken de gösterilir ve aynı ileti kaç kez
/// açılırsa açılsın sunucuya (ve Azure'a) tek istek gider. Limit, kullanıcı
/// bazlı kota ve Azure çağrısı SUNUCUDA uygulanır (bkz. `backend/src/
/// translation.ts`); burada yalnızca tipli hatalar iletilir.
///
/// Kural gereği istisna fırlatmaz, her işlem [Result] döner.
class TranslationRepository {
  TranslationRepository({
    required AppDatabase database,
    required TranslationApi? api,
    required Future<String> Function() userId,
  }) : _db = database,
       _api = api,
       _userId = userId;

  final AppDatabase _db;

  /// `null`: sunucu adresi yapılandırılmamış → çeviri kullanılamaz.
  final TranslationApi? _api;
  final Future<String> Function() _userId;

  /// Kaynak dil örneğinin en çok uzunluğu (kod birimi). Sunucu da kırpar;
  /// algılama isteği de kota harcadığından kısa tutulur.
  static const detectSampleChars = 400;

  /// İletinin kaynak dilini döndürür (`en`, `de`…); metin yoksa `Ok(null)`.
  ///
  /// Önce yerel önbellek (aynı ileti bir daha algılanmaz, çevrimdışı da
  /// çalışır), yoksa sunucu. Hata durumunda arayüz düğmeyi yine gösterir; bu
  /// yüzden hata bilgilendirme olarak kullanıcıya iletilmez.
  Future<Result<String?>> detectLanguage({
    required int messageId,
    required String subject,
    required String? html,
    required String? plainText,
  }) async {
    try {
      final cached = await _db.getMessageLanguage(messageId);
      if (cached != null) return Ok(cached);
    } catch (e) {
      return Err(StorageFailure(detail: '$e'));
    }

    final sample = _sample(subject: subject, html: html, plainText: plainText);
    if (sample.isEmpty) return const Ok(null);

    final api = _api;
    if (api == null) {
      return const Err(
        TranslationUnavailableFailure(detail: 'sunucu yapılandırılmamış'),
      );
    }
    final String userId;
    try {
      userId = await _userId();
    } catch (e) {
      return Err(TranslationUnavailableFailure(detail: '$e'));
    }
    final result = await api.detectLanguage(userId: userId, sample: sample);
    final detection = result.valueOrNull;
    if (detection == null) {
      return Err(result.failureOrNull ?? const TranslationUnavailableFailure());
    }
    final language = detection.language;
    if (language != null) {
      try {
        await _db.saveMessageLanguage(messageId, language);
      } catch (_) {
        // Yazılamadıysa bir sonraki açılışta yeniden algılanır.
      }
    }
    return Ok(language);
  }

  /// Algılama örneği: gövdenin ilk metin parçaları (etiketsiz); gövde yoksa
  /// konu. Harf içermiyorsa boş.
  String _sample({
    required String subject,
    required String? html,
    required String? plainText,
  }) {
    final List<String> segments;
    if (html != null && html.trim().isNotEmpty) {
      segments = TranslatableHtml.parse(html).segments;
    } else if (plainText != null && plainText.trim().isNotEmpty) {
      segments = TranslatablePlainText.parse(plainText).segments;
    } else {
      segments = const [];
    }
    final buffer = StringBuffer();
    for (final s in segments) {
      if (buffer.length >= detectSampleChars) break;
      buffer
        ..write(s)
        ..write(' ');
    }
    var text = buffer.toString().trim();
    if (text.isEmpty) text = subject.trim();
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(text)) return '';
    return text.length > detectSampleChars
        ? text.substring(0, detectSampleChars)
        : text;
  }

  Future<Result<MailTranslation>> translate({
    required int messageId,
    required String subject,
    required String? html,
    required String? plainText,
    String sourceLanguage = 'auto',
    String targetLanguage = 'tr',
  }) async {
    final TranslatedEmailCacheRow? cached;
    try {
      cached = await _db.getTranslation(
        messageId: messageId,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );
    } catch (e) {
      return Err(StorageFailure(detail: '$e'));
    }
    if (cached != null) {
      return Ok(
        MailTranslation(
          subject: cached.translatedSubject,
          content: cached.translatedHtml,
          fromCache: true,
        ),
      );
    }

    final api = _api;
    if (api == null) {
      return const Err(
        TranslationUnavailableFailure(detail: 'sunucu yapılandırılmamış'),
      );
    }

    final hasHtml = html != null && html.trim().isNotEmpty;
    final htmlDoc = hasHtml ? TranslatableHtml.parse(html) : null;
    final plainDoc = !hasHtml && plainText != null && plainText.isNotEmpty
        ? TranslatablePlainText.parse(plainText)
        : null;
    final segments = htmlDoc?.segments ?? plainDoc?.segments ?? const [];

    final String userId;
    try {
      userId = await _userId();
    } catch (e) {
      return Err(TranslationUnavailableFailure(detail: '$e'));
    }

    final response = await api.translate(
      TranslationRequest(
        userId: userId,
        messageId: '$messageId',
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        subject: subject,
        segments: segments,
      ),
    );
    final translated = response.valueOrNull;
    if (translated == null) {
      return Err(
        response.failureOrNull ?? const TranslationUnavailableFailure(),
      );
    }

    final String content;
    if (htmlDoc != null) {
      final applied = htmlDoc.apply(translated.segments);
      if (applied == null) {
        return const Err(
          TranslationUnavailableFailure(detail: 'parça sayısı uyuşmuyor'),
        );
      }
      content = applied;
    } else if (plainDoc != null) {
      final applied = plainDoc.apply(translated.segments);
      if (applied == null) {
        return const Err(
          TranslationUnavailableFailure(detail: 'parça sayısı uyuşmuyor'),
        );
      }
      content = applied;
    } else {
      content = '';
    }

    try {
      await _db.saveTranslation(
        messageId: messageId,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        translatedSubject: translated.translatedSubject,
        translatedHtml: content,
      );
    } catch (_) {
      // Önbelleğe yazılamadı: çeviri yine de gösterilir, yalnızca bir sonraki
      // açılışta yeniden istenir.
    }

    return Ok(
      MailTranslation(
        subject: translated.translatedSubject,
        content: content,
        fromCache: false,
        nearLimit: translated.nearLimit,
      ),
    );
  }
}

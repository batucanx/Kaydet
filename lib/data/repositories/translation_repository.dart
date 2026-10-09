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

  Future<Result<MailTranslation>> translate({
    required int messageId,
    required String subject,
    required String? html,
    required String? plainText,
    // Kaynak dil ASLA önceden algılanmaz/örneklenmez: tüm gövde `auto` ile
    // gönderilir, böylece karışık dilli iletiler de eksiksiz çevrilir.
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

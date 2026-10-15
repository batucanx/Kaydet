import 'dart:async';

import '../repositories/draft_repository.dart';

/// Taslak kaydetme ve sunucu senkronizasyonu use case'i.
///
/// UI katmanı doğrudan sunucuya veya veri tabanına istek atmaz; bu use case
/// üzerinden önce yerel veritabanına yazar (anında yanıt ve veri kaybı önleme),
/// ardından arka planda IMAP Taslaklar klasörüyle senkronizasyonu başlatır.
class SaveDraftUseCase {
  const SaveDraftUseCase(this._draftRepository);

  final DraftRepository _draftRepository;

  /// Taslağı yerel Drift veritabanına yazar ve [syncRemote] `true` ise arka
  /// planda sunucu senkronizasyonunu tetikler.
  Future<int> call({
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
    bool syncRemote = true,
  }) async {
    final id = await _draftRepository.saveDraftLocal(
      accountId: accountId,
      draftId: draftId,
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      body: body,
      html: html,
      attachmentPaths: attachmentPaths,
      replyToMessageId: replyToMessageId,
      inReplyTo: inReplyTo,
      references: references,
    );

    if (id > 0 && syncRemote) {
      unawaited(_draftRepository.syncDraftRemote(id));
    }

    return id;
  }
}

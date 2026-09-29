import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/result.dart';
import '../data/repositories/translation_repository.dart';
import '../data/services/push_backend_client.dart' show PushBackendConfig;
import '../data/services/translation_client.dart';
import 'providers.dart';
import 'push_backend_config.dart';

/// Çeviri sunucu üzerinden yapılır (Flutter → Kaydet sunucusu → Azure AI
/// Translator). Azure anahtarı/kimlik bilgisi uygulamada YOKTUR; burada
/// yalnızca sunucunun paylaşılan API anahtarı kullanılır. Sunucu adresi
/// yapılandırılmamışsa `null`: çeviri "kullanılamıyor" der, önbellek çalışır.
final translationApiProvider = Provider<TranslationApi?>((ref) {
  if (PushBackendSecrets.baseUrl.isEmpty || PushBackendSecrets.apiKey.isEmpty) {
    return null;
  }
  final client = HttpTranslationClient(
    const PushBackendConfig(
      baseUrl: PushBackendSecrets.baseUrl,
      apiKey: PushBackendSecrets.apiKey,
    ),
  );
  ref.onDispose(client.close);
  return client;
});

const _userIdKey = 'translation_user_id';

/// Sunucudaki kullanıcı bazlı çeviri kotasının anahtarı: bu kuruluma özel,
/// rastgele, kararlı bir kimlik (hesap e-postası ya da şifre içermez).
/// Uygulamada oturum sistemi olmadığından mevcut kimlik yerine bu kullanılır.
final translationUserIdProvider = Provider<Future<String> Function()>((ref) {
  final prefs = ref.watch(settingsStoreProvider).preferences;
  return () async {
    final existing = prefs.getString(_userIdKey);
    if (existing != null && existing.length >= 8) return existing;
    final random = Random.secure();
    final id = List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    await prefs.setString(_userIdKey, id);
    return id;
  };
});

final translationRepositoryProvider = Provider<TranslationRepository>(
  (ref) => TranslationRepository(
    database: ref.watch(databaseProvider),
    api: ref.watch(translationApiProvider),
    userId: ref.watch(translationUserIdProvider),
  ),
);

/// İletinin kaynak dili (`en`, `de`…). `null`: bilinmiyor (metin yok, çevrimdışı
/// ve önbellekte yok, sunucu yok/limit dolu) — arayüz yine de "Türkçeye Çevir"
/// gösterir, Türkçe olduğu kesin olan iletide ise hiçbir şey göstermez.
///
/// Girdi ORİJİNAL gövdedir; algılama yerelde önbelleklenir. Hata sessizce
/// `null`a düşer (orijinal ileti her durumda okunur kalır). Gövde inene kadar
/// beklenir (gövde yoksa `null`).
final messageLanguageProvider = FutureProvider.autoDispose.family<String?, int>(
  (ref, messageId) async {
    final message = await ref.watch(messageProvider(messageId).future);
    final body = await ref.watch(messageBodyProvider(messageId).future);
    if (message == null || body == null) return null;
    final result = await ref
        .read(translationRepositoryProvider)
        .detectLanguage(
          messageId: messageId,
          subject: message.subject,
          html: body.html,
          plainText: body.plainText,
        );
    return result.valueOrNull;
  },
);

enum TranslationPhase { idle, loading, shown }

class TranslationUiState {
  const TranslationUiState({
    this.phase = TranslationPhase.idle,
    this.translation,
    this.failure,
  });

  final TranslationPhase phase;

  /// [TranslationPhase.shown] iken dolu.
  final MailTranslation? translation;

  /// Son denemenin hatası (kullanıcıya `userMessage` gösterilir).
  final AppFailure? failure;
}

/// Bir iletinin çeviri durumu (ekrandan çıkınca atılır; çeviri zaten
/// önbellekte durur).
class TranslationController extends Notifier<TranslationUiState> {
  TranslationController(this.messageId);

  final int messageId;

  @override
  TranslationUiState build() => const TranslationUiState();

  /// [sourceLanguage]: algılanmışsa dil kodu, bilinmiyorsa `auto`.
  Future<void> translate({
    required String subject,
    required String? html,
    required String? plainText,
    String sourceLanguage = 'auto',
  }) async {
    if (state.phase == TranslationPhase.loading) return;
    state = const TranslationUiState(phase: TranslationPhase.loading);
    final result = await ref
        .read(translationRepositoryProvider)
        .translate(
          messageId: messageId,
          subject: subject,
          html: html,
          plainText: plainText,
          sourceLanguage: sourceLanguage,
        );
    if (!ref.mounted) return;
    state = switch (result) {
      Ok(:final value) => TranslationUiState(
        phase: TranslationPhase.shown,
        translation: value,
      ),
      Err(:final failure) => TranslationUiState(failure: failure),
    };
  }

  void showOriginal() => state = const TranslationUiState();
}

final translationControllerProvider = NotifierProvider.autoDispose
    .family<TranslationController, TranslationUiState, int>(
      TranslationController.new,
    );

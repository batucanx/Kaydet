import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/translation_providers.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/translation_repository.dart';
import 'package:kaydet/data/services/translation_client.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/core/theme/tokens.dart';
import 'package:kaydet/ui/features/mail_detail/translate_bar.dart';

import 'helpers/test_db.dart';

class _Api implements TranslationApi {
  final List<TranslationRequest> calls = [];
  Completer<Result<TranslationResponse>>? gate;
  Result<TranslationResponse>? forced;

  @override
  Future<Result<TranslationResponse>> translate(
    TranslationRequest request,
  ) async {
    calls.add(request);
    final g = gate;
    if (g != null) return g.future;
    return forced ??
        Ok(
          TranslationResponse(
            translatedSubject: 'TR:${request.subject}',
            segments: [for (final s in request.segments) 'TR:$s'],
            cacheHit: false,
            nearLimit: false,
          ),
        );
  }
}

MessageBodyRow _body({String? html = '<p>Hello world</p>', String? plain}) =>
    MessageBodyRow(
      messageId: 1,
      plainText: plain,
      html: html,
      fetchedAt: DateTime(2026, 9, 1),
    );

void main() {
  late AppDatabase db;
  late _Api api;
  late int messageId;

  setUp(() async {
    db = createTestDatabase();
    api = _Api();
    final accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'a@b.com',
        username: 'a@b.com',
        imapHost: 'imap.b.com',
        smtpHost: 'smtp.b.com',
      ),
    );
    final inboxId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen Kutusu',
        specialUse: const Value(SpecialUse.inbox),
      ),
    );
    await db.upsertServerMessages([
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: inboxId,
        dateUtc: DateTime.utc(2026, 9, 14),
        uid: const Value(1),
        subject: const Value('Your order has been shipped'),
      ),
    ]);
    messageId = (await db.messageByUid(inboxId, 1))!.id;
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pumpBar(
    WidgetTester tester, {
    MessageBodyRow? body,
    Brightness brightness = Brightness.light,
  }) async {
    final repo = TranslationRepository(
      database: db,
      api: api,
      userId: () async => 'user-000001',
    );
    final container = ProviderContainer(
      overrides: [translationRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          home: Scaffold(
            body: TranslateBar(
              messageId: messageId,
              body: body ?? _body(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  /// Çeviriyi, "..." menüsündeki öğenin yaptığı gibi denetleyiciden başlatır
  /// (çubuğun kendisinde başlatma düğmesi yoktur).
  void startTranslation(ProviderContainer container, {MessageBodyRow? body}) {
    final b = body ?? _body();
    unawaited(
      container
          .read(translationControllerProvider(messageId).notifier)
          .translate(
            subject: 'Your order has been shipped',
            html: b.html,
            plainText: b.plainText,
          ),
    );
  }

  /// Gerçek async (sqlite) işlemlerin tamamlanması için.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }

  testWidgets('açılışta ağ isteği yok; çubukta başlatma düğmesi yok', (
    tester,
  ) async {
    await pumpBar(tester);
    await settle(tester);
    expect(find.text('Türkçeye Çevir'), findsNothing);
    expect(find.text('Orijinali göster'), findsNothing);
    expect(api.calls, isEmpty);
  });

  testWidgets('çeviri başlatılınca gövdenin TAMAMI auto kaynakla gönderilir', (
    tester,
  ) async {
    final html =
        '<p>${List.generate(300, (i) => 'Sentence number $i here.').join('</p><p>')}</p>';
    final body = _body(html: html);
    final container = await pumpBar(tester, body: body);
    startTranslation(container, body: body);
    await settle(tester);
    expect(api.calls, hasLength(1));
    expect(api.calls.single.sourceLanguage, 'auto');
    expect(api.calls.single.segments, hasLength(300));
    expect(api.calls.single.segments.last, 'Sentence number 299 here.');
  });

  testWidgets('gövde metni yoksa hiçbir şey gösterilmez', (tester) async {
    await pumpBar(tester, body: _body(html: null, plain: null));
    expect(find.text('Türkçeye Çevir'), findsNothing);
    expect(find.text('Orijinali göster'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} temada bağlantı rengi tema belirtecinden', (
      tester,
    ) async {
      final container = await pumpBar(tester, brightness: brightness);
      startTranslation(container);
      await settle(tester);
      final tokens = brightness == Brightness.dark
          ? KaydetTokens.dark
          : KaydetTokens.light;
      final text = tester.widget<Text>(find.text('Orijinali göster'));
      expect(text.style?.color, tokens.accent);
    });
  }

  testWidgets('Orijinal → Türkçe → Orijinal: geri dönüş ağa çıkmaz', (
    tester,
  ) async {
    final container = await pumpBar(tester);

    startTranslation(container);
    await settle(tester);
    expect(api.calls, hasLength(1));
    expect(api.calls.single.sourceLanguage, 'auto');
    expect(find.textContaining('Türkçe gösteriliyor'), findsOneWidget);

    await tester.tap(find.text('Orijinali göster'));
    await tester.pump();
    expect(find.textContaining('Türkçe gösteriliyor'), findsNothing);
    expect(api.calls, hasLength(1));

    // Aynı ileti tekrar çevrilir: yerel önbellek, ağ yok.
    startTranslation(container);
    await settle(tester);
    expect(find.textContaining('Türkçe gösteriliyor'), findsOneWidget);
    expect(api.calls, hasLength(1));
  });

  testWidgets('çeviri sürerken "Çevriliyor..." gösterilir', (tester) async {
    final gate = Completer<Result<TranslationResponse>>();
    api.gate = gate;
    final container = await pumpBar(tester);
    startTranslation(container);
    await settle(tester);
    expect(find.text('Çevriliyor...'), findsOneWidget);
    expect(find.text('Türkçeye Çevir'), findsNothing);

    gate.complete(
      const Ok(
        TranslationResponse(
          translatedSubject: 'Siparişiniz gönderildi',
          segments: ['Merhaba dünya'],
          cacheHit: false,
          nearLimit: false,
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('Türkçe gösteriliyor'), findsOneWidget);
  });

  Future<void> expectFailureNotice(
    WidgetTester tester,
    AppFailure failure,
    String message,
  ) async {
    api.forced = Err(failure);
    final container = await pumpBar(tester);
    startTranslation(container);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(message), findsOneWidget);
    // Hata sonrası çubuk boşa döner; orijinal ekranda kalır ve menüden
    // yeniden denenebilir.
    expect(find.textContaining('Türkçe gösteriliyor'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('çevrimdışı + önbellek yok: bilgi mesajı, orijinal kalır', (
    tester,
  ) async {
    await expectFailureNotice(
      tester,
      const TranslationNetworkFailure(),
      'Çeviri için internet bağlantısı gerekiyor.',
    );
  });

  testWidgets('API 429 / aylık limit: kullanım limiti mesajı', (tester) async {
    await expectFailureNotice(
      tester,
      const TranslationMonthlyLimitFailure(),
      'Bu ay için çeviri kullanım limitine ulaşıldı.',
    );
  });

  testWidgets('sağlayıcı zaman aşımı/hata: "kullanılamıyor" mesajı', (
    tester,
  ) async {
    await expectFailureNotice(
      tester,
      const TranslationUnavailableFailure(),
      'Çeviri şu anda kullanılamıyor.',
    );
  });
}

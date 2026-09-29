import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/translation_repository.dart';
import 'package:kaydet/data/services/push_backend_client.dart'
    show PushBackendConfig;
import 'package:kaydet/data/services/translation_client.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/html_translation.dart';
import 'package:kaydet/domain/use_cases/language_names.dart';

import 'helpers/test_db.dart';

class _FakeApi implements TranslationApi {
  final List<TranslationRequest> calls = [];
  Result<TranslationResponse>? forced;

  final List<String> detectSamples = [];
  Result<LanguageDetection> detection = const Ok(
    LanguageDetection(language: 'en', nearLimit: false),
  );

  @override
  Future<Result<LanguageDetection>> detectLanguage({
    required String userId,
    required String sample,
  }) async {
    detectSamples.add(sample);
    return detection;
  }

  @override
  Future<Result<TranslationResponse>> translate(
    TranslationRequest request,
  ) async {
    calls.add(request);
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

const _html =
    '<html><head><style>.a{color:red}</style></head><body>'
    '<div class="box" style="color:#123456">'
    '<p>Hello</p>'
    '<a href="https://example.com/x?y=1" class="btn">Click here</a>'
    '<img src="cid:logo@x" alt="">'
    '<span> 12:30 </span>'
    '<script>var t = "do not translate";</script>'
    '</div></body></html>';

void main() {
  group('TranslatableHtml', () {
    test('yalnızca harf içeren metin düğümlerini çıkarır', () {
      final doc = TranslatableHtml.parse(_html);
      expect(doc.segments, ['Hello', 'Click here']);
      expect(doc.characterCount, 'Hello'.length + 'Click here'.length);
    });

    test('href, src, css, class ve yapı korunur; metinler çevrilir', () {
      final doc = TranslatableHtml.parse(_html);
      final out = doc.apply(['Merhaba', 'Buraya tıkla'])!;
      expect(out, contains('href="https://example.com/x?y=1"'));
      expect(out, contains('src="cid:logo@x"'));
      expect(out, contains('style="color:#123456"'));
      expect(out, contains('.a{color:red}'));
      expect(out, contains('class="box"'));
      expect(out, contains('class="btn"'));
      expect(out, contains('do not translate'));
      expect(out, contains('<p>Merhaba</p>'));
      expect(out, contains('>Buraya tıkla</a>'));
      expect(out, isNot(contains('Hello')));
      expect(out.indexOf('<p>'), lessThan(out.indexOf('<a ')));
    });

    test('baştaki/sondaki boşluk korunur, iç boşluklar sıkıştırılır', () {
      final doc = TranslatableHtml.parse('<p>  Hello \n   world  </p>');
      expect(doc.segments, ['Hello world']);
      expect(doc.apply(['Selam dünya']), contains('<p>  Selam dünya  </p>'));
    });

    test('parça sayısı uyuşmazsa uygulanmaz', () {
      expect(TranslatableHtml.parse(_html).apply(['tek']), isNull);
    });

    test('çevrilecek metin yoksa boş', () {
      expect(TranslatableHtml.parse('<p>123 — 45</p>').isEmpty, isTrue);
    });

    test('uzun bülten: tüm görünür metinler sırayla çıkar ve geri yerleşir', () {
      final paragraphs = [for (var i = 0; i < 300; i++) 'Paragraph number $i'];
      final html =
          '<body>${paragraphs.map((p) => '<p class="c">$p <b>bold</b></p>').join()}</body>';
      final doc = TranslatableHtml.parse(html);
      expect(doc.segments, hasLength(600));
      final out = doc.apply([for (final s in doc.segments) 'TR $s'])!;
      expect(
        out,
        contains('<p class="c">TR Paragraph number 0 <b>TR bold</b></p>'),
      );
      expect(out, contains('TR Paragraph number 299'));
    });

    test(
      'tablo: hücre, başlık, başlık satırı metinleri çevrilir; yapı kalır',
      () {
        const html =
            '<table border="0" width="100%"><caption>Order summary</caption>'
            '<thead><tr><th>Item</th><th>Price</th></tr></thead>'
            '<tbody><tr><td class="x">Shoes</td><td>\$40</td></tr></tbody></table>';
        final doc = TranslatableHtml.parse(html);
        expect(doc.segments, ['Order summary', 'Item', 'Price', 'Shoes']);
        final out = doc.apply(['A', 'B', 'C', 'D'])!;
        expect(out, contains('<caption>A</caption>'));
        expect(out, contains('<th>B</th><th>C</th>'));
        expect(out, contains('<td class="x">D</td><td>\$40</td>'));
        expect(out, contains('width="100%"'));
      },
    );

    test('buton ve bağlantı görünen yazıları çevrilir, öznitelikler kalır', () {
      const html =
          '<a href="https://t.example.com/track?id=9&amp;u=1" style="color:#fff" '
          'id="cta" data-x="1">Verify your email</a>'
          '<button type="submit" class="b" onclick="x()">Confirm</button>';
      final doc = TranslatableHtml.parse(html);
      expect(doc.segments, ['Verify your email', 'Confirm']);
      final out = doc.apply(['E-postanı doğrula', 'Onayla'])!;
      expect(out, contains('href="https://t.example.com/track?id=9&amp;u=1"'));
      expect(out, contains('style="color:#fff"'));
      expect(out, contains('id="cta"'));
      expect(out, contains('data-x="1"'));
      expect(out, contains('onclick="x()"'));
      expect(out, contains('>E-postanı doğrula</a>'));
      expect(out, contains('>Onayla</button>'));
    });

    test('görsel: src/alt/boyut aynen kalır, görsel metni çevrilmez', () {
      const html =
          '<p>Look</p><img src="https://cdn.example.com/a.png?x=1" alt="Logo" '
          'width="120" height="40" style="display:block">';
      final doc = TranslatableHtml.parse(html);
      expect(doc.segments, ['Look']);
      final out = doc.apply(['Bak'])!;
      expect(out, contains('src="https://cdn.example.com/a.png?x=1"'));
      expect(out, contains('alt="Logo"'));
      expect(out, contains('width="120"'));
    });

    test('HTML imza ve alıntı çevrilir', () {
      const html =
          '<div>Best regards,<br><b>John Smith</b><br><small>Sent from my phone</small></div>'
          '<blockquote>Thanks for your help</blockquote><footer>Unsubscribe here</footer>';
      final doc = TranslatableHtml.parse(html);
      expect(doc.segments, [
        'Best regards,',
        'John Smith',
        'Sent from my phone',
        'Thanks for your help',
        'Unsubscribe here',
      ]);
      expect(doc.apply(List.filled(5, 'X')), contains('<b>X</b>'));
    });

    test('çok parçalı metin düğümleri: her parça yerinde kalır', () {
      final doc = TranslatableHtml.parse(
        '<p>Hello <b>John</b>, welcome <i>back</i>!</p>',
      );
      expect(doc.segments, ['Hello', 'John', ', welcome', 'back']);
      final out = doc.apply([
        'Merhaba',
        'John',
        ', tekrar hoş geldin',
        'geri',
      ])!;
      expect(
        out,
        contains('<p>Merhaba <b>John</b>, tekrar hoş geldin <i>geri</i>!</p>'),
      );
    });

    test('bozuk HTML: çökmez, yapı onarılır, metin çevrilir', () {
      final doc = TranslatableHtml.parse(
        '<div><p>Unclosed <b>bold text<div>Second block</span></p>',
      );
      expect(
        doc.segments,
        containsAll(['Unclosed', 'bold text', 'Second block']),
      );
      final out = doc.apply([for (final _ in doc.segments) 'Ç'])!;
      expect(out, isNot(contains('Second block')));
      expect(out, contains('Ç'));
    });

    test('boş HTML: çevrilecek parça yok, çökmez', () {
      for (final html in ['', '   ', '<html></html>', '<div></div>']) {
        final doc = TranslatableHtml.parse(html);
        expect(doc.isEmpty, isTrue, reason: html);
        expect(doc.apply(const []), isNotNull);
      }
    });

    test('bilgilendirme (dil adları)', () {
      expect(languageDisplayName('en'), 'İngilizce');
      expect(languageDisplayName('zh-Hans'), 'Çince');
      expect(languageDisplayName('xx'), isNull);
      expect(isTurkish('tr'), isTrue);
      expect(isTurkish('en'), isFalse);
      expect(isTurkish(null), isFalse);
    });

    test('düz metin: satır yapısı ve girinti korunur', () {
      final doc = TranslatablePlainText.parse('Hello\n\n  Bye\n42');
      expect(doc.segments, ['Hello', 'Bye']);
      expect(doc.apply(['Merhaba', 'Hoşça kal']), 'Merhaba\n\n  Hoşça kal\n42');
    });
  });

  group('TranslationRepository', () {
    late AppDatabase db;
    late _FakeApi api;
    late TranslationRepository repo;
    late int accountId;
    late int inboxId;

    Future<int> insertMessage(int uid) async {
      await db.upsertServerMessages([
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          uid: Value(uid),
          subject: Value('Konu $uid'),
        ),
      ]);
      return (await db.messageByUid(inboxId, uid))!.id;
    }

    Future<Result<MailTranslation>> translate(
      int id, {
      String target = 'tr',
      String? html = _html,
      String? plain,
    }) => repo.translate(
      messageId: id,
      subject: 'Hello subject',
      html: html,
      plainText: plain,
      targetLanguage: target,
    );

    setUp(() async {
      db = createTestDatabase();
      api = _FakeApi();
      repo = TranslationRepository(
        database: db,
        api: api,
        userId: () async => 'user-000001',
      );
      accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'a@b.com',
          username: 'a@b.com',
          imapHost: 'imap.b.com',
          smtpHost: 'smtp.b.com',
        ),
      );
      inboxId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX',
          name: 'Gelen Kutusu',
          specialUse: const Value(SpecialUse.inbox),
        ),
      );
    });

    tearDown(() => db.close());

    test(
      'konu ve gövde çevrilir; istek yalnızca metin parçalarını taşır',
      () async {
        final id = await insertMessage(1);
        final result = (await translate(id)).valueOrNull!;
        expect(result.subject, 'TR:Hello subject');
        expect(result.content, contains('TR:Hello'));
        expect(result.content, contains('href="https://example.com/x?y=1"'));
        expect(api.calls.single.segments, ['Hello', 'Click here']);
        expect(api.calls.single.subject, 'Hello subject');
      },
    );

    test('aynı ileti ikinci kez çevrilirse API çağrılmaz', () async {
      final id = await insertMessage(1);
      await translate(id);
      final second = (await translate(id)).valueOrNull!;
      expect(api.calls, hasLength(1));
      expect(second.fromCache, isTrue);
      expect(second.subject, 'TR:Hello subject');
    });

    test('farklı hedef dil için yeni çeviri yapılır', () async {
      final id = await insertMessage(1);
      await translate(id);
      await translate(id, target: 'de');
      expect(api.calls, hasLength(2));
    });

    test('farklı ileti için yeni çeviri yapılır', () async {
      await translate(await insertMessage(1));
      await translate(await insertMessage(2));
      expect(api.calls, hasLength(2));
    });

    test('çevrimdışıyken önbellekteki çeviri gösterilir', () async {
      final id = await insertMessage(1);
      await translate(id);
      api.forced = const Err(TranslationNetworkFailure());
      final offline = await translate(id);
      expect(offline.isOk, isTrue);
      expect(offline.valueOrNull!.fromCache, isTrue);
    });

    test('önbellekte yokken internet yoksa tipli hata döner', () async {
      api.forced = const Err(TranslationNetworkFailure());
      final result = await translate(await insertMessage(1));
      expect(result.failureOrNull, isA<TranslationNetworkFailure>());
      expect(
        result.failureOrNull!.userMessage,
        'Çeviri için internet bağlantısı gerekiyor.',
      );
    });

    test('limit hataları tipli döner ve önbelleğe yazılmaz', () async {
      final id = await insertMessage(1);
      api.forced = const Err(TranslationMonthlyLimitFailure());
      expect(
        (await translate(id)).failureOrNull,
        isA<TranslationMonthlyLimitFailure>(),
      );
      api.forced = const Err(TranslationUserLimitFailure());
      expect(
        (await translate(id)).failureOrNull,
        isA<TranslationUserLimitFailure>(),
      );
      expect(
        await db.getTranslation(
          messageId: id,
          sourceLanguage: 'auto',
          targetLanguage: 'tr',
        ),
        isNull,
      );
    });

    test('sunucu yapılandırılmamışsa çökmez, kullanılamıyor der', () async {
      final noApi = TranslationRepository(
        database: db,
        api: null,
        userId: () async => 'user-000001',
      );
      final result = await noApi.translate(
        messageId: await insertMessage(1),
        subject: 's',
        html: _html,
        plainText: null,
      );
      expect(result.failureOrNull, isA<TranslationUnavailableFailure>());
      expect(
        result.failureOrNull!.userMessage,
        'Çeviri şu anda kullanılamıyor.',
      );
    });

    test('düz metin ileti çevrilir', () async {
      final id = await insertMessage(1);
      final result = (await translate(
        id,
        html: null,
        plain: 'Hello\nBye',
      )).valueOrNull!;
      expect(result.content, 'TR:Hello\nTR:Bye');
    });

    for (final lang in ['en', 'de', 'fr', 'es', 'tr']) {
      test('$lang dilindeki ileti algılanır ve önbelleklenir', () async {
        api.detection = Ok(LanguageDetection(language: lang, nearLimit: false));
        final id = await insertMessage(1);
        Future<Result<String?>> detect() => repo.detectLanguage(
          messageId: id,
          subject: 'Konu',
          html: _html,
          plainText: null,
        );
        expect((await detect()).valueOrNull, lang);
        expect((await detect()).valueOrNull, lang);
        // İkinci açılış yerelden: sunucuya (kota harcayan) tek istek gider.
        expect(api.detectSamples, hasLength(1));
        // Örnek yalnızca görünür metindir, etiket/CSS/URL içermez.
        expect(api.detectSamples.single, 'Hello Click here');
        expect(isTurkish(lang), lang == 'tr');
      });
    }

    test(
      'algılama: çevrimdışı ve önbellekte yoksa hata döner, çökmez',
      () async {
        api.detection = const Err(TranslationNetworkFailure());
        final result = await repo.detectLanguage(
          messageId: await insertMessage(1),
          subject: 's',
          html: _html,
          plainText: null,
        );
        expect(result.failureOrNull, isA<TranslationNetworkFailure>());
      },
    );

    test('algılama: harf içermeyen/boş içerik sunucuya gitmez', () async {
      final id = await insertMessage(1);
      final result = await repo.detectLanguage(
        messageId: id,
        subject: '123',
        html: '<p>12 — 34</p>',
        plainText: null,
      );
      expect(result.valueOrNull, isNull);
      expect(result.isOk, isTrue);
      expect(api.detectSamples, isEmpty);
    });

    test('iletilen ileti: Türkçe başlık satırları örneğe girmez', () async {
      final id = await insertMessage(1);
      await repo.detectLanguage(
        messageId: id,
        subject: 'FWD: Complete your Adobe account',
        html:
            '<div><b>Gönderen:</b> "Adobe" &lt;noreply@adobe.com&gt;<br>'
            '<b>Gönderilmiş:</b> 29.09.2026 10:01<br><b>Alıcı:</b> a@b.com<br>'
            '<b>Konu:</b> Complete your Adobe account</div>'
            '<p>You recently created an Adobe account using a@b.com.</p>'
            '<p>To get the most out of your Adobe products and services, '
            'please take a moment to complete your account details.</p>',
        plainText: null,
      );
      final sample = api.detectSamples.single;
      expect(sample, startsWith('You recently created'));
      expect(sample, isNot(contains('Gönderen')));
      expect(sample, isNot(contains('Alıcı')));
    });

    test('algılama örneği en çok 400 karakterdir', () async {
      final id = await insertMessage(1);
      await repo.detectLanguage(
        messageId: id,
        subject: 's',
        html: '<p>${'word ' * 500}</p>',
        plainText: null,
      );
      expect(api.detectSamples.single.length, lessThanOrEqualTo(400));
    });

    test('algılanan kaynak dil isteğe ve önbellek anahtarına girer', () async {
      final id = await insertMessage(1);
      await repo.translate(
        messageId: id,
        subject: 's',
        html: _html,
        plainText: null,
        sourceLanguage: 'de',
      );
      expect(api.calls.single.sourceLanguage, 'de');
      // Aynı ileti, farklı kaynak dil → ayrı kayıt (unique anahtar 3'lü).
      await repo.translate(
        messageId: id,
        subject: 's',
        html: _html,
        plainText: null,
      );
      expect(api.calls, hasLength(2));
      expect(await db.select(db.translatedEmailCache).get(), hasLength(2));
    });

    test('çeviri başarısız olsa da orijinal içerik değişmez', () async {
      api.forced = const Err(TranslationUnavailableFailure());
      final original = _html;
      final result = await translate(await insertMessage(1), html: original);
      expect(result.isErr, isTrue);
      // Repository orijinali değiştirmez/tüketmez; gösterim orijinalde kalır.
      expect(original, _html);
    });

    test('boş iletide çökmez; yalnızca konu çevrilir', () async {
      final id = await insertMessage(1);
      final result = (await translate(id, html: '', plain: '')).valueOrNull!;
      expect(result.subject, 'TR:Hello subject');
      expect(result.content, '');
      expect(api.calls.single.segments, isEmpty);
    });

    test('aynı anahtar için yinelenen kayıt oluşmaz', () async {
      final id = await insertMessage(1);
      for (final subject in ['a', 'b']) {
        await db.saveTranslation(
          messageId: id,
          sourceLanguage: 'auto',
          targetLanguage: 'tr',
          translatedSubject: subject,
          translatedHtml: '<p>$subject</p>',
        );
      }
      final rows = await db.select(db.translatedEmailCache).get();
      expect(rows, hasLength(1));
      expect(rows.single.translatedSubject, 'b');
    });
  });

  group('HttpTranslationClient', () {
    late HttpServer server;
    late HttpTranslationClient client;
    int status = 200;
    Object? body;
    Map<String, dynamic>? received;
    String? authHeader;

    Duration delay = Duration.zero;

    setUp(() async {
      status = 200;
      delay = Duration.zero;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        authHeader = request.headers.value(HttpHeaders.authorizationHeader);
        received =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        try {
          request.response
            ..statusCode = status
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(body));
          await request.response.close();
        } on Object {
          // İstemci zaman aşımıyla bağlantıyı kapattıysa sunucu yazamaz.
        }
      });
      client = HttpTranslationClient(
        PushBackendConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'key',
        ),
      );
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    const request = TranslationRequest(
      userId: 'user-000001',
      messageId: '1',
      sourceLanguage: 'auto',
      targetLanguage: 'tr',
      subject: 'Hi',
      segments: ['Hello'],
    );

    test('başarılı yanıt tipli sonuca çevrilir', () async {
      body = {
        'translatedSubject': 'Selam',
        'segments': ['Merhaba'],
        'cacheHit': true,
        'nearLimit': true,
      };
      final r = (await client.translate(request)).valueOrNull!;
      expect(r.translatedSubject, 'Selam');
      expect(r.segments, ['Merhaba']);
      expect(r.cacheHit, isTrue);
      expect(r.nearLimit, isTrue);
      expect(authHeader, 'Bearer key');
      expect(received!['segments'], ['Hello']);
    });

    test('429 iş hatası kodları tipli hatalara eşlenir', () async {
      status = 429;
      body = {'error': 'TRANSLATION_MONTHLY_LIMIT_REACHED'};
      expect(
        (await client.translate(request)).failureOrNull,
        isA<TranslationMonthlyLimitFailure>(),
      );
      body = {'error': 'TRANSLATION_USER_LIMIT_REACHED'};
      expect(
        (await client.translate(request)).failureOrNull,
        isA<TranslationUserLimitFailure>(),
      );
    });

    test('503 ve bozuk yanıt kullanılamıyor hatasıdır', () async {
      status = 503;
      body = {'error': 'TRANSLATION_UNAVAILABLE'};
      expect(
        (await client.translate(request)).failureOrNull,
        isA<TranslationUnavailableFailure>(),
      );
      status = 200;
      body = {'translatedSubject': 'x', 'segments': []};
      expect(
        (await client.translate(request)).failureOrNull,
        isA<TranslationUnavailableFailure>(),
      );
    });

    test('dil algılama yanıtı tipli sonuca çevrilir', () async {
      body = {'language': 'de', 'score': 0.9, 'nearLimit': false};
      final r = (await client.detectLanguage(
        userId: 'user-000001',
        sample: 'Hallo Welt',
      )).valueOrNull!;
      expect(r.language, 'de');
      expect(received!['sample'], 'Hallo Welt');
      body = {'language': null, 'score': 0, 'nearLimit': false};
      final none = (await client.detectLanguage(
        userId: 'user-000001',
        sample: 'x',
      )).valueOrNull!;
      expect(none.language, isNull);
    });

    test('dil algılamada limit dolu → tipli hata', () async {
      status = 429;
      body = {'error': 'TRANSLATION_MONTHLY_LIMIT_REACHED'};
      final r = await client.detectLanguage(userId: 'user-000001', sample: 'x');
      expect(r.failureOrNull, isA<TranslationMonthlyLimitFailure>());
      expect(
        r.failureOrNull!.userMessage,
        'Bu ay için çeviri kullanım limitine ulaşıldı.',
      );
    });

    test('yanıt zaman aşımına uğrarsa ağ hatası döner', () async {
      final slow = HttpTranslationClient(
        PushBackendConfig(
          baseUrl: 'http://127.0.0.1:${server.port}',
          apiKey: 'key',
        ),
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(slow.close);
      delay = const Duration(milliseconds: 600);
      body = {
        'translatedSubject': 'x',
        'segments': ['y'],
      };
      expect(
        (await slow.translate(request)).failureOrNull,
        isA<TranslationNetworkFailure>(),
      );
    });

    test('bağlantı yoksa ağ hatası döner, istisna fırlatmaz', () async {
      await server.close(force: true);
      expect(
        (await client.translate(request)).failureOrNull,
        isA<TranslationNetworkFailure>(),
      );
    });
  });
}

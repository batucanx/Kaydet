@Timeout(Duration(seconds: 120))
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart' show Delta;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/app.dart';
import 'package:kaydet/app/navigation.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/use_cases/email_html_codec.dart';
import 'package:kaydet/ui/features/compose/compose_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Yazma ekranındaki biçimlendirme akışı — gerçek `ComposeScreen`, gerçek
/// araç çubuğu dokunuşları.
///
/// Kök neden regresyonu: eski kod `Attribute.size`a `'18px'` yazıyordu;
/// `flutter_quill` bunu okuyamayıp `TextLine` çizimi sırasında fırlatıyor ve
/// editörün tamamı boş bir `ErrorWidget`'a dönüşüyordu. Bu testler aynı
/// yolu (Normal → Büyük → Çok büyük → …) arayüzden yürütür ve hiçbir
/// istisna/ErrorWidget çıkmadığını denetler.
void appTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    // Gerçek bir telefon ekranı: taşma/kaydırma davranışı bunun üzerinden
    // sınanır.
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await body(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}

void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late SecureStore secureStore;
  late AppSettingsStore settingsStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    secureStore = InMemorySecureStore();
    settingsStore = await AppSettingsStore.create();
  });

  tearDown(() async {
    await imap.dispose();
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Uygulamayı açar; hesap sahtedir, ağ katmanı taklittir. Hesap kimliğini
  /// döndürür.
  Future<int> pumpApp(WidgetTester tester) async {
    final id = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
        displayName: const Value('Pazarlık'),
      ),
    );
    await secureStore.writePassword(id, 'sifre');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(secureStore),
          imapServiceProvider.overrideWithValue(imap),
          smtpServiceProvider.overrideWithValue(smtp),
          settingsStoreProvider.overrideWithValue(settingsStore),
        ],
        child: const KaydetApp(),
      ),
    );
    await settle(tester);
    return id;
  }

  /// Yazma ekranını açar, biçim çubuğunu gösterir ve editörün denetleyicisini
  /// döndürür.
  Future<QuillController> openCompose(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Yeni ileti'));
    await settle(tester);
    await tester.tap(find.byTooltip('Biçimlendir'));
    await settle(tester);
    return tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
  }

  /// Menü düğmesine dokunup seçeneği seçer — gerçek kullanıcı yolu.
  Future<void> choose(WidgetTester tester, String button, String option) async {
    await tester.tap(find.bySemanticsLabel(button));
    await settle(tester);
    await tester.tap(find.text(option).last);
    await settle(tester);
  }

  void select(QuillController controller, int start, int end) {
    controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      ChangeSource.local,
    );
  }

  /// Editörün çizdiği TÜM yazı boyutları (px). Çizim ağacından okunur; böylece
  /// belge modeli değil, ekranda görünen doğrulanır.
  List<double> renderedFontSizes(WidgetTester tester) {
    final sizes = <double>[];
    void visit(InlineSpan span, double? inherited) {
      if (span is TextSpan) {
        final size = span.style?.fontSize ?? inherited;
        if (span.text != null && span.text!.trim().isNotEmpty && size != null) {
          sizes.add(size);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, size);
        }
      }
    }

    for (final rich in tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(QuillEditor),
        matching: find.byType(RichText),
      ),
    )) {
      visit(rich.text, null);
    }
    return sizes;
  }

  void expectHealthy(WidgetTester tester) {
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    // Editör görünür alanın dışına taşmaz.
    final rect = tester.getRect(find.byType(QuillEditor));
    expect(rect.width, lessThanOrEqualTo(390));
    expect(rect.width, greaterThan(100));
  }

  Object? sizeAttr(QuillController c, int offset) =>
      c.document.collectStyle(offset, 1).attributes['size']?.value;

  group('yazı boyutu', () {
    appTest('Normal → Büyük → Çok büyük → Çok büyük → Normal', (tester) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'Merhaba dünya',
        const TextSelection.collapsed(offset: 13),
      );
      await tester.pump();
      final editorState = tester.state(find.byType(QuillEditor));

      select(controller, 0, 13);
      await tester.pump();
      expect(renderedFontSizes(tester), everyElement(16));

      await choose(tester, 'Yazı boyutu', 'Büyük');
      expectHealthy(tester);
      expect(sizeAttr(controller, 0), '20');
      expect(renderedFontSizes(tester), everyElement(20));

      await choose(tester, 'Yazı boyutu', 'Çok büyük');
      expectHealthy(tester);
      expect(sizeAttr(controller, 0), '24');
      expect(renderedFontSizes(tester), everyElement(24));

      // Aynı seviyeyi yeniden seçmek zararsızdır.
      await choose(tester, 'Yazı boyutu', 'Çok büyük');
      expectHealthy(tester);
      expect(renderedFontSizes(tester), everyElement(24));

      await choose(tester, 'Yazı boyutu', 'Normal');
      expectHealthy(tester);
      expect(sizeAttr(controller, 0), isNull);
      expect(renderedFontSizes(tester), everyElement(16));

      // Biçimlendirme sırasında editör yeniden YARATILMADI.
      expect(
        identical(tester.state(find.byType(QuillEditor)), editorState),
        isTrue,
      );
    });

    appTest('Normal → Çok büyük → Normal ve Küçük', (tester) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'Deneme',
        const TextSelection.collapsed(offset: 6),
      );
      select(controller, 0, 6);
      await tester.pump();

      await choose(tester, 'Yazı boyutu', 'Çok büyük');
      expectHealthy(tester);
      await choose(tester, 'Yazı boyutu', 'Normal');
      expectHealthy(tester);
      await choose(tester, 'Yazı boyutu', 'Küçük');
      expectHealthy(tester);
      expect(sizeAttr(controller, 0), '13');
      expect(renderedFontSizes(tester), everyElement(13));
    });

    appTest('boyut yalnızca seçili metni etkiler, ekranı ölçeklemez', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'ilk ikinci son',
        const TextSelection.collapsed(offset: 14),
      );
      select(controller, 4, 10); // "ikinci"
      await tester.pump();

      final appBarBefore = tester.getSize(find.byType(AppBar));
      final toolbarBefore = tester.getSize(
        find.bySemanticsLabel('Yazı boyutu'),
      );

      await choose(tester, 'Yazı boyutu', 'Çok büyük');
      expectHealthy(tester);

      expect(sizeAttr(controller, 0), isNull);
      expect(sizeAttr(controller, 4), '24');
      expect(sizeAttr(controller, 12), isNull);
      // Editörde hem 16 hem 24 vardır; başka hiçbir arayüz öğesi değişmez.
      expect(renderedFontSizes(tester).toSet(), {16.0, 24.0});
      expect(tester.getSize(find.byType(AppBar)), appBarBefore);
      expect(
        tester.getSize(find.bySemanticsLabel('Yazı boyutu')),
        toolbarBefore,
      );
    });

    appTest('imleç boşken seçilen boyut sonradan yazılan metne uygulanır', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'a',
        const TextSelection.collapsed(offset: 1),
      );
      await tester.pump();

      await choose(tester, 'Yazı boyutu', 'Büyük');
      expectHealthy(tester);

      controller.replaceText(
        1,
        0,
        'bcd',
        const TextSelection.collapsed(offset: 4),
      );
      await tester.pump();
      expectHealthy(tester);
      expect(sizeAttr(controller, 1), '20');
      expect(sizeAttr(controller, 0), isNull);
    });

    /// Açık menüdeki yuvarlak işaretin (radyo) hangi seçenekte durduğu.
    Future<String?> checkedOption(WidgetTester tester, String button) async {
      await tester.tap(find.bySemanticsLabel(button));
      await settle(tester);
      String? checked;
      for (final radio in tester.widgetList<RadioMenuButton<Object?>>(
        find.byWidgetPredicate((w) => w is RadioMenuButton),
      )) {
        if (radio.value == radio.groupValue) {
          checked = ((radio.child as Text).data);
        }
      }
      // Menüyü, zaten işaretli seçeneği yeniden seçerek (değişiklik yapmadan)
      // kapat.
      await tester.tap(find.text(checked!).last);
      await settle(tester);
      return checked;
    }

    appTest('imleç boşken seçilen boyut menüdeki işarete anında yansır', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'Normal',
        const TextSelection.collapsed(offset: 6),
      );
      await tester.pump();
      expect(await checkedOption(tester, 'Yazı boyutu'), 'Normal');

      // Metin yazılmadan, yalnızca imleçteyken seçilen boyut.
      await choose(tester, 'Yazı boyutu', 'Büyük');
      expect(await checkedOption(tester, 'Yazı boyutu'), 'Büyük');

      // Yazıldıktan sonra da doğru kalır.
      controller.replaceText(
        6,
        0,
        'x',
        const TextSelection.collapsed(offset: 7),
      );
      await tester.pump();
      expect(await checkedOption(tester, 'Yazı boyutu'), 'Büyük');

      await choose(tester, 'Yazı boyutu', 'Normal');
      expect(await checkedOption(tester, 'Yazı boyutu'), 'Normal');
      expectHealthy(tester);
    });

    appTest('imleç boşken seçilen satır aralığı menüdeki işarete yansır', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'metin',
        const TextSelection.collapsed(offset: 5),
      );
      await tester.pump();
      expect(await checkedOption(tester, 'Satır aralığı'), 'Normal');

      await choose(tester, 'Satır aralığı', 'Çift satır');
      expect(await checkedOption(tester, 'Satır aralığı'), 'Çift satır');
      expectHealthy(tester);
    });

    appTest('uzun ileti → boyut artır → kaydır → biçim değiştir', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      final text = List.generate(
        120,
        (i) => 'Satır ${i + 1}: uzun bir iletinin bir satırı',
      ).join('\n');
      controller.replaceText(
        0,
        0,
        text,
        TextSelection.collapsed(offset: text.length),
      );
      await tester.pump();
      final editorState = tester.state(find.byType(QuillEditor));

      // Belgenin ortasından bir bölümü büyüt.
      final middle = text.indexOf('Satır 60:');
      select(controller, middle, middle + 200);
      await tester.pump();
      await choose(tester, 'Yazı boyutu', 'Çok büyük');
      expectHealthy(tester);

      // Kaydır.
      await tester.drag(find.byType(ListView).first, const Offset(0, -900));
      await settle(tester);
      expect(tester.takeException(), isNull);

      // Kaydırdıktan sonra biçim değiştir: boyutu düşür, satır aralığı ver.
      select(controller, middle, middle + 200);
      await tester.pump();
      await choose(tester, 'Yazı boyutu', 'Büyük');
      expect(tester.takeException(), isNull);
      await choose(tester, 'Satır aralığı', 'Çift satır');
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);

      expect(sizeAttr(controller, middle), '20');
      expect(
        controller.document
            .collectStyle(middle, 1)
            .attributes['line-height']
            ?.value,
        2.0,
      );
      expect(
        identical(tester.state(find.byType(QuillEditor)), editorState),
        isTrue,
      );
    });

    appTest('Bilgi/Gizli açılıp kapanınca editör yeniden yaratılmaz', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'metin',
        const TextSelection.collapsed(offset: 5),
      );
      await tester.pump();
      final editorState = tester.state(find.byType(QuillEditor));

      await tester.tap(find.byTooltip('Bilgi/Gizli ekle'));
      await settle(tester);
      expect(
        identical(tester.state(find.byType(QuillEditor)), editorState),
        isTrue,
      );

      await tester.tap(find.byTooltip('Gizle'));
      await settle(tester);
      expect(
        identical(tester.state(find.byType(QuillEditor)), editorState),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('satır aralığı', () {
    appTest('editörde giden HTML\'dekiyle aynı çarpan çizilir', (tester) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'bir\niki\nüç',
        const TextSelection.collapsed(offset: 10),
      );
      select(controller, 4, 6); // yalnızca "iki" satırı
      await tester.pump();

      await choose(tester, 'Satır aralığı', '1,5 satır');
      expectHealthy(tester);

      final heights = <String, double?>{};
      for (final rich in tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(QuillEditor),
          matching: find.byType(RichText),
        ),
      )) {
        heights[rich.text.toPlainText().trim()] = rich.text.style?.height;
      }
      // Quill'in kendi tablosu 1.5'i 1.55 çizerdi; artık birebir 1.5.
      expect(heights['iki'], 1.5);
      expect(heights['bir'], 1.15);
      expect(heights['üç'], 1.15);
    });

    appTest('Sıkı ve Çift satır doğru çarpanla çizilir', (tester) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'a\nb',
        const TextSelection.collapsed(offset: 3),
      );
      select(controller, 0, 1);
      await tester.pump();
      await choose(tester, 'Satır aralığı', 'Sıkı (1,0)');
      select(controller, 2, 3);
      await tester.pump();
      await choose(tester, 'Satır aralığı', 'Çift satır');
      expectHealthy(tester);

      final heights = <String, double?>{
        for (final rich in tester.widgetList<RichText>(
          find.descendant(
            of: find.byType(QuillEditor),
            matching: find.byType(RichText),
          ),
        ))
          rich.text.toPlainText().trim(): rich.text.style?.height,
      };
      expect(heights['a'], 1.0);
      expect(heights['b'], 2.0);
    });
  });

  group('taslak ve yapıştırma', () {
    appTest('kayıtlı taslak açılınca biçimlendirme aynen geri gelir', (
      tester,
    ) async {
      final accountId = await pumpApp(tester);

      // Taslak, uygulamanın kendi kodlayıcısıyla saklanmış biçimli bir ileti.
      final delta = Delta()
        ..insert('Kırmızı büyük', {
          'color': '#EF4444',
          'size': '20',
          'bold': true,
        })
        ..insert('\n', {'line-height': 1.5, 'align': 'center'})
        ..insert('\n')
        ..insert('küçük', {'size': '13'})
        ..insert(' normal\n')
        ..insert('çok büyük', {'size': '24'})
        ..insert('\n', {'line-height': 2.0});
      final container = ProviderScope.containerOf(
        tester.element(find.byType(KaydetApp)),
      );
      final draftId = await container
          .read(mailRepositoryProvider)
          .saveDraft(
            accountId: accountId,
            to: 'a@b.com',
            cc: '',
            bcc: '',
            subject: 'Taslak',
            body: 'düz',
            html: EmailHtmlCodec.encode(delta),
          );
      expect(draftId, greaterThan(0));

      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ComposeScreen(draftId: draftId),
        ),
      );
      await settle(tester);

      final controller = tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller;
      expectHealthy(tester);
      expect(controller.document.toDelta().toJson(), delta.toJson());
      // Ekranda görünen boyutlar da geri geldi.
      expect(renderedFontSizes(tester).toSet(), {13.0, 16.0, 20.0, 24.0});
    });

    appTest('yapıştırılan keyfi boyut/öznitelikler editörü çökertmez', (
      tester,
    ) async {
      final controller = await openCompose(tester);

      // Zengin yapıştırma kancası bağlı olmalı.
      // ignore: experimental_member_use
      final hook = controller.config.clipboardConfig?.onRichTextPaste;
      expect(hook, isNotNull);

      // Dışarıdan (ör. bir web sayfasından) gelebilecek en kötü içerik.
      final hostile = Delta()
        ..insert('a', {'size': '18px'})
        ..insert('b', {'size': '500'})
        ..insert('c', {'size': 'garip'})
        ..insert('d', {'color': 'javascript:1', 'font': 'Comic Sans'})
        ..insert({'image': 'https://x/y.png'})
        ..insert('\n', {'line-height': 99, 'header': 42});
      final safe = (await hook!(hostile, true))!;

      controller.document = Document.fromDelta(safe);
      await tester.pump();
      await settle(tester);

      expectHealthy(tester);
      expect(renderedFontSizes(tester).every((s) => s <= 24), isTrue);
    });
  });

  group('gönderim', () {
    appTest('biçimlendirilmiş ileti alıcıya satır bazında aynı biçimle gider', (
      tester,
    ) async {
      final controller = await openCompose(tester);
      controller.replaceText(
        0,
        0,
        'Kırmızı\nNormal',
        const TextSelection.collapsed(offset: 14),
      );
      // "Kırmızı" satırı: kırmızı, Büyük, 1,5 satır aralığı.
      select(controller, 0, 7);
      await tester.pump();
      await choose(tester, 'Yazı boyutu', 'Büyük');
      await tester.tap(find.bySemanticsLabel('Metin rengi'));
      await settle(tester);
      await tester.tapAt(_swatchCenter(tester, 0));
      await settle(tester);
      await choose(tester, 'Satır aralığı', '1,5 satır');

      await tester.enterText(find.byType(TextField).at(0), 'alici@ornek.com');
      await tester.enterText(find.byType(TextField).at(1), 'Biçim denemesi');
      await tester.pump();
      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);

      expect(smtp.sent, hasLength(1));
      final html = smtp.sent.single.html!;

      // Kırmızı satır: kendi satır aralığı + kırmızı + 20px.
      final first = RegExp(
        r'<div style="[^"]*line-height:1\.5;[^"]*">.*?Kırmızı.*?</div>',
      ).firstMatch(html);
      expect(first, isNotNull, reason: html);
      expect(first!.group(0), contains('color:#EF4444'));
      expect(first.group(0), contains('font-size:20px'));

      // Normal satır: kırmızıdan ETKİLENMEZ, taban değerlerle gider.
      final second = RegExp(
        r'<div style="[^"]*">Normal</div>',
      ).firstMatch(html);
      expect(second, isNotNull, reason: html);
      expect(second!.group(0), contains('line-height:1.15'));
      expect(second.group(0), contains('font-size:16px'));
      expect(second.group(0), isNot(contains('color:')));

      // Gönderilen HTML editöre geri okunduğunda aynı biçimi verir.
      final back = EmailHtmlCodec.decode(html);
      expect(
        back.toJson(),
        EmailHtmlCodec.decode(EmailHtmlCodec.encode(back)).toJson(),
      );
    });
  });
}

/// Renk açılır listesindeki [index]. renk karesinin merkezi. Kareler 34x34'lük
/// `SizedBox`lardır; ilki "Yok" seçeneğidir, renkler ondan sonra gelir.
Offset _swatchCenter(WidgetTester tester, int index) {
  final swatches = find.byWidgetPredicate(
    (widget) => widget is SizedBox && widget.width == 34 && widget.height == 34,
  );
  return tester.getCenter(swatches.at(index + 1));
}

@Timeout(Duration(seconds: 120))
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/app.dart';
import 'package:kaydet/app/navigation.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/core/widgets/kaydet_widgets.dart';
import 'package:kaydet/ui/features/compose/compose_screen.dart';
import 'package:kaydet/ui/features/compose/recipient_details_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Yazma ekranında "Hızlı Kişiler → alıcı → kişi ayrıntıları" akışı — gerçek
/// `ComposeScreen`, gerçek veritabanı, gerçek dokunuşlar; yalnızca ağ taklit.
void appTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
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

  Future<int> seedAccount() async {
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
    return id;
  }

  /// Hesabı ve kişileri hazırlayıp uygulamayı açar, Yeni İleti'ye girer.
  Future<int> openCompose(
    WidgetTester tester, {
    List<(String email, String name)> contacts = const [],
  }) async {
    final accountId = await seedAccount();
    for (final (email, name) in contacts) {
      await db.upsertContact(accountId: accountId, email: email, name: name);
    }
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
    await tester.tap(find.byTooltip('Yeni ileti'));
    await settle(tester);
    return accountId;
  }

  const ahmet = ('ahmet@example.com', 'Ahmet Yılmaz');
  const zeynep = ('zeynep@example.com', 'Zeynep Kaya');
  const info = ('info@example.com', '');

  Finder quick(String email) => find.byKey(ValueKey(email));
  Finder field(int index) => find.byType(TextField).at(index);

  /// Çipin sağındaki küçük "x" (AppBar'daki "Kapat" ikonu 24 dp'dir).
  Finder chipRemove() => find.byWidgetPredicate(
    (w) => w is Icon && w.icon == LucideIcons.x && w.size == 14,
  );

  Finder inSheet(Finder matching) => find.descendant(
    of: find.byType(RecipientDetailsSheet),
    matching: matching,
  );

  group('Hızlı Kişiler → alıcı', () {
    appTest('Kime odaktayken görünür, yazmaya başlayınca gizlenir', (
      tester,
    ) async {
      await openCompose(tester, contacts: [ahmet, zeynep, info]);

      expect(find.text('HIZLI KİŞİLER'), findsOneWidget);
      expect(find.byType(QuickContactAvatar), findsNWidgets(3));

      await tester.enterText(field(0), 'zey');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('HIZLI KİŞİLER'), findsNothing);
    });

    appTest('yazarken çıkan kişi önerisi kompakt bir satırdır', (tester) async {
      await openCompose(tester, contacts: [ahmet]);

      await tester.enterText(field(0), 'ahm');
      await tester.pump(const Duration(milliseconds: 100));

      final row = find
          .ancestor(
            of: find.text('ahmet@example.com'),
            matching: find.byType(InkWell),
          )
          .first;
      // Eskiden avatar 40 dp + iki satır büyük yazıyla ~85 dp'ye çıkıyordu.
      expect(tester.getSize(row).height, lessThanOrEqualTo(52));
      expect(find.byType(BrandAvatar), findsWidgets);
      final avatar = tester.getSize(
        find.descendant(of: row, matching: find.byType(BrandAvatar)),
      );
      expect(avatar.width, 28);
    });

    appTest('kişi yoksa şerit hiç çıkmaz', (tester) async {
      await openCompose(tester);
      expect(find.text('HIZLI KİŞİLER'), findsNothing);
    });

    appTest('dokununca çip olur ve gönderimde GERÇEK adres kullanılır', (
      tester,
    ) async {
      await openCompose(tester, contacts: [ahmet, zeynep]);

      await tester.tap(quick(ahmet.$1));
      await settle(tester);

      // Çip görünen adı gösterir; e-posta ayrı tutulur.
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);
      // Eklenen kişi şeritten düşer, diğerleri kalır.
      expect(quick(ahmet.$1), findsNothing);
      expect(quick(zeynep.$1), findsOneWidget);

      await tester.enterText(field(1), 'Konu');
      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);

      expect(smtp.sent, hasLength(1));
      final to = smtp.sent.single.to;
      expect(to, hasLength(1));
      expect(to.single.email, 'ahmet@example.com');
      expect(to.single.name, 'Ahmet Yılmaz');
    });

    appTest('adsız kişi: çip adresten türetilir, adres bozulmaz', (
      tester,
    ) async {
      await openCompose(tester, contacts: [info]);

      await tester.tap(quick(info.$1));
      await settle(tester);
      // Ad yoksa çipte adresten türetilen ad görünür (bkz. `display`).
      expect(find.text('İnfo'), findsOneWidget);

      await tester.enterText(field(1), 'Konu');
      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);

      expect(smtp.sent.single.to.single.email, 'info@example.com');
      expect(smtp.sent.single.to.single.name, isNull);
    });

    appTest('aynı kişi iki kez eklenemez', (tester) async {
      await openCompose(tester, contacts: [ahmet, zeynep]);

      await tester.tap(quick(ahmet.$1));
      await settle(tester);
      // Aynı adresi elle (büyük/küçük harf farklı) yeniden yazmak da çip
      // çoğaltmaz.
      await tester.enterText(field(0), 'AHMET@example.com,');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);

      await tester.enterText(field(1), 'Konu');
      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);

      expect(smtp.sent.single.to.map((a) => a.email), ['ahmet@example.com']);
    });

    appTest('iki uzun ad alt alta değil, yan yana durur', (tester) async {
      await openCompose(
        tester,
        contacts: [
          ('bayram@example.com', 'Bayram'),
          ('kurumsal@example.com', 'Kurumsal Mail Hizmeti'),
        ],
      );

      await tester.tap(quick('bayram@example.com'));
      await settle(tester);
      await tester.tap(quick('kurumsal@example.com'));
      await settle(tester);

      // Sığmayan ikinci çip alt satıra atlamaz: kısaltılıp aynı satıra girer.
      final first = tester.getTopLeft(find.text('Bayram')).dy;
      final second = tester.getTopLeft(find.textContaining('Kurumsal')).dy;
      expect(second, first, reason: 'çipler aynı satırda olmalı');
      expect(tester.takeException(), isNull);
    });

    appTest('silinen alıcı şeride döner ve yeniden eklenebilir', (
      tester,
    ) async {
      await openCompose(tester, contacts: [ahmet]);

      await tester.tap(quick(ahmet.$1));
      await settle(tester);
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);

      await tester.tap(chipRemove());
      await settle(tester);
      expect(find.text('Ahmet Yılmaz'), findsNothing);

      // Silmek çipin gövde dokunuşunu (ayrıntı sheet'i) açmamalı.
      expect(find.byType(RecipientDetailsSheet), findsNothing);

      // Alan hâlâ odakta: şerit geri gelmiştir.
      await tester.tap(field(0));
      await settle(tester);
      expect(quick(ahmet.$1), findsOneWidget);
      await tester.tap(quick(ahmet.$1));
      await settle(tester);
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);
    });

    appTest('Bilgi alanı odaktayken seçilen kişi Bilgi\'ye eklenir', (
      tester,
    ) async {
      await openCompose(tester, contacts: [ahmet, zeynep]);

      await tester.enterText(field(0), 'alici@ornek.com,');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('Bilgi/Gizli ekle'));
      await settle(tester);

      // Bilgi alanına geç: şerit o alanın çiplerine göre süzülür.
      await tester.tap(field(1));
      await settle(tester);
      await tester.tap(quick(zeynep.$1));
      await settle(tester);

      await tester.enterText(field(3), 'Konu');
      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);

      final sent = smtp.sent.single;
      expect(sent.to.map((a) => a.email), ['alici@ornek.com']);
      expect(sent.cc.map((a) => a.email), ['zeynep@example.com']);
      expect(sent.bcc, isEmpty);
    });

    appTest('şeridi yatay kaydırmak odağı (ve şeridi) kapatmaz', (
      tester,
    ) async {
      await openCompose(
        tester,
        contacts: [
          for (var i = 0; i < 10; i++) ('kisi$i@example.com', 'Kişi $i Soyad'),
        ],
      );
      expect(find.text('HIZLI KİŞİLER'), findsOneWidget);

      final before = tester.getTopLeft(quick('kisi9@example.com')).dx;
      await tester.drag(quick('kisi0@example.com'), const Offset(-200, 0));
      await settle(tester);

      // Şerit gerçekten kaydı ve alan odakta kaldı.
      expect(
        tester.getTopLeft(quick('kisi9@example.com')).dx,
        lessThan(before),
      );
      expect(find.text('HIZLI KİŞİLER'), findsOneWidget);
    });

    appTest('adı virgüllü kişi taslaktan geri yüklenince tek ve doğru alıcı', (
      tester,
    ) async {
      await openCompose(
        tester,
        contacts: [('ahmet@example.com', 'Yılmaz, Ahmet')],
      );

      await tester.tap(quick('ahmet@example.com'));
      await settle(tester);
      await tester.enterText(field(1), 'Virgüllü');
      await tester.tap(find.byTooltip('Kapat'));
      await settle(tester);

      final draft = await (db.select(
        db.messages,
      )..where((m) => m.isDraft.equals(true))).getSingle();
      final stored = EmailAddress.decodeList(draft.toAddrJson);
      expect(stored.single.email, 'ahmet@example.com');
      expect(stored.single.name, 'Yılmaz, Ahmet');

      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ComposeScreen(draftId: draft.id),
        ),
      );
      await settle(tester);

      // Eski davranış: "Yılmaz" geçersiz alıcı, ad da "Ahmet" olurdu.
      expect(find.text('Yılmaz, Ahmet'), findsOneWidget);
      expect(find.text('Yılmaz'), findsNothing);

      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);
      expect(smtp.sent.single.to.single.email, 'ahmet@example.com');
      expect(smtp.sent.single.to.single.name, 'Yılmaz, Ahmet');
    });
  });

  group('alıcı ayrıntıları', () {
    appTest('çipe dokunmak sheet açar, kapatınca alıcı korunur', (
      tester,
    ) async {
      await openCompose(tester, contacts: [ahmet]);
      await tester.tap(quick(ahmet.$1));
      await settle(tester);

      await tester.tap(find.text('Ahmet Yılmaz'));
      await settle(tester);

      expect(find.byType(RecipientDetailsSheet), findsOneWidget);
      expect(inSheet(find.text('Ahmet Yılmaz')), findsOneWidget);
      expect(inSheet(find.text('ahmet@example.com')), findsOneWidget);
      expect(inSheet(find.text('E-posta')), findsOneWidget);
      // Kişi zaten kayıtlı: ekleme eylemi yerine durum gösterilir.
      expect(inSheet(find.text('Kişilerinizde kayıtlı')), findsOneWidget);
      expect(find.text('Kişilere Ekle'), findsNothing);
      // Modelde olmayan alanlar UYDURULMAZ.
      expect(find.text('Telefon'), findsNothing);
      expect(find.text('Şirket'), findsNothing);

      // Sheet dışına (scrim) dokunarak kapat.
      await tester.tapAt(const Offset(195, 40));
      await settle(tester);

      expect(find.byType(RecipientDetailsSheet), findsNothing);
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);

      // Kapatınca silme hâlâ çalışır (iki hedef birbirini gölgelemez).
      await tester.tap(chipRemove());
      await settle(tester);
      expect(find.text('Ahmet Yılmaz'), findsNothing);
    });

    appTest('kişi defterinde olmayan adres "Kişilere Ekle" ile eklenir', (
      tester,
    ) async {
      final accountId = await openCompose(tester);

      await tester.enterText(field(0), 'yeni@ornek.com,');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Yeni'));
      await settle(tester);

      expect(inSheet(find.text('yeni@ornek.com')), findsOneWidget);
      expect(find.text('Kişilere Ekle'), findsOneWidget);
      expect(await db.select(db.contacts).get(), isEmpty);

      await tester.tap(find.text('Kişilere Ekle'));
      await settle(tester);

      final contacts = await db.select(db.contacts).get();
      expect(contacts.map((c) => c.email), ['yeni@ornek.com']);
      expect(contacts.single.accountId, accountId);
      // Canlı akış: eylem "kayıtlı" durumuna döner, ikinci kez basılamaz.
      expect(find.text('Kişilere Ekle'), findsNothing);
      expect(inSheet(find.text('Kişilerinizde kayıtlı')), findsOneWidget);
    });

    appTest('geçersiz adres için Kişilere Ekle sunulmaz', (tester) async {
      await openCompose(tester);

      await tester.enterText(field(0), 'bozukadres,');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Bozukadres'));
      await settle(tester);

      expect(find.byType(RecipientDetailsSheet), findsOneWidget);
      expect(inSheet(find.text('Geçersiz e-posta adresi')), findsOneWidget);
      expect(find.text('Kişilere Ekle'), findsNothing);
    });
  });

  group('sheet yerleşimi', () {
    const longName =
        'Muhammed Abdurrahman Bin Ahmet Yılmaz-Kaya Uluslararası Danışmanlık '
        've Ticaret Anonim Şirketi Genel Müdürü';
    const longEmail =
        'cok.uzun.bir.kisi.adi.ve.soyadi.ile.baslayan.adres@'
        'cok-uzun-bir-alt-alan-adi.kurumsal-ornek-sirket.com.tr';

    for (final dark in [false, true]) {
      for (final (size, scale) in [
        (const Size(320, 568), 2.0),
        (const Size(390, 844), 1.0),
        (const Size(844, 390), 1.0),
      ]) {
        testWidgets('${dark ? 'koyu' : 'açık'} tema, ${size.width.toInt()}x'
            '${size.height.toInt()}, yazı ×$scale: taşma yok', (tester) async {
          tester.view.physicalSize = size * 2;
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);

          final accountId = await seedAccount();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                databaseProvider.overrideWithValue(db),
                secureStoreProvider.overrideWithValue(secureStore),
                imapServiceProvider.overrideWithValue(imap),
                smtpServiceProvider.overrideWithValue(smtp),
              ],
              child: MaterialApp(
                theme: dark ? AppTheme.dark() : AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showRecipientDetails(
                        context,
                        address: const EmailAddress(
                          email: longEmail,
                          name: longName,
                        ),
                        accountId: accountId,
                      ),
                      child: const Text('aç'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('aç'));
          await settle(tester);

          expect(tester.takeException(), isNull);
          expect(find.byType(RecipientDetailsSheet), findsOneWidget);
          expect(find.text('Kişilere Ekle'), findsOneWidget);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 50));
        });
      }
    }
  });
}

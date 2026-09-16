@Timeout(Duration(seconds: 90))
library;

import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/app.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/database/tables.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Uçtan uca arayüz testleri.
///
/// Gerçek veritabanı, gerçek repository'ler ve gerçek eşitleme motoru
/// kullanılır; yalnızca ağ katmanı (IMAP/SMTP) taklit edilir. Böylece
/// kullanıcının gördüğü davranış doğrulanır.
/// Test gövdesini çalıştırır, sonra widget ağacını söküp bir kare daha çevirir.
///
/// Drift, son akış aboneliği kapanırken sıfır süreli bir zamanlayıcı kurar.
/// Bu zamanlayıcı boşaltılmazsa `flutter_test` "A Timer is still pending"
/// hatası verir ve test takılır. `addTearDown` bu iş için çok geç çalışır;
/// çerçevenin denetimi test gövdesinin hemen ardından yapılır.
void appTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    // Süre verilmeden çağrılan pump() sahte saati ilerletmez; sıfır süreli
    // zamanlayıcı ancak saat ilerleyince tetiklenir.
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

  Future<void> pumpApp(WidgetTester tester) async {
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
    await tester.pump();
  }

  /// Hesabı doğrudan veritabanına yazar (giriş ekranını atlamak için).
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

  /// Eşitlemenin tamamlanmasını bekler.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Ayarlar'a geçer. Modül geçişi artık alt gezinme çubuğunda değil,
  /// hamburger menünün altındaki etiketsiz simge şeridindedir (bkz.
  /// `AppShell` içindeki `_ModuleIcon`) — etiket görünürde olmadığı için
  /// metinle değil tooltip'le bulunur.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Klasörler'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byTooltip('Ayarlar'),
      ),
    );
    await settle(tester);
  }

  group('giriş ekranı', () {
    appTest('hesap yokken giriş ekranı açılır', (tester) async {
      await pumpApp(tester);
      await tester.pump();

      expect(find.text('KAYDET'), findsWidgets);
      expect(find.text('Giriş yap'), findsOneWidget);
      expect(find.text('E-posta adresi'), findsOneWidget);
    });

    appTest('geçersiz e-posta uyarı verir', (tester) async {
      await pumpApp(tester);
      await tester.pump();

      await tester.enterText(
        find.byType(TextFormField).first,
        'bozukadres',
      );
      await tester.tap(find.text('Giriş yap'));
      await tester.pump();

      expect(find.text('Geçerli bir e-posta adresi girin'), findsOneWidget);
    });

    appTest('boş şifre uyarı verir', (tester) async {
      await pumpApp(tester);
      await tester.pump();

      await tester.enterText(
        find.byType(TextFormField).first,
        'info@pazarlik.com.tr',
      );
      await tester.tap(find.text('Giriş yap'));
      await tester.pump();

      expect(find.text('Şifre gerekli'), findsOneWidget);
    });

    appTest('sunucu ayarları e-posta alanından doldurulur',
        (tester) async {
      await pumpApp(tester);
      await tester.pump();

      await tester.enterText(
        find.byType(TextFormField).first,
        'info@pazarlik.com.tr',
      );
      await tester.pump();
      await tester.tap(find.text('Sunucu ayarları'));
      await tester.pump();

      expect(find.text('mail.pazarlik.com.tr'), findsNWidgets(2));
      expect(find.text('993'), findsOneWidget);
      expect(find.text('465'), findsOneWidget);
    });

    appTest('başarılı giriş mail listesine geçirir', (tester) async {
      imap.seedInbox([
        envelope(uid: 1, subject: 'Fiyat teklifi'),
      ]);

      await pumpApp(tester);
      await tester.pump();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'info@pazarlik.com.tr');
      await tester.enterText(fields.at(1), 'sifre');
      await tester.pump();

      await tester.tap(find.text('Giriş yap'));
      await settle(tester);

      expect(find.text('Gelen Kutusu'), findsWidgets);
    });

    appTest('yanlış şifre hata kutusu gösterir', (tester) async {
      imap.failOnConnect = const AuthFailure(detail: 'test');

      await pumpApp(tester);
      await tester.pump();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'info@pazarlik.com.tr');
      await tester.enterText(fields.at(1), 'yanlis');
      await tester.pump();

      await tester.tap(find.text('Giriş yap'));
      await settle(tester);

      expect(find.text('Kullanıcı adı veya şifre hatalı.'), findsOneWidget);
      // Hesap kaydedilmemiş olmalı.
      expect(await db.activeAccount(), isNull);
    });

    appTest('giriş sonrası kimlik hatası afişi çıkmaz', (tester) async {
      // Güvenli depoya yazmak cihazda birkaç kare sürer. Hesap, şifresi
      // yerine oturmadan etkinleşirse eşitleme kimlik hatası verir ve
      // kullanıcı giriş yaptığı hâlde "şifre hatalı" uyarısı görür.
      secureStore = SlowSecureStore();
      imap.seedInbox([envelope(uid: 1, subject: 'Fiyat teklifi')]);

      await pumpApp(tester);
      await tester.pump();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'info@pazarlik.com.tr');
      await tester.enterText(fields.at(1), 'sifre');
      await tester.pump();

      await tester.tap(find.text('Giriş yap'));
      await settle(tester);
      await settle(tester);

      expect(find.text('Kullanıcı adı veya şifre hatalı.'), findsNothing);
      expect(find.text('Fiyat teklifi'), findsOneWidget);
    });
  });

  group('mail listesi', () {
    appTest('sunucudaki iletiler listelenir', (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1, subject: 'Fiyat teklifi', fromName: 'Ahmet Yılmaz'),
        envelope(uid: 2, subject: 'Logo çalışması', fromName: 'Zeynep Kaya'),
      ]);

      await pumpApp(tester);
      await settle(tester);

      expect(find.text('Fiyat teklifi'), findsOneWidget);
      expect(find.text('Logo çalışması'), findsOneWidget);
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);
      expect(find.text('Zeynep Kaya'), findsOneWidget);
    });

    appTest('boş klasörde boş durum gösterilir', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      expect(find.text('Bu klasör boş'), findsOneWidget);
    });

    appTest('avatara dokunmak seçim modunu başlatır', (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1, subject: 'Birinci'),
        envelope(uid: 2, subject: 'İkinci'),
      ]);

      await pumpApp(tester);
      await settle(tester);

      // İlk satırın avatarına dokun.
      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();

      expect(find.text('1 seçildi'), findsOneWidget);
      expect(find.text('Tümünü seç'), findsOneWidget);
      expect(find.text('Sil'), findsOneWidget);
      expect(find.text('Arşivle'), findsOneWidget);
    });

    appTest('tümünü seç bütün iletileri işaretler', (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1),
        envelope(uid: 2),
        envelope(uid: 3),
      ]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Tümünü seç'));
      await tester.pump();

      expect(find.text('3 seçildi'), findsOneWidget);
    });

    appTest('silme iletiyi listeden anında kaldırır', (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1, subject: 'Silinecek'),
        envelope(uid: 2, subject: 'Kalacak'),
      ]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await settle(tester);

      expect(find.text('Silinecek'), findsNothing);
      expect(find.text('Kalacak'), findsOneWidget);
    });

    appTest('silinen ileti sunucuda Çöp Kutusu\'na taşınır',
        (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Silinecek')]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await settle(tester);

      // Kalıcı silme DEĞİL, taşıma olmalı: veri kaybı riski yok.
      expect(
        imap.commandLog.any((c) => c.startsWith('move:') && c.contains('Trash')),
        isTrue,
        reason: 'komutlar: ${imap.commandLog}',
      );
      expect(
        imap.commandLog.any((c) => c.startsWith('expunge')),
        isFalse,
      );
    });

    appTest('okundu işaretleme sunucuya \\Seen gönderir', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, seen: false)]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Okundu'));
      await settle(tester);

      expect(
        imap.commandLog.any((c) => c.contains(r'store:\Seen:+')),
        isTrue,
        reason: 'komutlar: ${imap.commandLog}',
      );
    });

    appTest('sabitleme IMAP \\Flagged bayrağına yazılır', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1)]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sabitle'));
      await settle(tester);

      expect(
        imap.commandLog.any((c) => c.contains(r'store:\Flagged:+')),
        isTrue,
        reason: 'komutlar: ${imap.commandLog}',
      );
    });
  });

  group('arama', () {
    appTest('konuya göre filtreler', (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1, subject: 'Fiyat teklifi'),
        envelope(uid: 2, subject: 'Logo çalışması'),
      ]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Ara'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'logo');
      await settle(tester);

      expect(find.text('Logo çalışması'), findsOneWidget);
      expect(find.text('Fiyat teklifi'), findsNothing);
    });

    appTest('Türkçe karakter katlaması arayüzde de çalışır',
        (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1, subject: 'Görüşme notu'),
        envelope(uid: 2, subject: 'Fatura'),
      ]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Ara'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'gorusme');
      await settle(tester);

      expect(find.text('Görüşme notu'), findsOneWidget);
      expect(find.text('Fatura'), findsNothing);
    });

    appTest('sonuç yoksa boş durum gösterilir', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Fiyat teklifi')]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Ara'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'bulunamayacak');
      await settle(tester);

      expect(find.text('Sonuç bulunamadı'), findsOneWidget);
    });
  });

  group('ileti okuma', () {
    appTest('iletiye dokunmak detayı açar ve gövdeyi gösterir',
        (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Fiyat teklifi')]);
      imap.seedBody(
        'INBOX',
        1,
        const FetchedBody(plainText: 'Teklifimiz ektedir, iyi çalışmalar.'),
      );

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.text('Fiyat teklifi'));
      await settle(tester);

      expect(find.text('Teklifimiz ektedir, iyi çalışmalar.'), findsOneWidget);
      expect(find.text('Yanıtla'), findsOneWidget);
      expect(find.text('İlet'), findsOneWidget);
    });

    appTest('okundu işareti gecikmeli konur', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Okunmamış', seen: false)]);
      imap.seedBody('INBOX', 1, const FetchedBody(plainText: 'metin'));

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.text('Okunmamış'));
      // Sayfa geçişi birkaç kare sürer (320 ms). Okundu gecikmesini
      // (1500 ms) doldurmadan detay ekranına varılmalı.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byTooltip('Geri'), findsOneWidget);

      await tester.tap(find.byTooltip('Geri'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      final row = await db.messageByUid(
        (await db.mailboxBySpecialUse(
          (await db.activeAccount())!.id,
          SpecialUse.inbox,
        ))!
            .id,
        1,
      );
      expect(
        row?.isSeen,
        isFalse,
        reason: 'Hemen geri çıkan kullanıcı iletiyi okumuş sayılmamalı',
      );
    });
  });

  group('ileti yazma', () {
    appTest('yaz düğmesi yazma ekranını açar', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);

      expect(find.text('Yeni ileti'), findsWidgets);
      expect(find.text('Kime'), findsOneWidget);
      expect(find.text('Konu'), findsOneWidget);
      expect(find.text('Sesli yaz'), findsOneWidget);
    });

    appTest('alıcısız gönderim uyarı verir', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);
      await tester.tap(find.byTooltip('Gönder'));
      await tester.pump();

      expect(find.text('En az bir alıcı girin.'), findsOneWidget);
    });

    appTest('geçersiz adres uyarı verir', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);

      await tester.enterText(find.byType(TextField).first, 'bozukadres');
      await tester.pump();
      await tester.tap(find.byTooltip('Gönder'));
      await tester.pump();

      expect(find.textContaining('Geçersiz adres'), findsOneWidget);
    });

    appTest('gönderilen ileti SMTP\'ye ulaşır ve Gönderilenler\'e yazılır',
        (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'alici@ornek.com');
      await tester.enterText(find.byType(TextField).at(1), 'Deneme konusu');
      await tester.enterText(find.byType(TextField).at(2), 'Merhaba dünya');
      await tester.pump();

      await tester.tap(find.byTooltip('Gönder'));
      await settle(tester);

      expect(smtp.sent, hasLength(1));
      expect(smtp.sent.single.subject, 'Deneme konusu');
      expect(smtp.sent.single.to.single.email, 'alici@ornek.com');
      // SMTP gönderimi ile Gönderilenler'e APPEND ayrı adımlardır.
      expect(
        imap.commandLog.any((c) => c == 'append:INBOX.Sent'),
        isTrue,
        reason: 'komutlar: ${imap.commandLog}',
      );
    });

    appTest('geri çıkarken taslak diyaloğu açılır', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.pump();
      await tester.tap(find.byTooltip('Kapat'));
      await tester.pump();

      expect(find.text('Taslak kaydedilsin mi?'), findsOneWidget);
      expect(find.text('Taslağı kaydet'), findsOneWidget);
      expect(find.text('Sil'), findsOneWidget);
      expect(find.text('İptal'), findsOneWidget);
    });

    appTest('boş iletide diyalog çıkmaz, doğrudan kapanır',
        (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);
      await tester.tap(find.byTooltip('Kapat'));
      await settle(tester);

      expect(find.text('Taslak kaydedilsin mi?'), findsNothing);
      expect(find.text('Kime'), findsNothing);
    });

    appTest('taslak kaydedilince Taslaklar klasörüne düşer',
        (tester) async {
      final accountId = await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Yeni ileti'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'Yarım kalan');
      await tester.pump();
      await tester.tap(find.byTooltip('Kapat'));
      await tester.pump();
      await tester.tap(find.text('Taslağı kaydet'));
      await settle(tester);

      final drafts =
          await db.mailboxBySpecialUse(accountId, SpecialUse.drafts);
      expect(drafts, isNotNull);
      expect(await db.countMessages(drafts!.id), 1);
    });
  });

  group('klasör gezinme', () {
    appTest('yan menü klasörleri listeler', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Klasörler'));
      await settle(tester);

      expect(find.text('Gelen Kutusu'), findsWidgets);
      expect(find.text('Gönderilenler'), findsOneWidget);
      expect(find.text('Taslaklar'), findsOneWidget);
      expect(find.text('Çöp Kutusu'), findsOneWidget);
      expect(find.text('İstenmeyen'), findsOneWidget);
      expect(find.text('Arşiv'), findsOneWidget);
      expect(find.text('Sabitlenenler'), findsOneWidget);
    });

    appTest('Taslaklar, Çöp Kutusu\'nun üzerinde sıralanır',
        (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Klasörler'));
      await settle(tester);

      final draftsY = tester.getTopLeft(find.text('Taslaklar')).dy;
      final trashY = tester.getTopLeft(find.text('Çöp Kutusu')).dy;
      expect(draftsY, lessThan(trashY));
    });

    appTest('klasör seçimi listeyi değiştirir', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Gelen ileti')]);

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Klasörler'));
      await settle(tester);
      await tester.tap(find.text('Arşiv'));
      await settle(tester);

      expect(find.text('Gelen ileti'), findsNothing);
      expect(find.text('Bu klasör boş'), findsOneWidget);
    });
  });

  group('ayarlar', () {
    appTest('ayarlar ekranı hesap bilgisini gösterir', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await openSettings(tester);

      expect(find.text('info@pazarlik.com.tr'), findsOneWidget);
      expect(
        find.text('mail.pazarlik.com.tr:993 · SSL/TLS · Etkin'),
        findsOneWidget,
      );
    });

    appTest('arka plan sıklığı dürüst şekilde açıklanır', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await openSettings(tester);

      await tester.scrollUntilVisible(
        find.textContaining('Android en sık 15 dakikada bir'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Android en sık 15 dakikada bir'),
        findsOneWidget,
      );
    });

    appTest('çıkış yap onay ister ve hesabı siler', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await openSettings(tester);

      await tester.scrollUntilVisible(
        find.text('Hesaptan çıkış yap'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Hesaptan çıkış yap'));
      await tester.pump();

      expect(find.text('Çıkış yap'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Çıkış yap'));
      await settle(tester);

      expect(await db.activeAccount(), isNull);
      expect(find.text('Giriş yap'), findsOneWidget);
    });

    appTest('yan menüden açılan ayarlarda çıkış giriş ekranına döner',
        (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      // Yan menüdeki Ayarlar, `AppShell`in gövdesini değiştirir (artık ayrı
      // bir yığın sayfası açmıyor, bkz. `activeTabProvider`). Çıkıştan
      // sonra kök ekrana dönülmezse kullanıcı giriş ekranını hiç göremez
      // ve çıkış yapamadığını sanır.
      await openSettings(tester);

      await tester.scrollUntilVisible(
        find.text('Hesaptan çıkış yap'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Hesaptan çıkış yap'));
      await tester.pump();
      await tester.tap(find.text('Hesaptan çıkış yap'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Çıkış yap'));
      await settle(tester);

      expect(await db.activeAccount(), isNull);
      expect(find.text('Hesaptan çıkış yap'), findsNothing);
      expect(find.text('Giriş yap'), findsOneWidget);
    });

    appTest('hesap ekle ikinci hesabı ekler ve ona geçer', (tester) async {
      await seedAccount();
      await pumpApp(tester);
      await settle(tester);

      await openSettings(tester);

      await tester.tap(find.byTooltip('Hesap ekle'));
      await settle(tester);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'ikinci@baskasirket.com');
      await tester.enterText(fields.at(1), 'sifre2');
      await tester.pump();
      await tester.tap(find.text('Giriş yap'));
      await settle(tester);

      // "Hesap ekle" akışı kendini kapatır, Ayarlar'a döneriz — ilk hesap
      // listede kalır ama artık etkin değildir.
      expect(find.text('ikinci@baskasirket.com'), findsOneWidget);
      expect(find.text('info@pazarlik.com.tr'), findsOneWidget);

      final active = await db.activeAccount();
      expect(active?.email, 'ikinci@baskasirket.com');
      expect(await db.allAccounts(), hasLength(2));
    });

    appTest(
        'hesap listesinden etkin olmayan hesabı kaldırmak ekranı değiştirmez',
        (tester) async {
      await seedAccount();
      final secondId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'ucuncu@ornek.com',
          username: 'ucuncu@ornek.com',
          imapHost: 'mail.ornek.com',
          smtpHost: 'mail.ornek.com',
          isActive: const Value(false),
        ),
      );
      await secureStore.writePassword(secondId, 'sifre3');

      await pumpApp(tester);
      await settle(tester);
      await openSettings(tester);

      await tester.scrollUntilVisible(
        find.text('ucuncu@ornek.com'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // Liste id sırasına göre dizilir: seedAccount() önce eklendiği için
      // ilk çöp kutusu simgesi ona, ikincisi az önce eklenen hesaba aittir.
      await tester.tap(find.byTooltip('Hesabı kaldır').at(1));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Çıkış yap'));
      await settle(tester);

      // Etkin olmayan bir hesap kaldırıldığında ekran değişmez. AppBar,
      // yukarıdaki kaydırmadan etkilenmeyen sabit alan olduğu için "hâlâ
      // Ayarlar'dayız" kontrolü için ListView içindeki bir metinden daha
      // güvenilir: Sliver sanallaştırması ekran dışına kaydırılan içeriği
      // element ağacından kaldırır, `find.text('HESAPLAR')` bu yüzden
      // kaydırma sonrası yanlışlıkla "bulunamadı" dönebilir.
      expect(find.widgetWithText(AppBar, 'Ayarlar'), findsOneWidget);
      expect(find.text('ucuncu@ornek.com'), findsNothing);
      expect(await db.allAccounts(), hasLength(1));
      expect((await db.activeAccount())?.email, 'info@pazarlik.com.tr');
    });

    appTest(
        'yan menüde tüm hesaplar birlikte görünür; başka hesabın '
        'klasörüne dokunmak ayrı bir geçiş adımı olmadan o hesaba geçer',
        (tester) async {
      await seedAccount();
      final secondId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'ikinci@ornek.com',
          username: 'ikinci@ornek.com',
          imapHost: 'mail.ornek.com',
          smtpHost: 'mail.ornek.com',
          displayName: const Value('İkinci Hesap'),
          isActive: const Value(false),
        ),
      );
      await secureStore.writePassword(secondId, 'sifre2');
      // Gerçek bir hesapta olduğu gibi klasörleri önceden yerelde var:
      // yan menü, hesap etkinleşmeden de bu klasörü göstermelidir.
      await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: secondId,
          path: 'INBOX',
          name: 'İkinci Gelen Kutusu',
          specialUse: const Value(SpecialUse.inbox),
        ),
      );

      await pumpApp(tester);
      await settle(tester);

      await tester.tap(find.byTooltip('Klasörler'));
      await settle(tester);

      // İki hesap da aynı anda listelenir — henüz hiçbir şeye dokunmadan.
      expect(find.text('ikinci@ornek.com'), findsOneWidget);
      expect(find.text('İkinci Gelen Kutusu'), findsOneWidget);

      // Başka hesabın klasörüne dokunmak, ayrı bir "hesap değiştir" adımı
      // olmadan doğrudan o hesabı etkinleştirir.
      await tester.tap(find.text('İkinci Gelen Kutusu'));
      await settle(tester);

      expect((await db.activeAccount())?.email, 'ikinci@ornek.com');
    });
  });

  group('eşitleme davranışı', () {
    appTest('UIDVALIDITY değişince klasör baştan indirilir',
        (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Eski ileti')]);

      await pumpApp(tester);
      await settle(tester);
      expect(find.text('Eski ileti'), findsOneWidget);

      // Sunucu klasörü yeniden oluşturdu: UID'ler geçersiz.
      imap.uidValidity = 2000;
      imap.store['INBOX'] = {2: envelope(uid: 2, subject: 'Yeni ileti')};

      await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1000);
      await settle(tester);
      await settle(tester);

      expect(find.text('Eski ileti'), findsNothing);
      expect(find.text('Yeni ileti'), findsOneWidget);
    });

    appTest('sunucudan silinen ileti yerelden de düşer', (tester) async {
      await seedAccount();
      imap.seedInbox([
        envelope(uid: 1, subject: 'Birinci'),
        envelope(uid: 2, subject: 'İkinci'),
      ]);

      await pumpApp(tester);
      await settle(tester);
      expect(find.text('Birinci'), findsOneWidget);

      imap.store['INBOX']!.remove(1);

      await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1000);
      await settle(tester);
      await settle(tester);

      expect(find.text('Birinci'), findsNothing);
      expect(find.text('İkinci'), findsOneWidget);
    });
  });

  group('kalıcı silme koruması', () {
    appTest('Çöp Kutusu içinde silme onay ister', (tester) async {
      final accountId = await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Çöpteki ileti')]);

      await pumpApp(tester);
      await settle(tester);

      // İletiyi çöpe taşı.
      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await settle(tester);

      // Çöp Kutusu'na geç.
      await tester.tap(find.byTooltip('Klasörler'));
      await settle(tester);
      await tester.tap(find.text('Çöp Kutusu'));
      await settle(tester);
      expect(find.text('Çöpteki ileti'), findsOneWidget);

      // Oradan silmek KALICI olduğu için onay istenmeli.
      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await tester.pump();

      expect(find.text('Kalıcı olarak silinsin mi?'), findsOneWidget);

      // Vazgeçilirse ileti durmalı. ("Vazgeç" hem seçim çubuğunda hem
      // diyalogda var; diyalogdaki hedeflenir.)
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Vazgeç'),
        ),
      );
      await settle(tester);
      expect(find.text('Çöpteki ileti'), findsOneWidget);

      final trash = await db.mailboxBySpecialUse(accountId, SpecialUse.trash);
      expect(await db.countMessages(trash!.id), 1);
    });

    appTest('onaylanırsa sunucudan da kalıcı silinir', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Gidecek ileti')]);

      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await settle(tester);

      await tester.tap(find.byTooltip('Klasörler'));
      await settle(tester);
      await tester.tap(find.text('Çöp Kutusu'));
      await settle(tester);

      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await tester.pump();
      await tester.tap(find.text('Kalıcı olarak sil'));
      await settle(tester);

      expect(find.text('Gidecek ileti'), findsNothing);
      expect(
        imap.commandLog.any((c) => c.startsWith('expunge')),
        isTrue,
        reason: 'komutlar: ${imap.commandLog}',
      );
    });

    appTest('normal klasörde silme onay istemez', (tester) async {
      await seedAccount();
      imap.seedInbox([envelope(uid: 1, subject: 'Gelen ileti')]);

      await pumpApp(tester);
      await settle(tester);
      await tester.tap(find.byType(InkResponse).first);
      await tester.pump();
      await tester.tap(find.text('Sil'));
      await tester.pump();

      expect(find.text('Kalıcı olarak silinsin mi?'), findsNothing);
    });
  });
}

/// Şifre yazımı gecikmeli güvenli depo.
///
/// Android Keystore'a yazmak anlık değildir; bu gecikme, hesabın şifresi
/// yerine oturmadan etkinleşmesi hatasını görünür kılar.
class SlowSecureStore extends InMemorySecureStore {
  @override
  Future<void> writePassword(int accountId, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await super.writePassword(accountId, password);
  }
}

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/search_providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/features/search/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/test_db.dart';

class _AllAccountsScope extends SearchScopeNotifier {
  @override
  int? build() => null;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late int accountId;
  late int inboxId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
        displayName: const Value('Pazarlık'),
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

  tearDown(() async {
    await db.close();
  });

  MessagesCompanion message(
    int uid,
    String subject, {
    bool hasAttachments = false,
    String fromEmail = 'ahmet@gmail.com',
    DateTime? date,
  }) => MessagesCompanion.insert(
    accountId: accountId,
    mailboxId: inboxId,
    dateUtc: date ?? DateTime.now().toUtc(),
    uid: Value(uid),
    subject: Value(subject),
    fromEmail: Value(fromEmail),
    hasAttachments: Value(hasAttachments),
  );

  /// Gerçek SQLite işleri sahte zamanlayıcıyla ilerlemez: arada gerçek olay
  /// döngüsüne de zaman tanınır.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> pumpSearch(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          searchScopeProvider.overrideWith(_AllAccountsScope.new),
          ownEmailDomainsProvider.overrideWithValue(const <String>{}),
          // Drift akışları sahte zamanlayıcıda bekleyen zamanlayıcı bırakır;
          // arama sonuçları akış değil tek seferlik sorgudur ve gerçek
          // veritabanından gelir.
          allAccountsProvider.overrideWith((ref) => Stream.value(const [])),
          recentContactsProvider.overrideWithValue(const []),
          // Sunucu araması bu testlerin konusu değil (bkz. remote_search_test).
          remoteSearchProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const SearchScreen()),
      ),
    );
    await settle(tester);
  }

  testWidgets('filtre düğmesi çipleri açar; yazı olmadan Ekli tüm ekli '
      'iletileri listeler', (tester) async {
    await db.upsertServerMessages([
      message(1, 'Ekli rapor', hasAttachments: true),
      message(2, 'Ekli olmayan not'),
    ]);

    await pumpSearch(tester);

    // Başta çipler kapalı, ekran boş durumda.
    expect(find.text('Ekli'), findsNothing);
    expect(find.text('Gönderen, konu veya içerikte arayın.'), findsOneWidget);

    await tester.tap(find.byTooltip('Filtre'));
    await settle(tester);
    for (final label in ['Ekli', 'Tarih', 'Klasörler', 'Gönderen', 'Alıcı']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Filtre seçilmedi: hâlâ metin istenir.
    expect(find.text('Ekli rapor'), findsNothing);

    await tester.tap(find.text('Ekli'));
    await settle(tester);

    expect(find.text('Ekli rapor'), findsOneWidget);
    expect(find.text('Ekli olmayan not'), findsNothing);
    expect(find.byTooltip('Filtre, 1 etkin'), findsOneWidget);
  });

  testWidgets('metin ve gönderen filtresi birlikte daraltır; düğme filtreleri '
      'sıfırlar', (tester) async {
    await db.upsertServerMessages([
      message(1, 'Teklif Ahmet', fromEmail: 'ahmet@gmail.com'),
      message(2, 'Teklif Ece', fromEmail: 'ece@hotmail.com'),
    ]);

    await pumpSearch(tester);
    await tester.tap(find.byTooltip('Filtre'));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, 'teklif');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('Teklif Ahmet'), findsOneWidget);
    expect(find.text('Teklif Ece'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchScreen)),
    );
    container
        .read(searchFiltersProvider.notifier)
        .apply(
          container
              .read(searchFiltersProvider)
              .copyWith(sender: () => 'ece@hotmail.com'),
        );
    await settle(tester);

    expect(find.text('Teklif Ece'), findsOneWidget);
    expect(find.text('Teklif Ahmet'), findsNothing);
    expect(find.text('Gönderen: ece@hotmail.com'), findsOneWidget);

    // Çipler açıkken filtre düğmesi düz aramaya döner.
    await tester.tap(find.byTooltip('Filtre, 1 etkin'));
    await settle(tester);

    expect(container.read(searchFiltersProvider).isActive, isFalse);
    expect(find.text('Gönderen'), findsNothing);
    expect(find.text('Teklif Ahmet'), findsOneWidget);
    expect(find.text('Teklif Ece'), findsOneWidget);
  });

  testWidgets('filtreyle eşleşen sonuç yoksa boş durum filtreleri temizletir', (
    tester,
  ) async {
    await db.upsertServerMessages([message(1, 'Ekli olmayan not')]);

    await pumpSearch(tester);
    await tester.tap(find.byTooltip('Filtre'));
    await settle(tester);
    await tester.tap(find.text('Ekli'));
    await settle(tester);

    expect(find.text('Sonuç bulunamadı'), findsOneWidget);
    expect(find.text('Seçili filtrelerle eşleşen sonuç yok.'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(TextButton, 'Filtreleri temizle').last,
    );
    await settle(tester);

    expect(find.text('Sonuç bulunamadı'), findsNothing);
  });

  testWidgets('sonuçtaki ileti (taslak) silinince liste kendiliğinden '
      'güncellenir', (tester) async {
    final ids = await db.upsertServerMessages([
      message(1, 'Rapor taslağı'),
      message(2, 'Rapor son hali'),
    ]);

    await pumpSearch(tester);
    await tester.enterText(find.byType(TextField).first, 'rapor');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('Rapor taslağı'), findsOneWidget);
    expect(find.text('Rapor son hali'), findsOneWidget);

    // Taslağı silmek (bkz. `DraftRepository.discardDraft`) arama açıkken olur.
    await tester.runAsync(() => db.deleteMessages([ids.first]));
    await settle(tester);

    expect(find.text('Rapor taslağı'), findsNothing);
    expect(find.text('Rapor son hali'), findsOneWidget);
  });

  testWidgets('Tümü/Posta/Kişiler/Dosyalar sekmeleri yok; Dosyalar bir filtre '
      'çipidir', (tester) async {
    final ids = await db.upsertServerMessages([
      message(1, 'Sözleşme ekli', hasAttachments: true),
      message(2, 'Düz not'),
    ]);
    await db.addAttachment(
      AttachmentsCompanion.insert(
        messageId: ids.first,
        fileName: const Value('sozlesme.pdf'),
      ),
    );

    await pumpSearch(tester);
    for (final tab in ['Tümü', 'Posta', 'Kişiler']) {
      expect(find.text(tab), findsNothing, reason: tab);
    }
    // Dosyalar çipler kapalıyken görünmez; ayrı bir sekme değildir.
    expect(find.text('Dosyalar'), findsNothing);

    await tester.tap(find.byTooltip('Filtre'));
    await settle(tester);
    await tester.tap(find.text('Dosyalar'));
    await settle(tester);

    // Yazı olmadan en son ekler listelenir; ileti sonuçları değil.
    expect(find.text('sozlesme.pdf'), findsOneWidget);
    expect(find.text('Düz not'), findsNothing);
    expect(find.byTooltip('Filtre, 1 etkin'), findsOneWidget);
  });
}

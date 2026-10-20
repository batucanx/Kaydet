import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/filter_providers.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_filter_repository.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/filter_rules.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/features/settings/filters_settings_screen.dart';

import 'helpers/test_db.dart';

/// Ayarlar > Filtreler: liste, sıralama, aç/kapat, silme, düzenleyici doğrulaması ve "filtreyi test et".
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late MailFilterRepository repo;
  late int accountId;
  late int folderId;
  late int labelId;
  final synced = <int>[];

  FilterDefinition def(
    String name, {
    bool enabled = true,
    List<FilterAction>? actions,
    List<FilterCondition>? conditions,
  }) => FilterDefinition(
    name: name,
    enabled: enabled,
    matchMode: FilterMatchMode.all,
    conditions:
        conditions ??
        const [
          FilterCondition(
            field: FilterField.from,
            operator: FilterOperator.contains,
            value: 'fatura@example.com',
          ),
        ],
    actions: actions ?? const [FilterAction.archive()],
    stopProcessing: false,
  );

  /// Veritabanı işlemleri gerçek zaman ister: `runAsync` içinde yapılır.
  Future<T> real<T>(WidgetTester tester, Future<T> Function() body) async =>
      (await tester.runAsync(body)) as T;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Drift akışları kapanırken zamanlayıcı bırakır: ağaç kaldırılıp boşaltılmadan test bitmez.
  void screenTest(
    String name,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          mailFilterRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const FiltersSettingsScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  setUp(() async {
    db = createTestDatabase();
    synced.clear();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'h',
        smtpHost: 'h',
      ),
    );
    await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen Kutusu',
        specialUse: const Value(SpecialUse.inbox),
      ),
    );
    folderId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX.Faturalar',
        name: 'Faturalar',
        specialUse: const Value(SpecialUse.custom),
      ),
    );
    await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX.Çöp',
        name: 'Çöp',
        specialUse: const Value(SpecialUse.trash),
      ),
    );
    labelId = await db.insertLabel(
      LabelsCompanion.insert(accountId: accountId, name: 'Fatura'),
    );
    repo = MailFilterRepository(database: db, onChanged: synced.add);
  });

  tearDown(() async {
    await db.close();
  });

  screenTest('boş durum: açıklama ve "Filtre oluştur"', (tester) async {
    await open(tester);
    expect(find.text('Henüz oluşturulmuş bir filtre yok.'), findsOneWidget);
    expect(find.text('Filtre oluştur'), findsOneWidget);
  });

  screenTest('liste: sıra numarası, ad, durum, koşul ve işlem özetleri', (
    tester,
  ) async {
    await real(tester, () async {
      await repo.add(
        accountId,
        def(
          'Faturalar',
          actions: [
            FilterAction.move(folderId),
            FilterAction.label(labelId),
            const FilterAction.forward('muhasebe@example.com'),
          ],
        ),
      );
      await repo.add(
        accountId,
        def(
          '',
          enabled: false,
          conditions: const [
            FilterCondition(
              field: FilterField.attachment,
              operator: FilterOperator.exists,
            ),
          ],
        ),
      );
    });
    await open(tester);

    expect(find.text('Faturalar'), findsWidgets);
    expect(find.text('Aktif'), findsOneWidget);
    expect(find.text('Devre dışı'), findsOneWidget);
    expect(find.text('Kimden içerir “fatura@example.com”'), findsWidgets);
    expect(find.text('→ Faturalar klasörüne taşı'), findsOneWidget);
    expect(find.text('→ “Fatura” etiketini ekle'), findsOneWidget);
    expect(find.text('→ muhasebe@example.com adresine ilet'), findsOneWidget);
    // Adı boş bırakılan filtre ilk koşuldan adlandırılır.
    expect(find.text('Ek dosyası var'), findsWidgets);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(
      find.byTooltip('“Faturalar” filtresini yukarı taşı'),
      findsOneWidget,
    );
  });

  screenTest('aşağı taşı sırayı değiştirir ve eşitleme ister', (tester) async {
    await real(tester, () async {
      await repo.add(accountId, def('Birinci'));
      await repo.add(accountId, def('İkinci'));
    });
    await open(tester);
    synced.clear();

    await tester.tap(find.byTooltip('“Birinci” filtresini aşağı taşı'));
    await settle(tester);

    final order = await real(tester, () => repo.list(accountId));
    expect(order.map((f) => f.name), ['İkinci', 'Birinci']);
    expect(synced, [accountId]);
  });

  screenTest('anahtar filtreyi kapatır; eşitleme ister', (tester) async {
    await real(tester, () => repo.add(accountId, def('Fatura')));
    await open(tester);
    synced.clear();

    await tester.tap(find.byType(Switch));
    await settle(tester);

    final f = (await real(tester, () => repo.list(accountId))).single;
    expect(f.enabled, isFalse);
    expect(synced, [accountId]);
    expect(find.text('Devre dışı'), findsOneWidget);
  });

  screenTest('silme onay ister; vazgeçince silinmez, onaylayınca silinir', (
    tester,
  ) async {
    await real(tester, () => repo.add(accountId, def('Silinecek')));
    await open(tester);

    await tester.tap(find.byTooltip('“Silinecek” filtresini sil'));
    await settle(tester);
    expect(find.text('Filtre silinsin mi?'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await settle(tester);
    expect(await real(tester, () => repo.count(accountId)), 1);

    await tester.tap(find.byTooltip('“Silinecek” filtresini sil'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sil'));
    await settle(tester);
    expect(await real(tester, () => repo.count(accountId)), 0);
    expect(find.text('Henüz oluşturulmuş bir filtre yok.'), findsOneWidget);
  });

  screenTest(
    'düzenleyici: boş değer ve klasör için web ile aynı mesajlar; kaydetmez',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('Filtre oluştur'));
      await settle(tester);
      expect(find.text('Şu e-postalar için…'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Filtreyi oluştur'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Filtreyi oluştur'));
      await settle(tester);

      expect(find.text('Bir değer girin.'), findsOneWidget);
      expect(find.text('Bir klasör seçin.'), findsOneWidget);
      expect(
        find.text('Filtre kaydedilemedi. İşaretli alanları kontrol edin.'),
        findsOneWidget,
      );
      expect(await real(tester, () => repo.count(accountId)), 0);
    },
  );

  screenTest('düzenleyici: klasör seçip kaydetmek filtre oluşturur', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Filtre oluştur'));
    await settle(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Filtre adı'),
      'Faturalarım',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Koşul 1: değer'),
      'fatura@example.com',
    );
    await tester.tap(find.byType(DropdownButton<int>));
    await settle(tester);
    // Yalnızca elle taşımanın izin verdiği klasörler listelenir (Çöp ve Gelen Kutusu yok).
    expect(find.text('Çöp'), findsNothing);
    await tester.tap(find.text('Faturalar').last);
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('Filtreyi oluştur'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Filtreyi oluştur'));
    await settle(tester);

    final list = await real(tester, () => repo.list(accountId));
    expect(list, hasLength(1));
    expect(list.single.name, 'Faturalarım');
    expect(list.single.actions, [FilterAction.move(folderId)]);
    expect(list.single.conditions.single.value, 'fatura@example.com');
    expect(synced, [accountId]);
    // Liste ekranına dönüldü.
    expect(find.text('→ Faturalar klasörüne taşı'), findsOneWidget);
  });

  screenTest('"Filtreyi test et": koşullar tek tek ve karar gösterilir', (
    tester,
  ) async {
    await real(tester, () async {
      await repo.add(accountId, def('Fatura'));
      final inbox = (await db.mailboxByPath(accountId, 'INBOX'))!;
      await db.upsertServerMessages([
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inbox.id,
          uid: const Value(1),
          dateUtc: DateTime.utc(2026, 10, 12),
          subject: const Value('Ekim faturası'),
          fromName: const Value('Muhasebe'),
          fromEmail: const Value('Fatura@Example.com'),
        ),
      ]);
    });
    await open(tester);
    await tester.tap(find.text('Düzenle'));
    await settle(tester);

    await tester.scrollUntilVisible(
      find.text('Filtreyi test et'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Filtreyi test et'));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Test et'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Test et'));
    await settle(tester);

    expect(
      find.text('Kimden içerir “fatura@example.com”: eşleşti'),
      findsOneWidget,
    );
    expect(find.text('Bu e-posta filtreyle eşleşiyor.'), findsOneWidget);
  });
}

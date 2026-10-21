import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/search_providers.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/models/search_filters.dart';
import 'package:kaydet/ui/core/theme/app_theme.dart';
import 'package:kaydet/ui/features/search/search_filter_chips.dart';

class _FakeScope extends SearchScopeNotifier {
  @override
  int? build() => null;
}

ContactRow contact(int id, String email, String name) => ContactRow(
  id: id,
  accountId: 1,
  email: email,
  name: name,
  timesUsed: 1,
  lastUsedAt: DateTime(2026, 10, 1),
);

void main() {
  final now = DateTime(2026, 10, 21, 15, 30);

  late ProviderContainer container;

  Future<void> pumpChips(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        searchScopeProvider.overrideWith(_FakeScope.new),
        // Kişi avatarları (`BrandAvatar`) hesap listesi için veritabanı açmasın.
        ownEmailDomainsProvider.overrideWithValue(const <String>{}),
        searchFolderOptionsProvider.overrideWith(
          (ref) async => const [
            SearchFolder.standard(SpecialUse.inbox),
            SearchFolder.standard(SpecialUse.sent),
            SearchFolder.custom('Work'),
          ],
        ),
        searchPeopleProvider.overrideWith(
          (ref, text) async => [
            contact(1, 'ece@firma.com', 'Ece Kaya'),
            contact(2, 'can@firma.com', 'Can Demir'),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: SearchFilterChips(now: now)),
        ),
      ),
    );
    await tester.pump();
  }

  SearchFilters filters() => container.read(searchFiltersProvider);

  testWidgets('beş çip web ile aynı sırada gelir, başta filtre yoktur', (
    tester,
  ) async {
    await pumpChips(tester);

    for (final label in [
      'Ekli',
      'Dosyalar',
      'Tarih',
      'Klasörler',
      'Gönderen',
      'Alıcı',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(filters().isActive, isFalse);
    // Çöp Kutusu "Tüm Klasörler" aramasına her zaman dahildir.
    expect(filters().includeDeleted, isTrue);
    expect(find.text('Filtreleri temizle'), findsNothing);
  });

  testWidgets('Ekli dokununca açılır kapanır', (tester) async {
    await pumpChips(tester);

    await tester.tap(find.text('Ekli'));
    await tester.pump();
    expect(filters().withAttachmentsOnly, isTrue);
    expect(filters().activeCount, 1);

    await tester.tap(find.text('Ekli'));
    await tester.pump();
    expect(filters().withAttachmentsOnly, isFalse);
  });

  testWidgets('Tarih: hızlı aralık seçilince uygulanır ve sayfa kapanır', (
    tester,
  ) async {
    await pumpChips(tester);

    await tester.tap(find.text('Tarih'));
    await tester.pumpAndSettle();
    expect(find.text('Bugün'), findsOneWidget);
    expect(find.text('Son 7 gün'), findsOneWidget);
    expect(find.text('Son 30 gün'), findsOneWidget);
    // "Bul" yalnızca elle seçilen günlerle açılır.
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Bul')),
      isA<FilledButton>().having((b) => b.onPressed, 'onPressed', isNull),
    );

    await tester.tap(find.text('Son 7 gün'));
    await tester.pumpAndSettle();

    final today = DateTime.now();
    final expected = const SearchFilters().withPreset(
      SearchDatePreset.last7,
      today,
    );
    expect(filters().dateFrom, expected.dateFrom);
    expect(filters().dateTo, expected.dateTo);
    // Sayfa kapandı.
    expect(find.text('Bugün'), findsNothing);
  });

  testWidgets('Tarih çipi seçimi okur ve × yalnızca tarihi kaldırır', (
    tester,
  ) async {
    await pumpChips(tester);
    container
        .read(searchFiltersProvider.notifier)
        .apply(
          filters().copyWith(
            withAttachmentsOnly: true,
            dateFrom: () => DateTime(2026, 10, 15),
            dateTo: () => DateTime(2026, 10, 21),
          ),
        );
    await tester.pump();

    // 15–21 Ekim, `now` ile "Son 7 gün" ile aynı.
    expect(find.text('Tarih: Son 7 gün'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pump();

    expect(filters().hasDate, isFalse);
    expect(filters().withAttachmentsOnly, isTrue);
  });

  testWidgets('Klasörler: seçim anında uygulanır, çip adı gösterir', (
    tester,
  ) async {
    await pumpChips(tester);

    await tester.tap(find.text('Klasörler'));
    await tester.pumpAndSettle();
    expect(find.text('Tüm Klasörler'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    expect(filters().folder, const SearchFolder.custom('Work'));
    expect(find.text('Klasörler: Work'), findsOneWidget);
  });

  testWidgets('Gönderen: kişi seçilir, tekrar dokunmak geri alır', (
    tester,
  ) async {
    await pumpChips(tester);

    await tester.tap(find.text('Gönderen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ece Kaya'));
    await tester.pumpAndSettle();

    expect(filters().sender, 'ece@firma.com');
    expect(filters().recipient, isNull);
    expect(find.text('Gönderen: ece@firma.com'), findsOneWidget);

    // Aynı kişiye yeniden dokunmak seçimi geri alır.
    await tester.tap(find.text('Gönderen: ece@firma.com'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ece Kaya'));
    await tester.pumpAndSettle();

    expect(filters().sender, isNull);
  });

  testWidgets('Alıcı: tam bir adres yazıp onaylamak o adresi seçer', (
    tester,
  ) async {
    await pumpChips(tester);

    await tester.tap(find.text('Alıcı'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Yeni@Firma.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(filters().recipient, 'yeni@firma.com');
    expect(filters().sender, isNull);
  });

  testWidgets(
    'Filtreleri temizle hepsini sıfırlar ama Çöp Kutusu dahil kalır',
    (tester) async {
      await pumpChips(tester);
      container
          .read(searchFiltersProvider.notifier)
          .apply(
            filters().copyWith(
              withAttachmentsOnly: true,
              sender: () => 'ece@firma.com',
            ),
          );
      await tester.pump();

      // Çip satırı yatay kaydırılır; düğme satırın sonundadır.
      await tester.scrollUntilVisible(
        find.text('Filtreleri temizle'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filtreleri temizle'));
      await tester.pump();

      expect(filters().isActive, isFalse);
      expect(filters().includeDeleted, isTrue);
      expect(find.text('Filtreleri temizle'), findsNothing);
    },
  );

  test('describeSearchDateFilter hızlı aralığı ya da günleri okur', () {
    String describe(SearchFilters f) => describeSearchDateFilter(f, now);

    expect(
      describe(const SearchFilters().withPreset(SearchDatePreset.today, now)),
      'Bugün',
    );
    expect(
      describe(
        SearchFilters(
          dateFrom: DateTime(2026, 9, 1),
          dateTo: DateTime(2026, 9, 5),
        ),
      ),
      '1 Eyl – 5 Eyl',
    );
    expect(
      describe(SearchFilters(dateFrom: DateTime(2025, 3, 4))),
      '4 Mar 2025 ve sonrası',
    );
    expect(
      describe(SearchFilters(dateTo: DateTime(2026, 3, 4))),
      '4 Mar ve öncesi',
    );
    expect(
      describe(
        SearchFilters(
          dateFrom: DateTime(2026, 3, 4),
          dateTo: DateTime(2026, 3, 4),
        ),
      ),
      '4 Mar',
    );
  });
}

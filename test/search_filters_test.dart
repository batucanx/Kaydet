import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/models/search_filters.dart';

void main() {
  group('SearchFilters', () {
    test('varsayılan filtre etkin değildir', () {
      const filters = SearchFilters();

      expect(filters.isActive, isFalse);
      expect(filters.activeCount, 0);
    });

    test('activeCount yalnızca etkili filtreleri sayar', () {
      expect(const SearchFilters(withAttachmentsOnly: true).activeCount, 1);
      expect(
        const SearchFilters(
          folder: SearchFolder.standard(SpecialUse.inbox),
        ).activeCount,
        1,
      );
      expect(SearchFilters(dateFrom: DateTime(2026, 10, 1)).activeCount, 1);
      expect(const SearchFilters(sender: 'a@x.com').activeCount, 1);
      expect(const SearchFilters(recipient: 'b@x.com').activeCount, 1);
      // "Silinmiş öğeleri dahil et" bir filtre değil, arama ekranının
      // varsayılanıdır (web gibi): rozete sayılmaz.
      expect(const SearchFilters(includeDeleted: true).activeCount, 0);
      expect(const SearchFilters(includeDeleted: true).isActive, isFalse);
      // İki tarih ucu tek bir filtredir.
      expect(
        SearchFilters(
          dateFrom: DateTime(2026, 10, 1),
          dateTo: DateTime(2026, 10, 5),
        ).activeCount,
        1,
      );
      expect(
        SearchFilters(
          withAttachmentsOnly: true,
          dateTo: DateTime(2026, 10, 5),
          sender: 'a@x.com',
          recipient: 'b@x.com',
          folder: const SearchFolder.custom('Work'),
        ).activeCount,
        5,
      );
    });

    test('selectsOnItsOwn: etkin her filtre metinsiz da tam bir aramadır', () {
      expect(const SearchFilters().selectsOnItsOwn, isFalse);
      expect(
        const SearchFilters(includeDeleted: true).selectsOnItsOwn,
        isFalse,
      );
      expect(
        const SearchFilters(withAttachmentsOnly: true).selectsOnItsOwn,
        isTrue,
      );
      expect(const SearchFilters(sender: 'a@x.com').selectsOnItsOwn, isTrue);
      expect(
        SearchFilters(dateTo: DateTime(2026, 10, 5)).selectsOnItsOwn,
        isTrue,
      );
    });

    test('copyWith klasörü temizleyebilir, diğer alanları korur', () {
      const filters = SearchFilters(
        withAttachmentsOnly: true,
        folder: SearchFolder.custom('Work'),
      );

      final cleared = filters.copyWith(folder: () => null);
      expect(cleared.folder, isNull);
      expect(cleared.withAttachmentsOnly, isTrue);

      final toggled = filters.copyWith(includeDeleted: true);
      expect(toggled.folder, const SearchFolder.custom('Work'));
      expect(toggled.includeDeleted, isTrue);
    });

    test('eşitlik değere göredir', () {
      expect(
        const SearchFilters(
          withAttachmentsOnly: true,
          folder: SearchFolder.custom('Work'),
        ),
        const SearchFilters(
          withAttachmentsOnly: true,
          folder: SearchFolder.custom('Work'),
        ),
      );
      expect(
        const SearchFilters(withAttachmentsOnly: true),
        isNot(const SearchFilters()),
      );
    });
  });

  group('SearchFilters tarih', () {
    final now = DateTime(2026, 10, 21, 15, 30);

    test('hızlı aralıklar bugünü sayarak geriye gider', () {
      final today = const SearchFilters().withPreset(
        SearchDatePreset.today,
        now,
      );
      expect(today.dateFrom, DateTime(2026, 10, 21));
      expect(today.dateTo, DateTime(2026, 10, 21));

      final week = const SearchFilters().withPreset(
        SearchDatePreset.last7,
        now,
      );
      expect(week.dateFrom, DateTime(2026, 10, 15));
      expect(week.dateTo, DateTime(2026, 10, 21));

      final month = const SearchFilters().withPreset(
        SearchDatePreset.last30,
        now,
      );
      expect(month.dateFrom, DateTime(2026, 9, 22));
    });

    test('activePreset yalnızca tam eşleşen aralığı bulur', () {
      final week = const SearchFilters().withPreset(
        SearchDatePreset.last7,
        now,
      );
      expect(week.activePreset(now), SearchDatePreset.last7);
      expect(
        week.withDateFrom(DateTime(2026, 10, 14)).activePreset(now),
        isNull,
      );
      expect(const SearchFilters().activePreset(now), isNull);
    });

    test('dateRange iki ucu yerel gece yarısına, bitişi ertesi güne açar', () {
      final range = SearchFilters(
        dateFrom: DateTime(2026, 10, 10),
        dateTo: DateTime(2026, 10, 12),
      ).dateRange!;
      expect(range.after, DateTime(2026, 10, 10).toUtc());
      expect(range.before, DateTime(2026, 10, 13).toUtc());

      final fromOnly = SearchFilters(
        dateFrom: DateTime(2026, 10, 10),
      ).dateRange!;
      expect(fromOnly.before, isNull);
      final toOnly = SearchFilters(dateTo: DateTime(2026, 10, 10)).dateRange!;
      expect(toOnly.after, isNull);

      expect(const SearchFilters().dateRange, isNull);
    });

    test('ters uçlu pencere null döner (hiçbir şeyle eşleşmez)', () {
      final reversed = SearchFilters(
        dateFrom: DateTime(2026, 10, 12),
        dateTo: DateTime(2026, 10, 10),
      );
      expect(reversed.hasDate, isTrue);
      expect(reversed.dateRange, isNull);
    });

    test('bir uç diğerini aşarsa diğer ucu da çeker', () {
      final filters = SearchFilters(
        dateFrom: DateTime(2026, 10, 10),
        dateTo: DateTime(2026, 10, 12),
      );

      final movedFrom = filters.withDateFrom(DateTime(2026, 10, 20, 9));
      expect(movedFrom.dateFrom, DateTime(2026, 10, 20));
      expect(movedFrom.dateTo, DateTime(2026, 10, 20));

      final movedTo = filters.withDateTo(DateTime(2026, 10, 1));
      expect(movedTo.dateTo, DateTime(2026, 10, 1));
      expect(movedTo.dateFrom, DateTime(2026, 10, 1));

      // Uçlar çaprazlanmıyorsa diğeri dokunulmaz; uç silinebilir.
      final cleared = filters.withDateTo(null);
      expect(cleared.dateTo, isNull);
      expect(cleared.dateFrom, DateTime(2026, 10, 10));
    });

    test('copyWith kişi ve tarih alanlarını temizleyebilir', () {
      final filters = SearchFilters(
        dateFrom: DateTime(2026, 10, 10),
        sender: 'a@x.com',
        recipient: 'b@x.com',
      );

      final cleared = filters.copyWith(
        dateFrom: () => null,
        sender: () => null,
      );
      expect(cleared.hasDate, isFalse);
      expect(cleared.sender, isNull);
      expect(cleared.recipient, 'b@x.com');
    });
  });

  group('SearchFolder', () {
    test('of: özel klasör ada, standart klasör türe göre seçilir', () {
      expect(
        SearchFolder.of(SpecialUse.custom, 'Work'),
        const SearchFolder.custom('Work'),
      );
      expect(
        SearchFolder.of(SpecialUse.inbox, 'Gelen Kutusu'),
        const SearchFolder.standard(SpecialUse.inbox),
      );
    });

    test('aynı türdeki klasörler hesap/ad farkına rağmen birleşir', () {
      // Bir hesapta "Sent Items", diğerinde "Gönderilenler": tek seçenek.
      expect(
        SearchFolder.of(SpecialUse.sent, 'Sent Items'),
        SearchFolder.of(SpecialUse.sent, 'Gönderilenler'),
      );
    });

    test('farklı adlı özel klasörler ayrı seçeneklerdir', () {
      expect(
        const SearchFolder.custom('Work'),
        isNot(const SearchFolder.custom('School')),
      );
    });
  });
}

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
      expect(const SearchFilters(includeDeleted: true).activeCount, 1);
      expect(
        const SearchFilters(
          folder: SearchFolder.standard(SpecialUse.inbox),
        ).activeCount,
        1,
      );
      // Belirli bir klasör seçiliyken "silinmiş öğeler" etkisizdir: ayrıca
      // sayılmaz.
      expect(
        const SearchFilters(
          includeDeleted: true,
          folder: SearchFolder.standard(SpecialUse.inbox),
        ).activeCount,
        1,
      );
      expect(
        const SearchFilters(
          withAttachmentsOnly: true,
          includeDeleted: true,
        ).activeCount,
        2,
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

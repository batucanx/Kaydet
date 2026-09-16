import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/tables.dart';
import 'package:kaydet/domain/use_cases/folder_mapping.dart';

void main() {
  SpecialUse resolve(String path, {String delimiter = '.', SpecialUse? flag}) =>
      FolderMapping.resolve(
        path: path,
        delimiter: delimiter,
        serverFlagUse: flag,
      );

  group('sunucu bayrağı', () {
    test('sunucu bildirdiyse ad eşlemesine bakılmaz', () {
      expect(
        resolve('INBOX.Garip Ad', flag: SpecialUse.sent),
        SpecialUse.sent,
      );
    });

    test('sunucu "custom" derse ad eşlemesi devreye girer', () {
      expect(
        resolve('INBOX.Sent', flag: SpecialUse.custom),
        SpecialUse.sent,
      );
    });
  });

  group('İngilizce klasör adları', () {
    test('INBOX her biçimde tanınır', () {
      expect(resolve('INBOX'), SpecialUse.inbox);
      expect(resolve('inbox'), SpecialUse.inbox);
    });

    test('cPanel yolları çözülür', () {
      expect(resolve('INBOX.Sent'), SpecialUse.sent);
      expect(resolve('INBOX.Drafts'), SpecialUse.drafts);
      expect(resolve('INBOX.Trash'), SpecialUse.trash);
      expect(resolve('INBOX.Junk'), SpecialUse.junk);
      expect(resolve('INBOX.Archive'), SpecialUse.archive);
    });

    test('boşluklu adlar çözülür', () {
      expect(resolve('INBOX.Sent Items'), SpecialUse.sent);
      expect(resolve('INBOX.Deleted Items'), SpecialUse.trash);
    });

    test('eğik çizgi ayracı da çalışır', () {
      expect(resolve('INBOX/Sent', delimiter: '/'), SpecialUse.sent);
    });
  });

  group('Türkçe klasör adları', () {
    test('Türk hosting adları çözülür', () {
      expect(resolve('INBOX.Gönderilmiş Öğeler'), SpecialUse.sent);
      expect(resolve('INBOX.Gönderilenler'), SpecialUse.sent);
      expect(resolve('INBOX.Taslaklar'), SpecialUse.drafts);
      expect(resolve('INBOX.Çöp Kutusu'), SpecialUse.trash);
      expect(resolve('INBOX.Önemsiz'), SpecialUse.junk);
      expect(resolve('INBOX.İstenmeyen'), SpecialUse.junk);
      expect(resolve('INBOX.Arşiv'), SpecialUse.archive);
      expect(resolve('INBOX.Silinmiş Öğeler'), SpecialUse.trash);
    });

    test('büyük/küçük harf farkı önemli değil', () {
      expect(resolve('INBOX.TASLAKLAR'), SpecialUse.drafts);
      expect(resolve('INBOX.çöp kutusu'), SpecialUse.trash);
    });
  });

  test('tanınmayan klasör özel klasör sayılır', () {
    expect(resolve('INBOX.Müşteriler'), SpecialUse.custom);
    expect(resolve('INBOX.2026 Projeleri'), SpecialUse.custom);
  });

  group('yan menü sıralaması', () {
    test('Taslaklar, Çöp Kutusu\'nun hemen üzerindedir', () {
      expect(
        FolderMapping.sortOrderFor(SpecialUse.drafts),
        lessThan(FolderMapping.sortOrderFor(SpecialUse.trash)),
      );
    });

    test('Gelen Kutusu en üsttedir', () {
      final orders = SpecialUse.values
          .map(FolderMapping.sortOrderFor)
          .toList();
      expect(
        FolderMapping.sortOrderFor(SpecialUse.inbox),
        orders.reduce((a, b) => a < b ? a : b),
      );
    });
  });

  group('silme davranışı', () {
    test('Çöp Kutusu ve İstenmeyen içinde silme kalıcıdır', () {
      expect(FolderMapping.deleteIsPermanent(SpecialUse.trash), isTrue);
      expect(FolderMapping.deleteIsPermanent(SpecialUse.junk), isTrue);
    });

    test('diğer klasörlerde silme Çöp Kutusu\'na taşır', () {
      expect(FolderMapping.deleteIsPermanent(SpecialUse.inbox), isFalse);
      expect(FolderMapping.deleteIsPermanent(SpecialUse.archive), isFalse);
      expect(FolderMapping.deleteIsPermanent(SpecialUse.sent), isFalse);
    });
  });

  group('yol yardımcıları', () {
    test('son bileşeni ayırır', () {
      expect(FolderMapping.leafName('INBOX.Sent', '.'), 'Sent');
      expect(FolderMapping.leafName('INBOX/Alt/Klasör', '/'), 'Klasör');
      expect(FolderMapping.leafName('INBOX', '.'), 'INBOX');
    });

    test('Türkçe görünen adlar', () {
      expect(
        FolderMapping.displayName(SpecialUse.inbox, 'x'),
        'Gelen Kutusu',
      );
      expect(FolderMapping.displayName(SpecialUse.junk, 'x'), 'İstenmeyen');
      expect(
        FolderMapping.displayName(SpecialUse.custom, 'Müşteriler'),
        'Müşteriler',
      );
    });
  });
}

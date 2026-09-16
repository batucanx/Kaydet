import '../../core/turkish.dart';
import '../../data/database/tables.dart';

/// Sunucu klasörünü uygulamanın bildiği türe eşler.
///
/// Sıralama önemli: önce sunucunun SPECIAL-USE/XLIST bayrağına bakılır
/// (kesin bilgi), o yoksa ad eşlemesine düşülür. Türk hosting'lerinde
/// klasörler `Gönderilmiş Öğeler`, `Önemsiz`, `Çöp Kutusu` gibi adlandırılır
/// ve bu isimler sunucudan sunucuya değişir.
abstract final class FolderMapping {
  /// İngilizce + Türkçe klasör adı eşlemesi (normalleştirilmiş).
  static const Map<SpecialUse, List<String>> _names = {
    SpecialUse.inbox: ['inbox', 'gelen', 'gelen kutusu', 'gelenkutusu'],
    SpecialUse.sent: [
      'sent',
      'sent items',
      'sent messages',
      'sentmail',
      'sent mail',
      'gonderilmis',
      'gonderilmis ogeler',
      'gonderilenler',
      'giden',
      'giden kutusu',
    ],
    SpecialUse.drafts: [
      'drafts',
      'draft',
      'taslak',
      'taslaklar',
      'taslak ogeler',
    ],
    SpecialUse.trash: [
      'trash',
      'deleted',
      'deleted items',
      'deleted messages',
      'bin',
      'cop',
      'cop kutusu',
      'silinmis',
      'silinmis ogeler',
      'cop kutusu ogeleri',
    ],
    SpecialUse.junk: [
      'junk',
      'spam',
      'bulk mail',
      'junk e-mail',
      'istenmeyen',
      'istenmeyen posta',
      'onemsiz',
      'gereksiz',
    ],
    SpecialUse.archive: [
      'archive',
      'archives',
      'all mail',
      'arsiv',
      'arsivler',
    ],
  };

  /// Klasör yolundan son bileşeni alır: `INBOX.Sent` → `Sent`
  static String leafName(String path, String delimiter) {
    if (delimiter.isEmpty) return path;
    final index = path.lastIndexOf(delimiter);
    if (index < 0 || index == path.length - 1) return path;
    return path.substring(index + delimiter.length);
  }

  /// Ada göre klasör türünü tahmin eder.
  ///
  /// [serverFlagUse] sunucunun bildirdiği tür — varsa her zaman kazanır.
  static SpecialUse resolve({
    required String path,
    required String delimiter,
    SpecialUse? serverFlagUse,
  }) {
    if (serverFlagUse != null && serverFlagUse != SpecialUse.custom) {
      return serverFlagUse;
    }

    // INBOX adı IMAP standardında büyük/küçük harf duyarsız ve sabittir.
    if (path.toUpperCase() == 'INBOX') return SpecialUse.inbox;

    final leaf = foldForSearch(leafName(path, delimiter)).trim();
    final full = foldForSearch(path.replaceAll(delimiter, ' ')).trim();

    for (final entry in _names.entries) {
      for (final candidate in entry.value) {
        if (leaf == candidate) return entry.key;
      }
    }
    // Ad tam eşleşmediyse, `INBOX.Sent Items` gibi birleşik yollarda ara.
    for (final entry in _names.entries) {
      for (final candidate in entry.value) {
        if (full.endsWith(' $candidate') || full == candidate) {
          return entry.key;
        }
      }
    }
    return SpecialUse.custom;
  }

  /// Yan menüdeki sıralama. Taslaklar, Çöp Kutusu'nun hemen üzerindedir.
  static int sortOrderFor(SpecialUse use) => switch (use) {
        SpecialUse.inbox => 0,
        SpecialUse.sent => 10,
        SpecialUse.archive => 20,
        SpecialUse.drafts => 30,
        SpecialUse.trash => 40,
        SpecialUse.junk => 50,
        SpecialUse.custom => 100,
      };

  /// Kullanıcıya gösterilen Türkçe ad.
  static String displayName(SpecialUse use, String fallback) =>
      switch (use) {
        SpecialUse.inbox => 'Gelen Kutusu',
        SpecialUse.sent => 'Gönderilenler',
        SpecialUse.drafts => 'Taslaklar',
        SpecialUse.trash => 'Çöp Kutusu',
        SpecialUse.junk => 'İstenmeyen',
        SpecialUse.archive => 'Arşiv',
        SpecialUse.custom => fallback,
      };

  /// Bir klasörde silme işlemi kalıcı mı olmalı?
  ///
  /// Çöp Kutusu'nun içinde silmek kalıcıdır (EXPUNGE); başka yerde silmek
  /// iletiyi Çöp Kutusu'na taşır.
  static bool deleteIsPermanent(SpecialUse use) =>
      use == SpecialUse.trash || use == SpecialUse.junk;
}

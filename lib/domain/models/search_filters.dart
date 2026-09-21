import 'mail_models.dart';

/// Aramanın klasör kapsamı: standart bir klasör türü ya da kullanıcının
/// oluşturduğu bir klasör.
///
/// Klasör kimliği (`Mailboxes.id`) yerine tür/ad tutulur: arama "Tüm
/// Hesaplar" kapsamında çalışabilir ve her hesabın Gelen Kutusu'nun farklı
/// bir kimliği vardır — "Gelen Kutusu" seçeneği hepsini birden kapsar.
/// Özel klasörler ada göre eşleşir (hesaplar arasında aynı adlı klasörler
/// birleşir).
final class SearchFolder {
  /// Standart klasör (Gelen Kutusu, Taslaklar…) — [use] `custom` olamaz.
  const SearchFolder.standard(this.use)
    : assert(
        use != SpecialUse.custom,
        'Özel klasörler için SearchFolder.custom kullanılmalı',
      ),
      customName = null;

  /// Kullanıcının oluşturduğu klasör — [customName] ile eşleşir.
  const SearchFolder.custom(String this.customName) : use = SpecialUse.custom;

  /// Bir klasör satırının (tür + ad) karşılığı olan seçenek.
  factory SearchFolder.of(SpecialUse use, String name) =>
      use == SpecialUse.custom
      ? SearchFolder.custom(name)
      : SearchFolder.standard(use);

  final SpecialUse use;

  /// Yalnızca [use] `custom` iken dolu.
  final String? customName;

  @override
  bool operator ==(Object other) =>
      other is SearchFolder &&
      other.use == use &&
      other.customName == customName;

  @override
  int get hashCode => Object.hash(use, customName);
}

/// Arama sonuçlarını daraltan filtreler — arama ekranındaki "Filtreler"
/// sayfasının (Outlook'un filtre sayfası gibi) tüm seçimleri.
final class SearchFilters {
  const SearchFilters({
    this.withAttachmentsOnly = false,
    this.includeDeleted = false,
    this.folder,
  });

  /// Yalnızca ekli iletiler.
  final bool withAttachmentsOnly;

  /// "Tüm Klasörler" aramasına Çöp Kutusu'ndaki iletiler de dahil edilsin mi?
  /// Belirli bir [folder] seçiliyken etkisizdir: Çöp Kutusu ancak açıkça
  /// seçilerek aranır.
  final bool includeDeleted;

  /// `null` = "Tüm Klasörler".
  final SearchFolder? folder;

  /// Varsayılandan farklı (ve gerçekten etkili) filtre sayısı — "Filtrele"
  /// düğmesindeki rozet için. [includeDeleted] yalnızca "Tüm Klasörler"de
  /// etkili olduğundan başka bir klasör seçiliyken sayılmaz.
  int get activeCount =>
      (withAttachmentsOnly ? 1 : 0) +
      (includeDeleted && folder == null ? 1 : 0) +
      (folder != null ? 1 : 0);

  bool get isActive => activeCount > 0;

  SearchFilters copyWith({
    bool? withAttachmentsOnly,
    bool? includeDeleted,
    SearchFolder? Function()? folder,
  }) => SearchFilters(
    withAttachmentsOnly: withAttachmentsOnly ?? this.withAttachmentsOnly,
    includeDeleted: includeDeleted ?? this.includeDeleted,
    folder: folder != null ? folder() : this.folder,
  );

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.withAttachmentsOnly == withAttachmentsOnly &&
      other.includeDeleted == includeDeleted &&
      other.folder == folder;

  @override
  int get hashCode => Object.hash(withAttachmentsOnly, includeDeleted, folder);
}

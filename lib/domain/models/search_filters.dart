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

/// "Tarih" çipinin hızlı aralıkları (web'deki `DATE_PRESETS`).
enum SearchDatePreset {
  today('Bugün', 1),
  last7('Son 7 gün', 7),
  last30('Son 30 gün', 30);

  const SearchDatePreset(this.label, this.days);

  final String label;

  /// Bugün DÂHİL kaç gün ("Son 7 gün" = bugün ve ondan önceki altı gün).
  final int days;
}

/// Takvim gününün yerel gece yarısı (saat bilgisi atılır).
DateTime searchDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Arama sonuçlarını daraltan filtreler — arama ekranındaki filtre çiplerinin
/// (Ekli · Tarih · Klasörler · Gönderen · Alıcı) tüm seçimleri. Web
/// istemcisindeki `SearchFilterSet` ile aynı kurallar.
///
/// Tarih, iki YEREL takvim günüdür; ikisi de dahil ve ikisi de isteğe
/// bağlıdır: yalnızca [dateFrom] "o gün ve sonrası", yalnızca [dateTo] "o gün
/// ve öncesi", ikisi birden aradaki günler (uçlar dahil).
final class SearchFilters {
  const SearchFilters({
    this.withAttachmentsOnly = false,
    this.includeDeleted = false,
    this.folder,
    this.dateFrom,
    this.dateTo,
    this.sender,
    this.recipient,
    this.filesOnly = false,
  });

  /// Yalnızca ekli iletiler.
  final bool withAttachmentsOnly;

  /// "Tüm Klasörler" aramasına Çöp Kutusu'ndaki iletiler de dahil edilsin mi?
  /// Belirli bir [folder] seçiliyken etkisizdir: Çöp Kutusu ancak açıkça
  /// seçilerek aranır. Arama ekranı (web gibi) bunu her zaman `true` verir;
  /// çiplerde bir anahtarı yoktur ve rozete sayılmaz.
  final bool includeDeleted;

  /// `null` = "Tüm Klasörler".
  final SearchFolder? folder;

  /// İlk gün (dahil), yerel gece yarısı; `null` = alt sınır yok.
  final DateTime? dateFrom;

  /// Son gün (dahil), yerel gece yarısı; `null` = üst sınır yok.
  final DateTime? dateTo;

  /// Yalnızca bu adresten gelen iletiler (küçük harf).
  final String? sender;

  /// Yalnızca bu adrese gönderilen (Kime/Bilgi/Gizli) iletiler (küçük harf).
  final String? recipient;

  /// İleti yerine EKLERİ (dosyaları) listele ("Dosyalar" çipi). Mobile özgü:
  /// web'de yoktur. Metin boşsa en son ekler gözat modunda gelir.
  final bool filesOnly;

  /// Tarih filtresi var mı?
  bool get hasDate => dateFrom != null || dateTo != null;

  /// Yarı açık UTC penceresi (`after` ≤ tarih < `before`) — gün sınırları
  /// kullanıcının YEREL gece yarılarıdır. Uçlar ters ise (hiçbir ileti
  /// eşleşmez) `null` döner, tıpkı web'deki `toDateRange` gibi.
  ({DateTime? after, DateTime? before})? get dateRange {
    final from = dateFrom;
    final to = dateTo;
    if (from == null && to == null) return null;
    if (from != null && to != null && from.isAfter(to)) return null;
    return (
      after: from == null ? null : searchDay(from).toUtc(),
      before: to == null
          ? null
          : DateTime(to.year, to.month, to.day + 1).toUtc(),
    );
  }

  /// Varsayılandan farklı (ve gerçekten etkili) filtre sayısı — filtre
  /// düğmesindeki rozet için. [includeDeleted] bir filtre değil varsayılandır
  /// (bkz. alan açıklaması), sayılmaz.
  int get activeCount =>
      (withAttachmentsOnly ? 1 : 0) +
      (hasDate ? 1 : 0) +
      (folder != null ? 1 : 0) +
      (sender != null ? 1 : 0) +
      (recipient != null ? 1 : 0) +
      (filesOnly ? 1 : 0);

  bool get isActive => activeCount > 0;

  /// Metin olmadan da tam bir arama mı? Ekli, tarih, kişi ve klasör
  /// filtrelerinin her biri tek başına seçim yapar (web'deki
  /// `isRunnableSearch`): yalnızca "Ekli" tüm ekli iletileri, bir klasör o
  /// klasörü listeler; metin onların içinde daraltır.
  bool get selectsOnItsOwn => isActive;

  SearchFilters copyWith({
    bool? withAttachmentsOnly,
    bool? includeDeleted,
    SearchFolder? Function()? folder,
    DateTime? Function()? dateFrom,
    DateTime? Function()? dateTo,
    String? Function()? sender,
    String? Function()? recipient,
    bool? filesOnly,
  }) => SearchFilters(
    withAttachmentsOnly: withAttachmentsOnly ?? this.withAttachmentsOnly,
    includeDeleted: includeDeleted ?? this.includeDeleted,
    folder: folder != null ? folder() : this.folder,
    dateFrom: dateFrom != null ? dateFrom() : this.dateFrom,
    dateTo: dateTo != null ? dateTo() : this.dateTo,
    sender: sender != null ? sender() : this.sender,
    recipient: recipient != null ? recipient() : this.recipient,
    filesOnly: filesOnly ?? this.filesOnly,
  );

  /// İlk günü değiştirir; son günden sonraya düşerse son günü de ona çeker —
  /// filtre hiç ters kalmaz (web'deki `withDay`).
  SearchFilters withDateFrom(DateTime? day) {
    final from = day == null ? null : searchDay(day);
    final to = dateTo;
    return copyWith(
      dateFrom: () => from,
      dateTo: () => from != null && to != null && from.isAfter(to) ? from : to,
    );
  }

  /// Son günü değiştirir; ilk günden öncesine düşerse ilk günü de ona çeker.
  SearchFilters withDateTo(DateTime? day) {
    final to = day == null ? null : searchDay(day);
    final from = dateFrom;
    return copyWith(
      dateTo: () => to,
      dateFrom: () =>
          to != null && from != null && from.isAfter(to) ? to : from,
    );
  }

  /// Hızlı aralık: bugün ve önceki günler.
  SearchFilters withPreset(SearchDatePreset preset, DateTime now) {
    final today = searchDay(now);
    return copyWith(
      dateFrom: () =>
          DateTime(today.year, today.month, today.day - (preset.days - 1)),
      dateTo: () => today,
    );
  }

  /// Şu an etkin olan hızlı aralık (varsa).
  SearchDatePreset? activePreset(DateTime now) {
    for (final preset in SearchDatePreset.values) {
      final probe = const SearchFilters().withPreset(preset, now);
      if (probe.dateFrom == dateFrom && probe.dateTo == dateTo) return preset;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.withAttachmentsOnly == withAttachmentsOnly &&
      other.includeDeleted == includeDeleted &&
      other.folder == folder &&
      other.dateFrom == dateFrom &&
      other.dateTo == dateTo &&
      other.sender == sender &&
      other.recipient == recipient &&
      other.filesOnly == filesOnly;

  @override
  int get hashCode => Object.hash(
    withAttachmentsOnly,
    includeDeleted,
    folder,
    dateFrom,
    dateTo,
    sender,
    recipient,
    filesOnly,
  );
}

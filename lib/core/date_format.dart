/// Türkçe tarih biçimlendirme.
///
/// `intl` paketinin locale verisi çalışma anında yüklenmek zorunda olduğu için
/// (ve test ortamında bu ek kurulum gerektirdiği için) Türkçe ay/gün adları
/// burada sabit tutulur. Sonuç deterministiktir ve birim testlerde
/// doğrulanabilir.
library;

const List<String> _monthsShort = [
  'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', //
  'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
];

const List<String> _monthsLong = [
  'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', //
  'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
];

/// DateTime.weekday: 1 = Pazartesi ... 7 = Pazar
const List<String> _weekdaysShort = [
  'Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz',
];

const List<String> _weekdaysLong = [
  'Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar',
];

String _two(int value) => value.toString().padLeft(2, '0');

DateTime _dayOf(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Liste satırında gösterilen kısa tarih.
///
/// - Bugün → `14:23`
/// - Dün → `Dün`
/// - Son 7 gün → `Pzt`
/// - Bu yıl → `14 Eyl`
/// - Daha eski → `14.09.25`
String formatListDate(DateTime dateUtc, {DateTime? now}) {
  final local = dateUtc.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();

  final today = _dayOf(reference);
  final day = _dayOf(local);
  final diffDays = today.difference(day).inDays;

  if (diffDays == 0) return '${_two(local.hour)}:${_two(local.minute)}';
  if (diffDays == 1) return 'Dün';
  if (diffDays > 1 && diffDays < 7) return _weekdaysShort[local.weekday - 1];
  if (local.year == reference.year) {
    return '${local.day} ${_monthsShort[local.month - 1]}';
  }
  return '${_two(local.day)}.${_two(local.month)}.${_two(local.year % 100)}';
}

/// Mail detayında gösterilen uzun tarih.
///
/// `14 Eylül 2026 Pazartesi, 13:54`
String formatDetailDate(DateTime dateUtc) {
  final d = dateUtc.toLocal();
  return '${d.day} ${_monthsLong[d.month - 1]} ${d.year} '
      '${_weekdaysLong[d.weekday - 1]}, ${_two(d.hour)}:${_two(d.minute)}';
}

/// Liste gruplama başlığı: `Bugün`, `Dün`, `Geçen Hafta`, `Eylül 2026`.
String formatGroupHeader(DateTime dateUtc, {DateTime? now}) {
  final local = dateUtc.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final diffDays = _dayOf(reference).difference(_dayOf(local)).inDays;

  if (diffDays == 0) return 'Bugün';
  if (diffDays == 1) return 'Dün';
  if (diffDays < 7) return 'Geçen Hafta';
  if (diffDays < 30) return 'Bu Ay';
  return '${_monthsLong[local.month - 1]} ${local.year}';
}

/// Dosya boyutu: `1,4 MB`
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = value >= 10 ? value.round().toString() : value.toStringAsFixed(1);
  return '${rounded.replaceAll('.', ',')} ${units[unit]}';
}

/// Göreli süre: `az önce`, `5 dk önce`, `2 sa önce`, `3 gün önce`.
String formatRelative(DateTime dateUtc, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(dateUtc);
  if (diff.isNegative || diff.inSeconds < 45) return 'az önce';
  if (diff.inMinutes < 60) return '${diff.inMinutes} dk önce';
  if (diff.inHours < 24) return '${diff.inHours} sa önce';
  if (diff.inDays < 30) return '${diff.inDays} gün önce';
  return formatListDate(dateUtc, now: reference);
}

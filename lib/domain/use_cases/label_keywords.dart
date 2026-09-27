import '../../core/turkish.dart';

/// Bir etiket adından IMAP özel anahtar kelimesi üretir.
///
/// IMAP anahtar kelimeleri boşluk ve Türkçe karakter içeremez; bu yüzden ad
/// ASCII küçük harfe katlanıp alfasayısal olmayan karakterler `_` ile
/// değiştirilir ve `kaydet_` önekiyle işaretlenir. Üretilen değer
/// `Labels.imapKeyword` sütununda saklanır ve [SyncEngine] sunucudan gelen
/// anahtar kelimeleri tekrar görünen ada çevirirken bu değeri kullanır —
/// aksi hâlde arayüzde ham anahtar kelime (`kaydet_kisisel` gibi) görünür ve
/// etikete göre filtreleme hiçbir sonuç bulamaz.
String labelImapKeyword(String name) =>
    'kaydet_${foldForSearch(name).replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

/// [labelImapKeyword]'ün hesap içinde ÇAKIŞMAYAN hâli.
///
/// Farklı adlar aynı ASCII karşılığına düşebilir ("Kişisel" / "Kisisel",
/// "A B" / "A-B"): ortak bir anahtar kelime iki etiketin birbirini açıp
/// kapatmasına yol açar. [taken] hesabın mevcut anahtar kelimeleridir; çakışma
/// varsa `_2`, `_3`… eklenir.
String uniqueLabelKeyword(String name, Iterable<String> taken) {
  final base = labelImapKeyword(name);
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  var suffix = 2;
  while (used.contains('${base}_$suffix')) {
    suffix++;
  }
  return '${base}_$suffix';
}

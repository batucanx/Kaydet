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

/// Sunucudan gelen ham bayrak listesinden etiket anahtar kelimelerini ayıklar:
/// `\` ile başlayan sistem bayrakları ve `$Forwarded` (iletme durumu) etiket
/// değildir. IMAP anahtar kelimeleri büyük/küçük harfe duyarsızdır; sunucu
/// yazıldığı biçimde döndürebildiği için küçük harfe katlanır. Sonuç yinelenensiz
/// ve sıralıdır (yerelde saklanan değer ham karşılaştırmada kararlı kalsın).
List<String> normalizedKeywords(Iterable<String> flags) {
  final keywords = <String>{
    for (final flag in flags)
      if (flag.isNotEmpty &&
          !flag.startsWith(r'\') &&
          flag.toLowerCase() != r'$forwarded')
        flag.toLowerCase(),
  };
  return keywords.toList()..sort();
}

/// Anahtar kelimeleri hesabın etiket adlarına çevirir.
///
/// [namesByKeyword] küçük harfli anahtar kelime → görünen ad eşlemesidir.
/// Eşleşmeyen anahtar kelimeler (henüz yerelde olmayan ya da başka istemcinin
/// etiketi) elenir — ham hâliyle gösterilmeleri anlamsızdır — ama çağıran
/// ham anahtar kelimeleri SAKLAR ([normalizedKeywords]); etiket sonradan
/// gelirse ileti bu listeden yeniden çözülür. Sıra, web istemcisiyle aynı
/// olacak şekilde ada göredir.
List<String> labelNamesForKeywords(
  Iterable<String> keywords,
  Map<String, String> namesByKeyword,
) {
  final names = <String>{
    for (final keyword in keywords) ?namesByKeyword[keyword.toLowerCase()],
  };
  return names.toList()
    ..sort((a, b) => foldForSearch(a).compareTo(foldForSearch(b)));
}

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

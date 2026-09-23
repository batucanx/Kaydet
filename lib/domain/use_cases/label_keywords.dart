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

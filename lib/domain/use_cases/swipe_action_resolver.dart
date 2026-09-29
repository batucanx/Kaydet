import '../../data/services/app_settings.dart';
import '../models/mail_models.dart';

/// Bir kaydırmanın o an gerçekte yapacağı eylem.
///
/// Kullanıcının seçtiği [SwipeAction] genel varsayılandır; klasöre ve iletinin
/// durumuna göre değişebilir (bkz. [SwipeActionResolver.resolve]). Arayüz
/// yalnızca bu sonucu çizer ve çalıştırır.
enum EffectiveSwipe {
  none,
  archive,
  moveToInbox,
  delete,
  markRead,
  markUnread,
  pin,
  unpin,

  /// İlk kurulum yer tutucusu: Çekme seçenekleri ekranını açar.
  configure,
}

/// Seçilen kaydırma eylemini bulunulan klasör ve ileti durumuna göre nihai
/// eyleme çevirir. Saf bir fonksiyondur (Flutter/DB bağımlılığı yok), bu
/// yüzden tek başına test edilir.
///
/// Kurallar:
/// - Arşivle / Oku ve arşivle: Arşiv, Çöp Kutusu ve İstenmeyen'de anlamsızdır
///   (zaten oradadır ya da geri yüklenmek istenir) → "Gelen Kutusuna taşı".
/// - Sil: her yerde "sil"; klasöre göre çöpe taşıma/kalıcı silme ve onay,
///   mevcut silme akışının (`deleteMessagesWithUndo`, `confirmDelete`) işidir.
/// - Okundu: okunmuşsa okunmadı yapar, değilse okundu (aç/kapa).
/// - Sabitle: sabitliyse sabitlemeyi kaldırır, değilse sabitler (aç/kapa).
/// - Taslak/yerel kayıtlar sunucuya hiç gitmemiştir: yalnızca silinebilir,
///   diğer eylemler kapalıdır.
abstract final class SwipeActionResolver {
  static EffectiveSwipe resolve({
    required SwipeAction selected,
    required SpecialUse? folder,
    required bool isDraftOrLocal,
    required bool isSeen,
    required bool isFlagged,
  }) {
    if (isDraftOrLocal || folder == SpecialUse.drafts) {
      return selected == SwipeAction.delete
          ? EffectiveSwipe.delete
          : EffectiveSwipe.none;
    }

    final restoresToInbox =
        folder == SpecialUse.archive ||
        folder == SpecialUse.trash ||
        folder == SpecialUse.junk;

    return switch (selected) {
      SwipeAction.none => EffectiveSwipe.none,
      SwipeAction.configure => EffectiveSwipe.configure,
      SwipeAction.delete => EffectiveSwipe.delete,
      SwipeAction.archive || SwipeAction.readAndArchive =>
        restoresToInbox ? EffectiveSwipe.moveToInbox : EffectiveSwipe.archive,
      SwipeAction.toggleRead =>
        isSeen ? EffectiveSwipe.markUnread : EffectiveSwipe.markRead,
      SwipeAction.pin => isFlagged ? EffectiveSwipe.unpin : EffectiveSwipe.pin,
    };
  }
}

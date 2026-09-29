import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/swipe_action_resolver.dart';

/// Seçilen kaydırma eyleminin klasöre ve ileti durumuna göre nihai eyleme
/// çevrilmesi.
void main() {
  EffectiveSwipe resolve(
    SwipeAction selected, {
    SpecialUse folder = SpecialUse.inbox,
    bool draft = false,
    bool seen = false,
    bool flagged = false,
  }) => SwipeActionResolver.resolve(
    selected: selected,
    folder: folder,
    isDraftOrLocal: draft,
    isSeen: seen,
    isFlagged: flagged,
  );

  test('Gelen Kutusu + Arşivle → arşivle', () {
    expect(resolve(SwipeAction.archive), EffectiveSwipe.archive);
  });

  test('Arşiv + Arşivle → Gelen Kutusuna taşı', () {
    expect(
      resolve(SwipeAction.archive, folder: SpecialUse.archive),
      EffectiveSwipe.moveToInbox,
    );
  });

  test('Çöp ve İstenmeyen + Arşivle → Gelen Kutusuna taşı', () {
    for (final folder in [SpecialUse.trash, SpecialUse.junk]) {
      expect(
        resolve(SwipeAction.archive, folder: folder),
        EffectiveSwipe.moveToInbox,
      );
      expect(
        resolve(SwipeAction.readAndArchive, folder: folder),
        EffectiveSwipe.moveToInbox,
      );
    }
  });

  test('Sil her klasörde sil', () {
    for (final folder in SpecialUse.values) {
      expect(resolve(SwipeAction.delete, folder: folder), EffectiveSwipe.delete);
    }
  });

  test('Sabitle aç/kapa', () {
    expect(resolve(SwipeAction.pin), EffectiveSwipe.pin);
    expect(resolve(SwipeAction.pin, flagged: true), EffectiveSwipe.unpin);
  });

  test('Okundu aç/kapa', () {
    expect(resolve(SwipeAction.toggleRead), EffectiveSwipe.markRead);
    expect(
      resolve(SwipeAction.toggleRead, seen: true),
      EffectiveSwipe.markUnread,
    );
  });

  test('Yok → eylem yok', () {
    expect(resolve(SwipeAction.none), EffectiveSwipe.none);
  });

  test('taslak/yerel kayıt yalnızca silinebilir', () {
    expect(resolve(SwipeAction.delete, draft: true), EffectiveSwipe.delete);
    expect(resolve(SwipeAction.archive, draft: true), EffectiveSwipe.none);
    expect(resolve(SwipeAction.pin, draft: true), EffectiveSwipe.none);
    expect(
      resolve(SwipeAction.archive, folder: SpecialUse.drafts),
      EffectiveSwipe.none,
    );
  });

  test('yönler birbirinden bağımsızdır', () {
    const settings = AppSettings();
    expect(settings.swipeRight, SwipeAction.configure);
    expect(settings.swipeLeft, SwipeAction.delete);
    final changed = settings.copyWith(swipeRight: SwipeAction.pin);
    expect(changed.swipeRight, SwipeAction.pin);
    expect(changed.swipeLeft, SwipeAction.delete);
  });

  test('ilk kurulum: sağa "Ayarla" yer tutucusu, sola sil', () {
    const settings = AppSettings();
    expect(settings.swipeRight, SwipeAction.configure);
    expect(settings.swipeLeft, SwipeAction.delete);
    expect(resolve(SwipeAction.configure), EffectiveSwipe.configure);
    // Taslakta ayarla da kapalıdır (yalnızca sil açık).
    expect(resolve(SwipeAction.configure, draft: true), EffectiveSwipe.none);
  });
}

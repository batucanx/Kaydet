import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/notification_intent.dart';
import 'package:kaydet/data/services/notification_service.dart';

NotificationIntent _remote({String? eventId = 'evt-1', int uid = 7}) =>
    NotificationIntent.remote(
      RemoteMailTarget(
        uid: uid,
        accountId: 2,
        folder: 'INBOX',
        uidValidity: 1000,
        messageId: '<a@b>',
        eventId: eventId,
      ),
    );

void main() {
  late PendingNotificationIntents store;

  setUp(() => store = PendingNotificationIntents());

  test('yakalanan niyet tüketilene dek kaybolmaz', () {
    expect(store.capture(_remote()), isTrue);
    expect(store.pending?.uid, 7);
    final taken = store.take();
    expect(taken?.uid, 7);
    expect(store.pending, isNull);
  });

  test('yakalama, dinleyiciyi eşzamanlı uyarır', () {
    var notified = 0;
    store.changes.listen((_) => notified++);
    store.capture(_remote());
    expect(notified, 1);
  });

  test('aynı bildirim bekliyorsa ikinci kez yakalanmaz', () {
    expect(store.capture(_remote()), isTrue);
    expect(store.capture(_remote()), isFalse);
  });

  test('tüketilmiş APNs bildirimi aynı kimlikle tekrar gelirse yok sayılır', () {
    store.capture(_remote());
    store.take();
    expect(store.capture(_remote()), isFalse);
    expect(store.pending, isNull);
  });

  test('farklı kimlikli bildirim işlenir', () {
    store.capture(_remote());
    store.take();
    expect(store.capture(_remote(eventId: 'evt-2', uid: 8)), isTrue);
  });

  test('daha yeni dokunuş bekleyenin yerine geçer', () {
    store.capture(_remote(eventId: 'a', uid: 1));
    store.capture(_remote(eventId: 'b', uid: 2));
    expect(store.take()?.uid, 2);
    expect(store.take(), isNull);
  });

  test('yerel dokunuş soğuk açılışta çift teslimde bir kez işlenir', () {
    const tap = NotificationTap(42, NotificationTapKind.open);
    expect(store.capture(NotificationIntent.local(tap)), isTrue);
    store.take();
    expect(store.capture(NotificationIntent.local(tap)), isFalse);
  });

  test('Yanıtla ile gövde dokunuşu ayrı niyetlerdir', () {
    const open = NotificationTap(42, NotificationTapKind.open);
    const reply = NotificationTap(42, NotificationTapKind.reply);
    store.capture(NotificationIntent.local(open));
    store.take();
    expect(store.capture(NotificationIntent.local(reply)), isTrue);
  });

  test('uzak niyet sunucu tanımlayıcılarını taşır', () {
    final intent = _remote();
    expect(intent.isLocal, isFalse);
    expect(intent.accountId, 2);
    expect(intent.folderPath, 'INBOX');
    expect(intent.uidValidity, 1000);
    expect(intent.messageIdHeader, '<a@b>');
  });

  test('RemoteMailTarget kanal yanıtını ayrıştırır, uid yoksa null döner', () {
    final target = RemoteMailTarget.fromChannel({
      'accountId': 3,
      'uid': 9,
      'folder': 'INBOX',
      'uidValidity': 55,
      'messageId': '<m@x>',
      'eventId': 'E',
    });
    expect(target?.uid, 9);
    expect(target?.eventId, 'E');
    expect(RemoteMailTarget.fromChannel({'accountId': 3}), isNull);
    expect(RemoteMailTarget.fromChannel(null), isNull);
    // Native taraf eksik alanlar için NSNull yollar.
    expect(
      RemoteMailTarget.fromChannel({'uid': 1, 'folder': null})?.folder,
      isNull,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/new_mail_notifier.dart';
import 'package:kaydet/data/repositories/notification_ledger.dart';
import 'package:kaydet/data/repositories/remote_push_sync.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/notification_service.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Gösterilen bildirimleri kaydeder (gerçek platform eklentisine dokunmaz).
class _RecordingNotifications extends NotificationService {
  final List<({int messageId, int accountId, String? label})> shown = [];
  final List<int> summaries = [];

  @override
  Future<void> showNewMail(MessageRow message, {String? accountLabel}) async {
    shown.add((
      messageId: message.id,
      accountId: message.accountId,
      label: accountLabel,
    ));
  }

  @override
  Future<void> refreshGroupSummary(
    int accountId, {
    String? accountLabel,
  }) async {
    summaries.add(accountId);
  }

  Set<int> idsFor(int accountId) => {
    for (final s in shown)
      if (s.accountId == accountId) s.messageId,
  };
}

/// Bir hesabın IMAP bağlantısı + eşitleme motoru (gerçek uygulamada arka plan
/// işçisi, ön plan servisi ya da arayüz bunu kurar).
class _Mailbox {
  _Mailbox(this.accountId, this.imap, this.connection, this.engine);

  final int accountId;
  final FakeImapService imap;
  final MailConnection connection;
  final SyncEngine engine;
  late MailboxRow inbox;
  int _nextUid = 1;

  /// Sunucuya yeni bir ileti düşürür; UID'sini döndürür.
  int deliver({bool seen = false, DateTime? date}) {
    final uid = _nextUid++;
    imap.seedInbox([
      envelope(
        uid: uid,
        subject: 'Konu $uid',
        seen: seen,
        date:
            date ?? DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      ),
    ]);
    return uid;
  }
}

/// Çok hesaplı bildirim hattı: hangi yol eşitlerse eşitlesin, her hesabın
/// yeni iletisi tam bir kez bildirilir; bir hesabın durumu diğerini etkilemez.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late InMemorySecureStore secureStore;
  late _RecordingNotifications notifications;
  late NewMailNotifier notifier;
  late List<_Mailbox> boxes;

  Future<_Mailbox> addAccount(String email) async {
    final id = await db.insertAccount(
      AccountsCompanion.insert(
        email: email,
        username: email,
        imapHost: 'mail.example.com',
        smtpHost: 'mail.example.com',
      ),
    );
    await secureStore.writePassword(id, 'sifre');
    final imap = FakeImapService();
    final connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
      keepAlive: false,
    );
    final engine = SyncEngine(database: db, connection: connection);
    final box = _Mailbox(id, imap, connection, engine);
    final mailboxes = await engine.syncMailboxes(id);
    box.inbox = (mailboxes as Ok<List<MailboxRow>>).value.firstWhere(
      (m) => m.specialUse == SpecialUse.inbox,
    );
    return box;
  }

  /// Gelen Kutusu'nu eşitler; sonucu BİLDİRİMSİZ döndürür (bildirim üretmeyen
  /// bir yolu — ör. "Tüm Hesaplar" görünümü ya da yarıda kesilen bir işçiyi —
  /// temsil eder).
  Future<SyncOutcome> syncOnly(_Mailbox box) async {
    final fresh = (await db.mailboxById(box.inbox.id))!;
    final result = await box.engine.syncMailbox(
      accountId: box.accountId,
      mailbox: fresh,
    );
    return (result as Ok<SyncOutcome>).value;
  }

  /// Eşitler VE bildirir (FCM işçisinin yaptığı).
  Future<SyncOutcome> syncAndNotify(_Mailbox box) async {
    final outcome = await syncOnly(box);
    await notifier.notifyNew(accountId: box.accountId, outcome: outcome);
    return outcome;
  }

  /// Her hesapta ilk indirmeyi yapıp bildirim defterini bugüne kurar.
  Future<void> baseline(_Mailbox box) async {
    box.deliver(seen: true);
    final outcome = await syncAndNotify(box);
    expect(outcome.initialDownload, isTrue);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = createTestDatabase();
    secureStore = InMemorySecureStore();
    notifications = _RecordingNotifications();
    notifier = NewMailNotifier(
      database: db,
      notifications: notifications,
      ledger: NotificationLedger(database: db),
    );
    boxes = [
      for (var i = 1; i <= 5; i++) await addAccount('hesap$i@example.com'),
    ];
    for (final box in boxes) {
      await baseline(box);
    }
    notifications.shown.clear();
  });

  tearDown(() async {
    for (final box in boxes) {
      await box.connection.disconnect();
      await box.imap.dispose();
    }
    await db.close();
  });

  test('5 hesabın her birine gelen ileti KENDİ hesabı etiketiyle bildirilir', () async {
    final delivered = <int, int>{};
    for (final box in boxes) {
      delivered[box.accountId] = box.deliver();
    }

    for (final box in boxes) {
      await syncAndNotify(box);
    }

    for (final box in boxes) {
      expect(notifications.idsFor(box.accountId), hasLength(1), reason: 'hesap ${box.accountId}');
    }
    expect(notifications.shown, hasLength(5));
    final labels = notifications.shown.map((s) => s.label).toSet();
    expect(labels, {for (var i = 1; i <= 5; i++) 'hesap$i@example.com'});
  });

  test('hesapların bildirimi sırayla bağımsızdır: birinin gelişi diğerlerini tetiklemez/engellemez', () async {
    boxes[2].deliver();
    await syncAndNotify(boxes[2]);
    expect(notifications.idsFor(boxes[2].accountId), hasLength(1));
    expect(notifications.shown, hasLength(1));

    boxes[4].deliver();
    boxes[0].deliver();
    await syncAndNotify(boxes[0]);
    await syncAndNotify(boxes[4]);

    expect(notifications.idsFor(boxes[0].accountId), hasLength(1));
    expect(notifications.idsFor(boxes[4].accountId), hasLength(1));
    expect(notifications.idsFor(boxes[1].accountId), isEmpty);
    expect(notifications.idsFor(boxes[3].accountId), isEmpty);
  });

  test('BİLDİRİMSİZ bir yol iletiyi çekse bile sonraki turda hesap sessiz KALMAZ '
      '("Tüm Hesaplar" eşitlemesi ya da yarıda kesilen işçi)', () async {
    final other = boxes[3]; // kullanıcının o an baktığı hesap DEĞİL
    other.deliver();

    // Yol A: iletiyi yerele yazar ama bildirim üretmez.
    final consumed = await syncOnly(other);
    expect(consumed.newMessageIds, hasLength(1));
    expect(notifications.shown, isEmpty);

    // Yol B (FCM işçisi): iletiyi artık "yeni" bulmaz...
    final later = await syncOnly(other);
    expect(later.newMessageIds, isEmpty);
    // ...ama bildirim defteri bildirilmemiş iletiyi yakalar.
    await notifier.notifyNew(accountId: other.accountId, outcome: later);

    expect(notifications.idsFor(other.accountId), hasLength(1));
  });

  test('aynı ileti ikinci kez bildirilmez (çift bildirim yok)', () async {
    final box = boxes[1];
    box.deliver();
    final outcome = await syncOnly(box);

    await notifier.notifyNew(accountId: box.accountId, outcome: outcome);
    await notifier.notifyNew(accountId: box.accountId, outcome: outcome);
    await notifier.notifyNew(accountId: box.accountId, outcome: const SyncOutcome());

    expect(notifications.idsFor(box.accountId), hasLength(1));
    expect(notifications.shown, hasLength(1));
  });

  test('iletiyi yerele yazıp bildirimden önce ölen işçinin bıraktığı bildirim AĞSIZ tamamlanır', () async {
    final box = boxes[0];
    box.deliver();
    await syncOnly(box); // işçi burada öldü: bildirim hiç gösterilmedi
    expect(notifications.shown, isEmpty);

    // Bir sonraki tur ağ gerektirmeden, boş sonuçla bile bildirimi gösterir.
    await notifier.notifyNew(accountId: box.accountId, outcome: const SyncOutcome());

    expect(notifications.idsFor(box.accountId), hasLength(1));
  });

  test('bir hesabın bekleyen bildirimi diğer hesabın turunda gösterilmez (hesap başına defter)', () async {
    boxes[0].deliver();
    boxes[1].deliver();
    final o0 = await syncOnly(boxes[0]);
    await syncOnly(boxes[1]);

    await notifier.notifyNew(accountId: boxes[0].accountId, outcome: o0);

    expect(notifications.idsFor(boxes[0].accountId), hasLength(1));
    expect(notifications.idsFor(boxes[1].accountId), isEmpty);

    // Hesap 1'in sırası geldiğinde kendi bekleyeni gösterilir.
    await notifier.notifyNew(accountId: boxes[1].accountId, outcome: const SyncOutcome());
    expect(notifications.idsFor(boxes[1].accountId), hasLength(1));
  });

  test('yeni eklenen hesabın geçmişi bildirilmez; sonraki ileti bildirilir', () async {
    final fresh = await addAccount('yeni@example.com');
    fresh.deliver(); // eski ileti
    fresh.deliver();
    final initial = await syncOnly(fresh);
    expect(initial.initialDownload, isTrue);
    await notifier.notifyNew(accountId: fresh.accountId, outcome: initial);
    expect(notifications.shown, isEmpty);

    fresh.deliver();
    await syncAndNotify(fresh);

    expect(notifications.idsFor(fresh.accountId), hasLength(1));
    boxes.add(fresh); // tearDown temizlesin
  });

  test('okunmuş ve 2 günden eski iletiler bildirilmez', () async {
    final box = boxes[2];
    box.deliver(seen: true);
    box.deliver(date: DateTime.now().toUtc().subtract(const Duration(days: 5)));
    await syncAndNotify(box);

    expect(notifications.shown, isEmpty);
  });

  test('UIDVALIDITY değişince eski iletiler bildirim yağdırmaz', () async {
    final box = boxes[1];
    box.deliver();
    await syncAndNotify(box);
    expect(notifications.shown, hasLength(1));
    notifications.shown.clear();

    // Sunucu klasörü yeniden numaralandırdı: tüm iletiler yeni UID ile geri gelir.
    box.imap.store['INBOX']!.clear();
    box.imap.uidValidity = 2222;
    final uid = box.deliver();
    expect(uid, greaterThan(0));
    final outcome = await syncOnly(box);
    expect(outcome.resynced, isTrue);
    await notifier.notifyNew(accountId: box.accountId, outcome: outcome);

    // Klasör baştan indirildi: zaten bildirilmiş iletiler ikinci kez bildirilmez.
    expect(notifications.idsFor(box.accountId), isEmpty);

    // Sonraki gerçek ileti yine bildirilir.
    box.deliver();
    await syncAndNotify(box);
    expect(notifications.idsFor(box.accountId), hasLength(1));
  });

  test('iOS (sunucu push\'u bildirimi kendisi gösterir): yerel bildirim üretilmez', () async {
    final ios = NewMailNotifier(
      database: db,
      notifications: notifications,
      remotePushShowsAlerts: true,
      ledger: NotificationLedger(database: db),
    );
    final box = boxes[0];
    box.deliver();
    final outcome = await syncOnly(box);

    await ios.notifyNew(accountId: box.accountId, outcome: outcome);

    expect(notifications.shown, isEmpty);
  });

  group('iOS: sunucu push bildirimi gösterir', () {
    NewMailNotifier iosNotifier(Future<bool> Function(int) covers) =>
        NewMailNotifier(
          database: db,
          notifications: notifications,
          remotePushShowsAlerts: true,
          ledger: NotificationLedger(database: db),
          serverCoversAccount: covers,
        );

    test('sunucunun izlediği hesapta yerel bildirim çift bildirim olmasın diye bastırılır', () async {
      final ios = iosNotifier((_) async => true);
      boxes[0].deliver();
      final outcome = await syncOnly(boxes[0]);
      await ios.notifyNew(accountId: boxes[0].accountId, outcome: outcome);
      expect(notifications.shown, isEmpty);
    });

    test('sunucunun İZLEYEMEDİĞİ hesap yerel bildirimle korunur; diğer hesaplar bastırılmaya devam eder', () async {
      final uncovered = boxes[3].accountId;
      final ios = iosNotifier((id) async => id != uncovered);
      for (final box in boxes) {
        box.deliver();
      }

      for (final box in boxes) {
        final outcome = await syncOnly(box);
        await ios.notifyNew(accountId: box.accountId, outcome: outcome);
      }

      expect(notifications.idsFor(uncovered), hasLength(1));
      expect(notifications.shown, hasLength(1));
    });
  });

  group('ServerPushCoverage', () {
    test('kayıtlı sağlıksız hesapları bilir, okunamazsa sunucuyu izliyor sayar', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = SharedPrefsRegistrationStore(prefs);
      await store.write(const RegistrationSnapshot(unhealthy: {7}));

      final coverage = ServerPushCoverage();
      expect(await coverage.covers(7), isFalse);
      expect(await coverage.covers(8), isTrue);

      final broken = ServerPushCoverage(() async => throw StateError('yok'));
      expect(await broken.covers(7), isTrue);
    });
  });

  test('defter olmasa da (eklenti yok) eski davranış korunur: tur sonucundaki iletiler bildirilir', () async {
    final plain = NewMailNotifier(database: db, notifications: notifications);
    final box = boxes[4];
    box.deliver();
    final outcome = await syncOnly(box);

    await plain.notifyNew(accountId: box.accountId, outcome: outcome);

    expect(notifications.idsFor(box.accountId), hasLength(1));
  });
}

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_repository.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/label_keywords.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Regresyon: etiketler sunucuya IMAP özel anahtar kelimesi (`kaydet_...`)
/// olarak yazılıyor ama bu anahtar kelime `Labels.imapKeyword`'e hiç
/// kaydedilmiyordu. Sunucudan geri okunan bayraklar bu yüzden ham anahtar
/// kelimeyle `messages.labelsJson`'a yazılıyordu: arayüzde "Kişisel" yerine
/// "kaydet_kisisel" görünüyor, etikete göre filtreleme (adla karşılaştırdığı
/// için) hiçbir sonuç bulamıyordu. Bkz. `AccountRepository.createLabel`,
/// `SyncEngine._labelNamesByKeyword`.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late MailConnection connection;
  late SyncEngine sync;
  late MailRepository repository;
  late int accountId;
  late MailboxRow inbox;

  const labelName = 'Kişisel';

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    final secureStore = InMemorySecureStore();

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');

    connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
    );
    sync = SyncEngine(database: db, connection: connection);
    repository = MailRepository(
      database: db,
      connection: connection,
      syncEngine: sync,
      smtpService: FakeSmtpService(),
    );

    await db.insertLabel(
      LabelsCompanion.insert(
        accountId: accountId,
        name: labelName,
        imapKeyword: Value(labelImapKeyword(labelName)),
      ),
    );

    final mailboxes = await sync.syncMailboxes(accountId);
    inbox = (mailboxes as Ok<List<MailboxRow>>).value.firstWhere(
      (m) => m.specialUse == SpecialUse.inbox,
    );
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  test('etiket sunucudan geri okunduğunda görünen ada çevrilir, ham anahtar '
      'kelime olarak kalmaz', () async {
    imap.seedInbox([envelope(uid: 1, subject: 'Fatura')]);
    await sync.syncMailbox(accountId: accountId, mailbox: inbox);

    final message = await db.messageByUid(inbox.id, 1);
    expect(message, isNotNull);

    await repository.setLabel(
      messageIds: [message!.id],
      labelName: labelName,
      add: true,
    );
    await repository.waitForQueue();

    // Yerelde hemen görünen ad tutulur.
    final afterLocalAdd = await db.messageByUid(inbox.id, 1);
    expect(afterLocalAdd!.labelsJson, contains(labelName));

    // Sunucuya ham anahtar kelime STORE edilmiş olmalı.
    final keyword = labelImapKeyword(labelName);
    expect(
      imap.commandLog.any((c) => c.contains('store:$keyword:+')),
      isTrue,
      reason: 'komutlar: ${imap.commandLog}',
    );

    // Başka bir cihazda/sekmede olduğu gibi klasör baştan senkronize
    // edilince (bkz. `SyncEngine._syncFlags`) sunucu yalnızca ham anahtar
    // kelimeyi döner — bu adım eşlemenin bunu tekrar görünen ada
    // çevirdiğini doğrular.
    final refreshedInbox = await db.mailboxById(inbox.id);
    await sync.syncMailbox(accountId: accountId, mailbox: refreshedInbox!);

    final afterSync = await db.messageByUid(inbox.id, 1);
    expect(afterSync!.labelsJson, contains(labelName));
    expect(afterSync.labelsJson, isNot(contains(keyword)));
  });

  group('etiket iletiden sonra geldiğinde', () {
    Future<MessageRow> syncedMessage() async {
      await sync.syncMailbox(accountId: accountId, mailbox: inbox);
      return (await db.messageByUid(inbox.id, 1))!;
    }

    Future<void> resync() async {
      final refreshed = await db.mailboxById(inbox.id);
      await sync.syncMailbox(accountId: accountId, mailbox: refreshed!);
    }

    test('yerelde olmayan etiketin anahtar kelimesi saklanır, etiket sonradan '
        'gelince ileti onu kendiliğinden gösterir', () async {
      imap.seedInbox([
        envelope(
          uid: 1,
          subject: 'Heartbeat',
          extraFlags: [labelImapKeyword(labelName), 'kaydet_web_client'],
        ),
      ]);
      final message = await syncedMessage();

      // "Web Client" bu cihazda henüz yok: yalnızca bilinen etiket görünür,
      // ama ham anahtar kelime atılmaz.
      expect(message.labelsJson, '["$labelName"]');
      expect(
        message.keywordsJson,
        contains('kaydet_web_client'),
        reason: 'ham anahtar kelime saklanmalı',
      );

      // Etiket ayar belgesiyle (ya da elle) sonradan gelir.
      await db.insertLabel(
        LabelsCompanion.insert(
          accountId: accountId,
          name: 'Web Client',
          imapKeyword: const Value('kaydet_web_client'),
        ),
      );
      expect(await db.reapplyLabelNames(accountId), 1);

      final after = await db.messageByUid(inbox.id, 1);
      expect(after!.labelsJson, '["$labelName","Web Client"]');
    });

    test('sunucuda sonradan eklenen bilinmeyen anahtar kelime bayrak '
        'eşitlemesinde de saklanır', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncedMessage();

      // Başka bir istemci (web) hem yeni etiketi oluşturup hem atar; bayrak
      // eşitlemesi ayar belgesinden ÖNCE çalışır.
      imap.seedInbox([
        envelope(uid: 1, extraFlags: ['kaydet_finans']),
      ]);
      await resync();
      var row = await db.messageByUid(inbox.id, 1);
      expect(row!.labelsJson, '[]');
      expect(row.keywordsJson, '["kaydet_finans"]');

      await db.insertLabel(
        LabelsCompanion.insert(
          accountId: accountId,
          name: 'Finans',
          imapKeyword: const Value('kaydet_finans'),
        ),
      );
      await db.reapplyLabelNames(accountId);
      row = await db.messageByUid(inbox.id, 1);
      expect(row!.labelsJson, '["Finans"]');
    });

    test('anahtar kelime büyük/küçük harfe duyarsız eşleşir', () async {
      imap.seedInbox([
        envelope(
          uid: 1,
          extraFlags: [labelImapKeyword(labelName).toUpperCase()],
        ),
      ]);
      final message = await syncedMessage();
      expect(message.labelsJson, '["$labelName"]');
    });

    test('silinen etiketin adı iletilerden kalkar', () async {
      imap.seedInbox([
        envelope(uid: 1, extraFlags: [labelImapKeyword(labelName)]),
      ]);
      await syncedMessage();

      final label = (await db.labelsOf(accountId)).single;
      await db.deleteLabel(label.id);
      await db.reapplyLabelNames(accountId);

      final after = await db.messageByUid(inbox.id, 1);
      expect(after!.labelsJson, '[]');
    });

    test(
      'ham anahtar kelimesi bilinmeyen iletinin etiketlerine dokunulmaz',
      () async {
        imap.seedInbox([envelope(uid: 1)]);
        final message = await syncedMessage();
        await (db.update(
          db.messages,
        )..where((m) => m.id.equals(message.id))).write(
          const MessagesCompanion(
            labelsJson: Value('["Yerel"]'),
            keywordsJson: Value(null),
          ),
        );

        expect(await db.reapplyLabelNames(accountId), 0);
        final after = await db.messageByUid(inbox.id, 1);
        expect(after!.labelsJson, '["Yerel"]');
      },
    );

    test(
      'sunucusu etiket desteklemeyen hesapta yerel etiketler ezilmez',
      () async {
        imap.seedInbox([envelope(uid: 1)]);
        final message = await syncedMessage();
        await db.updateAccountFields(
          accountId,
          const AccountsCompanion(supportsKeywords: Value(false)),
        );
        await db.updateMessage(
          message.id,
          const MessagesCompanion(labelsJson: Value('["Kişisel"]')),
        );

        expect(await db.reapplyLabelNames(accountId), 0);
        final after = await db.messageByUid(inbox.id, 1);
        expect(after!.labelsJson, '["Kişisel"]');
      },
    );

    test('yerel etiket ekleme ham anahtar kelimeyi de günceller', () async {
      imap.seedInbox([envelope(uid: 1)]);
      final message = await syncedMessage();

      await repository.setLabel(
        messageIds: [message.id],
        labelName: labelName,
        add: true,
      );
      await repository.waitForQueue();

      var row = await db.messageByUid(inbox.id, 1);
      expect(row!.keywordsJson, '["${labelImapKeyword(labelName)}"]');
      // Etiketlerin yeniden çözülmesi yerel ekleme geri almaz.
      await db.reapplyLabelNames(accountId);
      row = await db.messageByUid(inbox.id, 1);
      expect(row!.labelsJson, '["$labelName"]');

      await repository.setLabel(
        messageIds: [message.id],
        labelName: labelName,
        add: false,
      );
      await repository.waitForQueue();
      row = await db.messageByUid(inbox.id, 1);
      expect(row!.keywordsJson, '[]');
      expect(row.labelsJson, '[]');
    });
  });
}

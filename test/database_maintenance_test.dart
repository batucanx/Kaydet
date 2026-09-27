import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/test_db.dart';

/// Yerel önbelleğin bakımı: gövde budama, ek dosyalarının yaşam döngüsü,
/// toplu sorgular.
void main() {
  late AppDatabase db;
  late int accountId;
  late int inboxId;

  setUp(() async {
    db = createTestDatabase();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    inboxId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen Kutusu',
        specialUse: const Value(SpecialUse.inbox),
      ),
    );
  });

  tearDown(() => db.close());

  MessagesCompanion serverMessage(int uid) => MessagesCompanion.insert(
    accountId: accountId,
    mailboxId: inboxId,
    dateUtc: DateTime.utc(2026, 9, 14, 10, 30),
    uid: Value(uid),
    subject: Value('Konu $uid'),
  );

  Future<MessageRow> insertServerMessage(int uid) async {
    await db.upsertServerMessages([serverMessage(uid)]);
    return (await db.messageByUid(inboxId, uid))!;
  }

  Future<void> ageBodies() => db.customStatement(
    'UPDATE message_bodies SET fetched_at = ?',
    [
      DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 60))
              .millisecondsSinceEpoch ~/
          1000,
    ],
  );

  group('gövde budama', () {
    test('budanan iletinin `bodyFetchedAt` değeri sıfırlanır', () async {
      final message = await insertServerMessage(1);
      await db.upsertBody(messageId: message.id, plainText: 'içerik');
      expect((await db.messageById(message.id))!.bodyFetchedAt, isNotNull);
      await ageBodies();

      final pruned = await db.pruneOldBodies();

      expect(pruned, 1);
      expect(await db.bodyOf(message.id), isNull);
      // Aksi hâlde `MailRepository.ensureBody` "zaten indirilmiş" sanıp bu
      // iletiyi kalıcı olarak boş bırakırdı.
      expect((await db.messageById(message.id))!.bodyFetchedAt, isNull);
    });

    test('taslak ve kuyruktaki iletinin gövdesi budanmaz', () async {
      final draftId = await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          subject: const Value('Taslak'),
          isLocalOnly: const Value(true),
          isDraft: const Value(true),
        ),
      );
      final queuedId = await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          subject: const Value('Gönderilecek'),
          isLocalOnly: const Value(true),
          outboxState: const Value(OutboxState.queued),
        ),
      );
      await db.upsertBody(messageId: draftId, plainText: 'taslak metni');
      await db.upsertBody(messageId: queuedId, plainText: 'gönderilecek metin');
      final server = await insertServerMessage(1);
      await db.upsertBody(messageId: server.id, plainText: 'sunucu metni');
      await ageBodies();

      final pruned = await db.pruneOldBodies();

      // Yalnızca sunucudan yeniden indirilebilen gövde budandı. Diğerleri TEK
      // kopyadır: silinseler taslak boş açılır, kuyruktaki ileti boş gönderilir.
      expect(pruned, 1);
      expect((await db.bodyOf(draftId))!.plainText, 'taslak metni');
      expect((await db.bodyOf(queuedId))!.plainText, 'gönderilecek metin');
      expect(await db.bodyOf(server.id), isNull);
      expect((await db.messageById(draftId))!.bodyFetchedAt, isNotNull);
    });

    test('yeterince yeni gövde budanmaz', () async {
      final message = await insertServerMessage(1);
      await db.upsertBody(messageId: message.id, plainText: 'içerik');

      expect(await db.pruneOldBodies(), 0);
      expect(await db.bodyOf(message.id), isNotNull);
    });
  });

  group('ek dosyaları', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('kaydet_db_'));
    tearDown(() => temp.deleteSync(recursive: true));

    File createFile(String relative) {
      final file = File('${temp.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync('içerik');
      return file;
    }

    Future<void> addAttachment(
      int messageId,
      File file, {
      required bool outgoing,
    }) => db.addAttachment(
      AttachmentsCompanion.insert(
        messageId: messageId,
        fileName: Value(file.uri.pathSegments.last),
        localPath: Value(file.path),
        isOutgoing: Value(outgoing),
      ),
    );

    test('ileti silinince indirilmiş ek dosyası da silinir', () async {
      final message = await insertServerMessage(1);
      final downloaded = createFile('ekler/${message.id}/7/rapor.pdf');
      final userFile = createFile('kullanici/ozgecmis.pdf');
      await addAttachment(message.id, downloaded, outgoing: false);
      await addAttachment(message.id, userFile, outgoing: true);

      await db.deleteMessages([message.id]);

      expect(downloaded.existsSync(), isFalse);
      // Boşalan ara klasörler de temizlenir; `ekler` dizininin kendisi kalır.
      expect(Directory('${temp.path}/ekler/${message.id}').existsSync(), isFalse);
      expect(Directory('${temp.path}/ekler').existsSync(), isTrue);
      // Yazma ekranından eklenen dosyaya buradan dokunulmaz.
      expect(userFile.existsSync(), isTrue);
    });

    test('hesap silinince ek dosyaları da silinir', () async {
      final message = await insertServerMessage(1);
      final downloaded = createFile('ekler/${message.id}/7/sozlesme.pdf');
      await addAttachment(message.id, downloaded, outgoing: false);

      await db.wipeAccount(accountId);

      expect(downloaded.existsSync(), isFalse);
    });

    test('klasör içeriği temizlenince (UIDVALIDITY) ek dosyaları silinir', () async {
      final message = await insertServerMessage(1);
      final downloaded = createFile('ekler/${message.id}/7/fatura.pdf');
      await addAttachment(message.id, downloaded, outgoing: false);

      await db.purgeMailboxMessages(inboxId);

      expect(downloaded.existsSync(), isFalse);
    });

    test('`ekler` dizini dışındaki bir yol asla silinmez', () async {
      final message = await insertServerMessage(1);
      final outside = createFile('baska/onemli.docx');
      await addAttachment(message.id, outside, outgoing: false);

      await db.deleteMessages([message.id]);

      expect(outside.existsSync(), isTrue);
    });
  });

  group('giden ek dosyaları', () {
    test('yalnızca hâlâ gerekli olanlar etkin sayılır', () async {
      final draftId = await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          isLocalOnly: const Value(true),
          isDraft: const Value(true),
        ),
      );
      await db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: draftId,
          localPath: const Value('/depo/taslak.pdf'),
          isOutgoing: const Value(true),
        ),
      );

      // Gönderilmiş ve Gönderilenler'e yazılmış (sunucuda UID'si var).
      final sent = await insertServerMessage(1);
      await db.updateMessage(
        sent.id,
        const MessagesCompanion(outboxState: Value(OutboxState.sent)),
      );
      await db.addAttachment(
        AttachmentsCompanion.insert(
          messageId: sent.id,
          localPath: const Value('/depo/gonderildi.pdf'),
          isOutgoing: const Value(true),
        ),
      );

      final active = await db.activeOutgoingAttachmentPaths();

      expect(active, {'/depo/taslak.pdf'});
      // Tümü ise (paylaşım süpürücüsünün kullandığı) ayrı bir sorgudur.
      expect(await db.outgoingAttachmentPaths(), {
        '/depo/taslak.pdf',
        '/depo/gonderildi.pdf',
      });
    });
  });

  group('toplu sorgular', () {
    test('messagesByUids yalnızca istenen UID\'leri döner', () async {
      for (final uid in [1, 2, 3]) {
        await insertServerMessage(uid);
      }

      final rows = await db.messagesByUids(inboxId, [1, 3, 99]);

      expect(rows.keys, unorderedEquals([1, 3]));
      expect(rows[1]!.subject, 'Konu 1');
    });

    test('messagesByUids SQLite değişken sınırını aşan listeyi de işler', () async {
      await insertServerMessage(1);

      final rows = await db.messagesByUids(inboxId, List.generate(2000, (i) => i + 1));

      expect(rows.keys, [1]);
    });

    test('binlerce iletiyi silmek değişken sınırına takılmaz', () async {
      final ids = <int>[];
      for (var uid = 1; uid <= 1200; uid++) {
        ids.add(await db.insertLocalMessage(serverMessage(uid)));
      }

      await db.deleteMessages(ids);

      expect(await db.countMessages(inboxId), 0);
    });
  });
}

import 'dart:convert';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/date_format.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_repository.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void main() {
  group('formatScheduleDate', () {
    final now = DateTime(2026, 9, 27, 10, 0); // Pazar

    test('aynı gün için "Bugün HH:mm" biçiminde gösterir', () {
      final todayEvening = DateTime(2026, 9, 27, 18, 30);
      expect(formatScheduleDate(todayEvening, now: now), 'Bugün 18:30');
    });

    test('ertesi gün için "Yarın HH:mm" biçiminde gösterir', () {
      final tomorrow = DateTime(2026, 9, 28, 8, 30);
      expect(formatScheduleDate(tomorrow, now: now), 'Yarın 08:30');
    });

    test('aynı hafta içindeki günler için gün adıyla gösterir', () {
      final tuesday = DateTime(2026, 9, 29, 9, 15);
      expect(formatScheduleDate(tuesday, now: now), 'Salı 09:15');
    });

    test('daha ileri tarihler için gün, ay adı ve saat gösterir', () {
      final nextMonth = DateTime(2026, 10, 15, 14, 0);
      expect(formatScheduleDate(nextMonth, now: now), '15 Ekim 14:00');
    });
  });

  group('MailRepository - Undo Send & Schedule Send', () {
    late AppDatabase db;
    late InMemorySecureStore secureStore;
    late FakeImapService imap;
    late MailConnection connection;
    late SyncEngine sync;
    late MailRepository repository;
    late int accountId;

    setUp(() async {
      db = createTestDatabase();
      secureStore = InMemorySecureStore();
      imap = FakeImapService();

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

      // Klasörleri eşitle ki Taslaklar ve Gönderilenler oluşsun
      await sync.syncMailboxes(accountId);
    });

    tearDown(() async {
      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });

    test('queueSend varsayılan 5s undo gecikmesiyle kuyruğa alır ve cancelQueuedSend ile geri alınabilir', () async {
      final messageId = await repository.queueSend(
        accountId: accountId,
        to: 'alici@example.com',
        cc: '',
        bcc: '',
        subject: 'Geri Alınacak İleti',
        body: 'Geri alma testi',
      );

      expect(messageId, greaterThan(0));

      // Veritabanındaki iletiyi kontrol et
      var message = await db.messageById(messageId);
      expect(message?.outboxState, OutboxState.queued);
      expect(message?.isDraft, isFalse);

      // Bekleyen işlem kontrolü
      final pendingOps = await db.pendingSendOperationsFor(messageId);
      expect(pendingOps.length, 1);
      expect(pendingOps.first.nextAttemptAt, isNotNull);
      expect(
        pendingOps.first.nextAttemptAt!.isAfter(DateTime.now().toUtc()),
        isTrue,
      );

      // Geri alma işlemi
      final cancelled = await repository.cancelQueuedSend(messageId);
      expect(cancelled, isTrue);

      // Kuyruktaki işlem silinmiş olmalı
      final remainingOps = await db.pendingSendOperationsFor(messageId);
      expect(remainingOps.isEmpty, isTrue);

      // İleti yeniden Taslak durumuna dönmüş olmalı
      message = await db.messageById(messageId);
      expect(message?.outboxState, OutboxState.none);
      expect(message?.isDraft, isTrue);
    });

    test('ileri tarihli gönderim (scheduledAt) doğru zamanla kuyruğa alınır ve iptal edilebilir', () async {
      final scheduledTime = DateTime.now().toUtc().add(const Duration(hours: 12));

      final messageId = await repository.queueSend(
        accountId: accountId,
        to: 'alici@example.com',
        cc: '',
        bcc: '',
        subject: 'Zamanlanmış İleti',
        body: 'İleri tarihli test',
        scheduledAt: scheduledTime,
      );

      expect(messageId, greaterThan(0));

      final pendingOps = await db.pendingSendOperationsFor(messageId);
      expect(pendingOps.length, 1);
      final payload = jsonDecode(pendingOps.first.payloadJson) as Map<String, dynamic>;
      expect(payload['scheduledAt'], isNotNull);

      // İptal et
      final cancelled = await repository.cancelQueuedSend(messageId);
      expect(cancelled, isTrue);

      final message = await db.messageById(messageId);
      expect(message?.isDraft, isTrue);
      expect(message?.outboxState, OutboxState.none);
    });

    test('zaten gönderilmiş (OutboxState.sent) bir ileti geri alınamaz', () async {
      final messageId = await repository.queueSend(
        accountId: accountId,
        to: 'alici@example.com',
        cc: '',
        bcc: '',
        subject: 'Gönderilmiş İleti',
        body: 'Test',
      );

      // İletiyi yapay olarak sent durumuna çek
      await db.updateMessage(
        messageId,
        const MessagesCompanion(outboxState: Value(OutboxState.sent)),
      );

      final cancelled = await repository.cancelQueuedSend(messageId);
      expect(cancelled, isFalse);
    });
  });
}

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/account_repository.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Hesap doğrulama, şifre güncelleme ve etiketler.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late InMemorySecureStore secureStore;
  late MailConnection connection;
  late AccountRepository repository;
  late int accountId;

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    secureStore = InMemorySecureStore();
    connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
    );
    repository = AccountRepository(
      database: db,
      secureStore: secureStore,
      imapService: imap,
      smtpService: smtp,
      connection: connection,
    );

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    await secureStore.writePassword(accountId, 'eski');
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  group('şifre güncelleme', () {
    test('doğrulanan yeni şifre saklanır', () async {
      final result = await repository.updatePassword(accountId, 'yeni');

      expect(result.isOk, isTrue);
      expect(await secureStore.readPassword(accountId), 'yeni');
      expect(imap.commandLog.any((c) => c.startsWith('verify:')), isTrue);
    });

    test('IMAP şifreyi reddederse saklanmaz', () async {
      imap.failOnConnect = const AuthFailure(detail: 'yanlış şifre');

      final result = await repository.updatePassword(accountId, 'yanlis');

      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<AuthFailure>());
      expect(await secureStore.readPassword(accountId), 'eski');
    });

    test('SMTP şifreyi reddederse saklanmaz', () async {
      smtp.failOnVerify = const AuthFailure(detail: '535');

      final result = await repository.updatePassword(accountId, 'yanlis');

      expect(result, isA<Err<void>>());
      expect(await secureStore.readPassword(accountId), 'eski');
    });

    test('boş şifre reddedilir', () async {
      final result = await repository.updatePassword(accountId, '');

      expect(result, isA<Err<void>>());
      expect(await secureStore.readPassword(accountId), 'eski');
    });

    test('hesap ve yerel veri korunur', () async {
      final mailboxId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX',
          name: 'INBOX',
        ),
      );

      await repository.updatePassword(accountId, 'yeni');

      expect(await db.accountById(accountId), isNotNull);
      expect(await db.mailboxById(mailboxId), isNotNull);
    });

    test('doğrulama canlı oturumu kapatmaz', () async {
      await connection.ensureConnected(accountId);
      expect(imap.isConnected, isTrue);

      await repository.updatePassword(accountId, 'yeni');

      expect(imap.isConnected, isTrue);
    });
  });

  group('giriş', () {
    SignInRequest request(String email) => SignInRequest(
      email: email,
      password: 'sifre',
      imapHost: 'imap.ornek.com',
      imapPort: 993,
      imapSecurity: SocketSecurity.ssl,
      smtpHost: 'smtp.ornek.com',
      smtpPort: 465,
      smtpSecurity: SocketSecurity.ssl,
    );

    test(
      'yeni hesap denenirken etkin hesabın canlı oturumu kapanmaz',
      () async {
        await connection.ensureConnected(accountId);
        expect(imap.isConnected, isTrue);

        final result = await repository.signIn(request('yeni@ornek.com'));

        expect(result.isOk, isTrue);
        // Doğrulama ayrı, geçici bir bağlantıyla yapıldı.
        expect(imap.commandLog.any((c) => c.startsWith('verify:')), isTrue);
        expect(imap.isConnected, isTrue);
      },
    );

    test('hatalı bilgiyle giriş hesap oluşturmaz', () async {
      imap.failOnConnect = const AuthFailure();

      final result = await repository.signIn(request('yeni@ornek.com'));

      expect(result, isA<Err<int>>());
      expect(await db.allAccounts(), hasLength(1));
    });
  });

  group('etiketler', () {
    test(
      'aynı ASCII karşılığına düşen adlar ayrı anahtar kelime alır',
      () async {
        await repository.createLabel(
          accountId: accountId,
          name: 'Kişisel',
          toneIndex: 1,
        );
        await repository.createLabel(
          accountId: accountId,
          name: 'Kisisel',
          toneIndex: 2,
        );

        final labels = await db.labelsOf(accountId);
        final keywords = labels.map((l) => l.imapKeyword).toSet();

        expect(labels, hasLength(2));
        expect(keywords, hasLength(2));
        expect(keywords, contains('kaydet_kisisel'));
      },
    );

    test(
      'mevcut etiket yeniden oluşturulunca anahtar kelimesi korunur',
      () async {
        await repository.createLabel(
          accountId: accountId,
          name: 'Kişisel',
          toneIndex: 1,
        );
        await repository.createLabel(
          accountId: accountId,
          name: 'Kisisel',
          toneIndex: 2,
        );
        final before = (await db.labelsOf(
          accountId,
        )).firstWhere((l) => l.name == 'Kisisel').imapKeyword;

        await repository.createLabel(
          accountId: accountId,
          name: 'Kisisel',
          toneIndex: 7,
        );

        final after = (await db.labelsOf(
          accountId,
        )).firstWhere((l) => l.name == 'Kisisel');
        expect(after.imapKeyword, before);
        expect(after.toneIndex, 7);
      },
    );

    Future<int> taggedMessage(List<String> names) async {
      final mailboxId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX',
          name: 'Gelen Kutusu',
        ),
      );
      return db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: mailboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          labelsJson: Value(jsonEncode(names)),
        ),
      );
    }

    test(
      'yeniden adlandırma anahtar kelimeyi korur, iletileri günceller',
      () async {
        await repository.createLabel(
          accountId: accountId,
          name: 'Finans',
          toneIndex: 1,
        );
        final label = (await db.labelsOf(accountId)).single;
        final messageId = await taggedMessage(['Finans', 'Diğer']);

        final result = await repository.renameLabel(
          labelId: label.id,
          newName: '  Finans 2026 ',
        );

        expect(result.isOk, isTrue);
        final renamed = (await db.labelsOf(accountId)).single;
        expect(renamed.name, 'Finans 2026');
        expect(renamed.imapKeyword, label.imapKeyword);
        final message = await (db.select(
          db.messages,
        )..where((m) => m.id.equals(messageId))).getSingle();
        expect(jsonDecode(message.labelsJson), ['Finans 2026', 'Diğer']);
      },
    );

    test('boş ya da çakışan ad reddedilir, ad değişmez', () async {
      await repository.createLabel(
        accountId: accountId,
        name: 'Finans',
        toneIndex: 1,
      );
      await repository.createLabel(
        accountId: accountId,
        name: 'İş',
        toneIndex: 2,
      );
      final finans = (await db.labelsOf(
        accountId,
      )).firstWhere((l) => l.name == 'Finans');

      final empty = await repository.renameLabel(
        labelId: finans.id,
        newName: '   ',
      );
      final duplicate = await repository.renameLabel(
        labelId: finans.id,
        newName: 'iş',
      );

      expect(empty, isA<Err<void>>());
      expect(duplicate, isA<Err<void>>());
      expect((await db.labelsOf(accountId)).map((l) => l.name).toSet(), {
        'Finans',
        'İş',
      });
    });

    test('silme etiketi iletilerden de kaldırır', () async {
      await repository.createLabel(
        accountId: accountId,
        name: 'Finans',
        toneIndex: 1,
      );
      final label = (await db.labelsOf(accountId)).single;
      final messageId = await taggedMessage(['Finans', 'Diğer']);

      final result = await repository.deleteLabel(label.id);

      expect(result.isOk, isTrue);
      expect(await db.labelsOf(accountId), isEmpty);
      final message = await (db.select(
        db.messages,
      )..where((m) => m.id.equals(messageId))).getSingle();
      expect(jsonDecode(message.labelsJson), ['Diğer']);
    });
  });
}

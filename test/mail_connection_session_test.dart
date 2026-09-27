import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// `MailConnection`ın işlem kilidi: SELECT + komut dizileri araya başka bir
/// klasör/hesap seçimi girmeden, baştan sona çalışmalıdır.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late MailConnection connection;
  late int accountA;
  late int accountB;

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    final secureStore = InMemorySecureStore();

    Future<int> addAccount(String email) async {
      final id = await db.insertAccount(
        AccountsCompanion.insert(
          email: email,
          username: email,
          imapHost: 'mail.ornek.com',
          smtpHost: 'mail.ornek.com',
        ),
      );
      await secureStore.writePassword(id, 'sifre');
      return id;
    }

    accountA = await addAccount('a@ornek.com');
    accountB = await addAccount('b@ornek.com');
    connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
    );
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  group('bağlantının hangi hesaba ait olduğu', () {
    test('hesap yalnızca bağlantı kurulduktan sonra "bağlı" sayılır', () async {
      expect(connection.isConnectedTo(accountA), isFalse);

      await connection.ensureConnected(accountA);
      expect(connection.isConnectedTo(accountA), isTrue);
      expect(connection.isConnectedTo(accountB), isFalse);

      await connection.ensureConnected(accountB);
      expect(connection.isConnectedTo(accountA), isFalse);
      expect(connection.isConnectedTo(accountB), isTrue);
    });

    test('eşzamanlı farklı hesap bağlantıları sırayla kurulur', () async {
      final results = await Future.wait([
        connection.ensureConnected(accountA),
        connection.ensureConnected(accountB),
      ]);

      expect(results.every((result) => result.isOk), isTrue);
      // İkisi de gerçekten bağlandı (biri diğerinin bağlanmasını "zaten
      // bağlı" sayıp atlamadı) ve son istenen hesap kaldı.
      expect(
        imap.commandLog.where((command) => command.startsWith('connect:')),
        hasLength(2),
      );
      expect(connection.isConnectedTo(accountB), isTrue);
    });

    test('zaten bağlı hesap için yeniden bağlanılmaz', () async {
      await connection.ensureConnected(accountA);
      await connection.ensureConnected(accountA);

      expect(
        imap.commandLog.where((command) => command.startsWith('connect:')),
        hasLength(1),
      );
    });

    test('disconnectAccount yalnızca bağlantı o hesaba aitse kapatır', () async {
      await connection.ensureConnected(accountB);

      await connection.disconnectAccount(accountA);
      expect(imap.isConnected, isTrue);
      expect(connection.isConnectedTo(accountB), isTrue);

      await connection.disconnectAccount(accountB);
      expect(imap.isConnected, isFalse);
      expect(connection.isConnectedTo(accountB), isFalse);
    });
  });

  group('exclusive', () {
    test('iki işlem iç içe girmeden sırayla çalışır', () async {
      final events = <String>[];
      Future<Result<void>> task(String name) =>
          connection.exclusive<void>(accountA, () async {
            events.add('$name başladı');
            await Future<void>.delayed(const Duration(milliseconds: 20));
            events.add('$name bitti');
            return okVoid;
          });

      await Future.wait([task('1'), task('2'), task('3')]);

      expect(events, [
        '1 başladı',
        '1 bitti',
        '2 başladı',
        '2 bitti',
        '3 başladı',
        '3 bitti',
      ]);
    });

    test('bağlanılamazsa hatayı döner ve işlemi hiç çalıştırmaz', () async {
      imap.failOnConnect = const AuthFailure(detail: 'yanlış şifre');
      var ran = false;

      final result = await connection.exclusive<void>(accountA, () async {
        ran = true;
        return okVoid;
      });

      expect(result, isA<Err<void>>());
      expect(ran, isFalse);
    });

    test('işlem bir istisna fırlatsa da kilit serbest kalır', () async {
      await expectLater(
        connection.exclusive<void>(accountA, () async {
          throw StateError('beklenmeyen');
        }),
        throwsStateError,
      );

      final next = await connection.exclusive<void>(
        accountA,
        () async => okVoid,
      );
      expect(next.isOk, isTrue);
    });
  });

  group('selectVerified', () {
    Future<MailboxRow> mailboxWithValidity(int? validity) async {
      final id = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountA,
          path: 'INBOX',
          name: 'INBOX',
          specialUse: const Value(SpecialUse.inbox),
          uidValidity: Value(validity),
        ),
      );
      return (await db.mailboxById(id))!;
    }

    test('UIDVALIDITY aynıysa klasörü seçer', () async {
      final mailbox = await mailboxWithValidity(imap.uidValidity);

      final result = await connection.exclusive<MailboxState>(
        accountA,
        () => connection.selectVerified(mailbox),
      );

      expect(result, isA<Ok<MailboxState>>());
      expect(imap.selectedPath, 'INBOX');
    });

    test('UIDVALIDITY değişmişse yerel UID\'ler geçersizdir: hata döner', () async {
      final mailbox = await mailboxWithValidity(imap.uidValidity + 1);

      final result = await connection.exclusive<MailboxState>(
        accountA,
        () => connection.selectVerified(mailbox),
      );

      expect(result, isA<Err<MailboxState>>());
      expect(
        (result as Err<MailboxState>).failure,
        isA<UidValidityChangedFailure>(),
      );
    });

    test('yerelde UIDVALIDITY hiç kayıtlı değilse doğrulama atlanır', () async {
      final mailbox = await mailboxWithValidity(null);

      final result = await connection.exclusive<MailboxState>(
        accountA,
        () => connection.selectVerified(mailbox),
      );

      expect(result, isA<Ok<MailboxState>>());
    });
  });
}

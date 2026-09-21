import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/services/google_oauth_service.dart';
import 'package:kaydet/data/services/secure_store.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late GoogleOAuthService oauth;
  late MailConnection connection;

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    oauth = GoogleOAuthService();

    final secureStore = InMemorySecureStore();
    final accountId = await db.insertAccount(
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
      googleOAuth: oauth,
    );
    await connection.ensureConnected(accountId);
  });

  tearDown(() async {
    // Bağlantı kapanınca 4 dakikalık zamanlayıcı da iptal olur.
    await connection.disconnect();
    oauth.dispose();
    await imap.dispose();
    await db.close();
  });

  group('MailConnection canlılık denetimi', () {
    test('IDLE yokken NOOP gönderir', () async {
      await connection.keepAliveTick();

      expect(imap.commandLog, contains('noop'));
    });

    test('IDLE sürerken NOOP göndermez, IDLE\'ı bitirmez', () async {
      // NOOP, sürmekte olan IDLE'ı bitirir ve yeniden başlatan olmadığından
      // anlık güncellemeler bağlantıdan en fazla 4 dakika sonra duruyordu.
      await imap.startIdle();

      await connection.keepAliveTick();

      expect(imap.commandLog, isNot(contains('noop')));
      expect(imap.isIdling, isTrue);
    });

    test('bağlantı yokken hiçbir şey göndermez', () async {
      await imap.disconnect();

      await connection.keepAliveTick();

      expect(imap.commandLog, isNot(contains('noop')));
    });
  });
}

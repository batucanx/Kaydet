import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/install_credentials.dart';
import 'package:kaydet/data/services/push_backend_client.dart';
import 'package:kaydet/data/services/translation_client.dart';

class _FailingOnceStorage extends Fake implements FlutterSecureStorage {
  _FailingOnceStorage(this.values);

  final Map<String, String> values;
  int failures = 1;

  @override
  Future<String?> read({
    required String key,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) async {
    if (failures > 0) {
      failures--;
      throw StateError('Keystore hazır değil');
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) async {
    values[key] = value!;
  }
}

void main() {
  group('SecureInstallCredentials', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('ilk kullanımda üretir, sonra aynı kimliği döner', () async {
      final a = SecureInstallCredentials(const FlutterSecureStorage());
      final first = await a.load();
      expect(first.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(first.secret, matches(RegExp(r'^[0-9a-f]{64}$')));

      // Yeni örnek (uygulama yeniden başlatıldı): depodan okur.
      final b = SecureInstallCredentials(const FlutterSecureStorage());
      final second = await b.load();
      expect(second.id, first.id);
      expect(second.secret, first.secret);
    });

    test('eşzamanlı çağrılar tek kimlik üretir', () async {
      final s = SecureInstallCredentials(const FlutterSecureStorage());
      final all = await Future.wait([s.load(), s.load(), s.load()]);
      expect(all.map((c) => c.id).toSet(), hasLength(1));
    });

    test(
      'okuma hatasında yeni kimlik üretip üzerine YAZMAZ, sonra yeniden dener',
      () async {
        final storage = _FailingOnceStorage({
          SecureInstallCredentials.idKey: 'a' * 32,
          SecureInstallCredentials.secretKey: 'b' * 64,
        });
        final s = SecureInstallCredentials(storage);
        await expectLater(s.load(), throwsStateError);
        expect(storage.values[SecureInstallCredentials.idKey], 'a' * 32);

        final ok = await s.load();
        expect(ok.id, 'a' * 32);
        expect(ok.secret, 'b' * 64);
      },
    );
  });

  group('istemciler kurulum başlıklarını gönderir', () {
    late HttpServer server;
    final seen = <HttpHeaders>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add(request.headers);
        await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            request.uri.path == '/v1/translate'
                ? jsonEncode({
                    'translatedSubject': 's',
                    'segments': ['x'],
                    'cacheHit': false,
                    'nearLimit': false,
                  })
                : jsonEncode({'clientAccountIds': <int>[]}),
          );
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    PushBackendConfig config(InstallCredentialsSource? c) => PushBackendConfig(
      baseUrl: 'http://127.0.0.1:${server.port}',
      apiKey: 'key',
      credentials: c,
    );

    test('push istemcisi', () async {
      final client = HttpPushBackendClient(
        config(_Fixed(const InstallCredentials(id: 'id-1', secret: 'sec-1'))),
      );
      await client.listRegisteredAccounts('ab' * 32);
      client.close();
      expect(seen.single.value('authorization'), 'Bearer key');
      expect(seen.single.value('x-install-id'), 'id-1');
      expect(seen.single.value('x-install-secret'), 'sec-1');
    });

    test('çeviri istemcisi', () async {
      final client = HttpTranslationClient(
        config(_Fixed(const InstallCredentials(id: 'id-2', secret: 'sec-2'))),
      );
      await client.translate(
        const TranslationRequest(
          userId: 'user-000001',
          messageId: '1',
          sourceLanguage: 'auto',
          targetLanguage: 'tr',
          subject: 'Hi',
          segments: ['Hello'],
        ),
      );
      client.close();
      expect(seen.single.value('x-install-id'), 'id-2');
      expect(seen.single.value('x-install-secret'), 'sec-2');
    });

    test('kimlik kaynağı yoksa yalnızca Authorization gider', () async {
      final client = HttpPushBackendClient(config(null));
      await client.listRegisteredAccounts('ab' * 32);
      client.close();
      expect(seen.single.value('x-install-id'), isNull);
    });
  });
}

class _Fixed implements InstallCredentialsSource {
  _Fixed(this.value);

  final InstallCredentials value;

  @override
  Future<InstallCredentials> load() async => value;
}

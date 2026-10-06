import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/sieve_block.dart';

/// Web istemcisiyle AYNI test tablosu (`packages/domain/src/sieve/vectors.json` dosyasının kopyası).
/// İki gerçekleme birebir aynı betiği üretmek zorundadır; biri değişirse tablo ikisinde de güncellenir.
void main() {
  final vectors =
      (jsonDecode(File('test/fixtures/sieve_vectors.json').readAsStringSync())
              as List)
          .cast<Map<String, Object?>>();

  group('Sieve bloğu — ortak test vektörleri', () {
    for (final v in vectors) {
      test(v['name']! as String, () {
        final expected = v['expect']! as Map<String, Object?>;
        final result = applyBlockedSendersBlock(
          v['script']! as String,
          (v['emails']! as List).cast<String>(),
          v['junk']! as String,
        );
        expect(result, expected['script']);
        final emails = expected['emails'] as List?;
        expect(
          readBlockedSendersBlock(result),
          emails?.cast<String>(),
        );
      });
    }

    test('idempotent: aynı listeyi yeniden uygulamak hiçbir şeyi değiştirmez', () {
      for (final v in vectors) {
        final emails = (v['emails']! as List).cast<String>();
        final junk = v['junk']! as String;
        final once = applyBlockedSendersBlock(v['script']! as String, emails, junk);
        expect(
          applyBlockedSendersBlock(once, emails, junk),
          once,
          reason: v['name']! as String,
        );
      }
    });
  });

  group('Sieve bloğu — davranış', () {
    const user =
        'require ["fileinto"];\nif header :contains "subject" "invoice" {\n  fileinto "Billing";\n}\n';

    test('kaldırınca kullanıcının betiği aynen geri gelir', () {
      final added = applyBlockedSendersBlock(user, ['a@x.com'], 'Junk');
      expect(added, contains(sieveBegin));
      expect(applyBlockedSendersBlock(added, const [], 'Junk'), user);
    });

    test('kullanıcının require satırları bloktan önce, kuralları sonra kalır', () {
      final added = applyBlockedSendersBlock(user, ['a@x.com'], 'Junk');
      expect(
        added.indexOf('require ["fileinto"];'),
        lessThan(added.indexOf(sieveBegin)),
      );
      expect(added.indexOf(sieveEnd), lessThan(added.indexOf('invoice')));
    });

    test('bloğu olmayan betikten bir şey okunmaz', () {
      expect(readBlockedSendersBlock(user), isNull);
    });
  });
}

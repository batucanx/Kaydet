import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/secure_storage_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iç içe çağrı kendi kendini kilitlemez', () async {
    final result = await SecureStorageLock.run(
      () => SecureStorageLock.run(() async => 42),
    );
    expect(result, 42);
  });

  test('eşzamanlı erişimler sırayla çalışır, iç içe geçmez', () async {
    var running = 0;
    var maxRunning = 0;
    Future<void> job() => SecureStorageLock.run(() async {
      running++;
      if (running > maxRunning) maxRunning = running;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      running--;
    });

    await Future.wait([for (var i = 0; i < 6; i++) job()]);
    expect(maxRunning, 1);
  });

  group('kilit dosyası (diğer izolatları taklit eder)', () {
    late Directory dir;
    late File lockFile;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('kaydet_lock');
      lockFile = File('${dir.path}/secure_storage.lock');
      SecureStorageLock.useDirectoryForTesting(dir);
    });

    tearDown(() {
      SecureStorageLock.useDirectoryForTesting(null);
      dir.deleteSync(recursive: true);
    });

    test('başka sahip kilidi tutarken bekler, bırakınca çalışır', () async {
      lockFile.createSync();
      var ran = false;
      final pending = SecureStorageLock.run(() async => ran = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ran, isFalse);

      lockFile.deleteSync();
      await pending;
      expect(ran, isTrue);
      // Kendi kilidini de bırakır.
      expect(lockFile.existsSync(), isFalse);
    });

    test('ölü sahibin eski kilidi geçersiz sayılır', () async {
      lockFile.createSync();
      lockFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(await SecureStorageLock.run(() async => 'ok'), 'ok');
      expect(lockFile.existsSync(), isFalse);
    });
  });

  test('hata kilidi bırakır: sonraki erişim çalışır', () async {
    await expectLater(
      SecureStorageLock.run<void>(() async => throw StateError('x')),
      throwsStateError,
    );
    expect(await SecureStorageLock.run(() async => 'ok'), 'ok');
  });
}

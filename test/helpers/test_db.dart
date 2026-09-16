import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:kaydet/data/database/app_database.dart';

/// Testlerde gerçek SQLite kullanılır (taklit katman değil).
///
/// sqlite3 3.5+ kütüphaneyi Dart native-assets üzerinden sağlar; ana
/// makinede ek kurulum gerekmez. Böylece şema, indeksler ve FTS5 araması
/// gerçekten sınanır.
AppDatabase createTestDatabase() =>
    AppDatabase.forTesting(NativeDatabase.memory());

Value<T> v<T>(T value) => Value<T>(value);

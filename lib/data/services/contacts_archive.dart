import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Arşivlenmiş bir kişi (kullanım sayaçları dahil: yeniden girişte otomatik tamamlama sırası korunur).
class ArchivedContact {
  const ArchivedContact({
    required this.email,
    required this.name,
    required this.timesUsed,
    required this.lastUsedAt,
  });

  final String email;
  final String name;
  final int timesUsed;
  final DateTime lastUsedAt;

  Map<String, Object?> toJson() => {
    'email': email,
    'name': name,
    'timesUsed': timesUsed,
    'lastUsedAt': lastUsedAt.millisecondsSinceEpoch,
  };

  static ArchivedContact? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final email = raw['email'];
    if (email is! String || email.isEmpty) return null;
    final name = raw['name'];
    final used = raw['timesUsed'];
    final last = raw['lastUsedAt'];
    return ArchivedContact(
      email: email,
      name: name is String ? name : '',
      timesUsed: used is int ? used : 1,
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(last is int ? last : 0),
    );
  }
}

/// Hesaptan çıkışta silinen yerel veritabanı satırlarının yerine kişi defterini hesabın
/// E-POSTASINA göre saklar; aynı adresle yeniden giriş yapılınca defter geri gelir.
abstract interface class ContactsArchive {
  /// [email] hesabının defterini saklar (öncekinin yerine geçer). Boş liste kaydı siler.
  Future<void> save(String email, List<ArchivedContact> contacts);

  /// [email] hesabının saklı defteri; yoksa boş.
  Future<List<ArchivedContact>> read(String email);
}

String _normalize(String email) => email.trim().toLowerCase();

class PrefsContactsArchive implements ContactsArchive {
  const PrefsContactsArchive();

  static String _key(String email) =>
      'kaydet.contactsArchive.${_normalize(email)}';

  @override
  Future<void> save(String email, List<ArchivedContact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    if (contacts.isEmpty) {
      await prefs.remove(_key(email));
      return;
    }
    await prefs.setString(
      _key(email),
      jsonEncode([for (final c in contacts) c.toJson()]),
    );
  }

  @override
  Future<List<ArchivedContact>> read(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(email));
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (ArchivedContact.tryParse(item) case final c?) c,
      ];
    } on FormatException {
      return const [];
    }
  }
}

/// Testler için.
class MemoryContactsArchive implements ContactsArchive {
  final Map<String, List<ArchivedContact>> _data = {};

  @override
  Future<void> save(String email, List<ArchivedContact> contacts) async {
    if (contacts.isEmpty) {
      _data.remove(_normalize(email));
    } else {
      _data[_normalize(email)] = List.of(contacts);
    }
  }

  @override
  Future<List<ArchivedContact>> read(String email) async =>
      List.of(_data[_normalize(email)] ?? const []);
}

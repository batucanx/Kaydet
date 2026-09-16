import '../../core/turkish.dart';

/// Konuşma (thread) gruplama.
///
/// Düz IMAP sunucu tarafında konuşma grubu vermez (THREAD uzantısı her
/// sunucuda yoktur ve sonuçları kalıcı değildir). Bu yüzden gruplama
/// yereldir: `References` / `In-Reply-To` başlıkları birincil kaynaktır,
/// başlık yoksa normalleştirilmiş konu + katılımcılar yedek ölçüttür.
///
/// JWZ algoritmasının sadeleştirilmiş ve mobil için hızlandırılmış hâli.
abstract final class Threading {
  /// `<abc@host>` biçimindeki kimlikleri ayıklar.
  static List<String> parseReferences(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final matches = RegExp(r'<([^<>]+)>').allMatches(raw);
    final ids = matches.map((m) => m.group(1)!.trim()).toList();
    if (ids.isNotEmpty) return ids;
    // Bazı sunucular köşeli parantez koymaz.
    return raw
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s.contains('@'))
        .toList();
  }

  /// Tek bir kimliği normalleştirir.
  static String? normalizeId(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final match = RegExp(r'<([^<>]+)>').firstMatch(trimmed);
    final id = (match?.group(1) ?? trimmed).trim();
    return id.isEmpty ? null : id;
  }

  /// Konuya dayalı yedek anahtar.
  ///
  /// Message-ID başlığı olmayan iletiler (bazı otomatik gönderim sistemleri)
  /// için konuyu kullanır. Konu boşsa gruplama yapılmaz — boş konulu tüm
  /// iletilerin tek bir konuşmada toplanması istenmeyen bir sonuçtur.
  static String? subjectKey(String? subject) {
    final normalized = normalizeSubject(subject);
    if (normalized.isEmpty) return null;
    return 'subj:${foldForSearch(normalized)}';
  }

  /// Tek bir ileti için konuşma kimliği üretir.
  ///
  /// [knownThreads] daha önce hesaplanmış `messageId → threadId` eşlemesidir;
  /// yeni ileti bir ata iletiye bağlanırsa onun konuşmasına katılır.
  static String resolveThreadId({
    required String? messageId,
    required String? inReplyTo,
    required String? references,
    required String? subject,
    required Map<String, String> knownThreads,
  }) {
    final refs = <String>[
      ...parseReferences(references),
      if (normalizeId(inReplyTo) != null) normalizeId(inReplyTo)!,
    ];

    // 1. Atalardan biri bilinen bir konuşmaya aitse ona katıl.
    for (final ref in refs.reversed) {
      final existing = knownThreads[ref];
      if (existing != null) return existing;
    }

    // 2. Atalar bilinmiyorsa kökü konuşma kimliği yap.
    if (refs.isNotEmpty) return refs.first;

    // 3. Kendi Message-ID'si varsa konuşmanın kökü bu iletidir.
    final own = normalizeId(messageId);
    if (own != null) return own;

    // 4. Son çare: konu anahtarı. Konu da yoksa ileti kendi başına bir
    // konuşmadır — boş konulu tüm otomatik iletilerin tek bir dev konuşmada
    // birikmesi engellenir.
    return subjectKey(subject) ?? _uniqueFallbackId();
  }

  /// Eşleşecek hiçbir bilgisi olmayan iletiler için benzersiz kimlik.
  static int _fallbackCounter = 0;

  static String _uniqueFallbackId() =>
      'single:${DateTime.now().microsecondsSinceEpoch}:${_fallbackCounter++}';

  /// Bir grup ileti için toplu konuşma ataması.
  ///
  /// [items] tarih sırasına göre (eskiden yeniye) verilmelidir; böylece
  /// ata iletiler çocuklarından önce işlenir.
  static Map<int, String> assignThreads(List<ThreadInput> items) {
    final byMessageId = <String, String>{};
    final bySubject = <String, String>{};
    final result = <int, String>{};

    for (final item in items) {
      final threadId = resolveThreadId(
        messageId: item.messageId,
        inReplyTo: item.inReplyTo,
        references: item.references,
        subject: item.subject,
        knownThreads: byMessageId,
      );

      var finalThread = threadId;

      // Başlık bilgisi yoksa konu üzerinden birleştirmeyi dene.
      final hasHeaders = (item.messageId != null && item.messageId!.isNotEmpty) ||
          (item.references != null && item.references!.isNotEmpty) ||
          (item.inReplyTo != null && item.inReplyTo!.isNotEmpty);
      final subjKey = subjectKey(item.subject);

      if (!hasHeaders && subjKey != null) {
        finalThread = bySubject[subjKey] ?? threadId;
      }

      final own = normalizeId(item.messageId);
      if (own != null) byMessageId[own] = finalThread;
      if (subjKey != null) bySubject.putIfAbsent(subjKey, () => finalThread);

      result[item.localId] = finalThread;
    }

    return result;
  }
}

/// Konuşma hesaplaması için gereken en az bilgi.
class ThreadInput {
  const ThreadInput({
    required this.localId,
    required this.messageId,
    required this.inReplyTo,
    required this.references,
    required this.subject,
  });

  final int localId;
  final String? messageId;
  final String? inReplyTo;
  final String? references;
  final String? subject;
}

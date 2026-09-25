import 'dart:convert';

import 'package:path/path.dart' as p;

/// Sistem "Paylaş" menüsünden (Android Sharesheet / iOS Share Extension)
/// gelen tek bir paylaşımın, native katmandan Flutter'a taşınan hâli.
///
/// Native taraf dosyaları uygulamanın kendi `share_inbox/<id>/` dizinine
/// kopyalar ve yanına `manifest.json` yazar (bkz. `ShareIntakeService`); bu
/// sınıf o manifestin Dart karşılığıdır. Manifest GÜVENİLMEYEN girdidir —
/// dosya adları ve kimlik burada doğrulanır, yol dışarıdan gelen bir metinden
/// değil `root/<id>/<fileName>`den TÜRETİLİR.
final class SharePayload {
  const SharePayload({
    required this.id,
    required this.source,
    required this.receivedAt,
    required this.directory,
    this.files = const [],
    this.issues = const [],
    this.text,
    this.subject,
  });

  /// Bu paylaşımı benzersiz tanıyan kimlik (UUID). Aynı paylaşımın yaşam
  /// döngüsü nedeniyle iki kez işlenmesini engelleyen anahtar budur.
  final String id;

  /// `android-share` ya da `ios-share-extension`.
  final String source;

  final DateTime receivedAt;

  /// Dosyaların durduğu mutlak dizin (`<inbox>/<id>`).
  final String directory;

  /// Paylaşılan sıra korunarak.
  final List<SharedFile> files;

  /// Native tarafın kopyalayamadığı ya da reddettiği dosyalar.
  final List<ShareIssue> issues;

  /// Dosya olmayan paylaşımlarda (link, düz metin) gövdeye konacak metin.
  final String? text;

  /// Paylaşan uygulamanın verdiği konu/başlık (tarayıcıdaki sayfa başlığı gibi).
  final String? subject;

  bool get hasText => (text ?? '').trim().isNotEmpty;

  /// Ne dosya, ne metin, ne de hata taşıyor — gösterilecek hiçbir şey yok.
  bool get isEmpty => files.isEmpty && !hasText && issues.isEmpty;

  /// Kimlik dizin adı olarak kullanılır; yalnızca bu alfabeyle kabul edilir
  /// (yol ayırıcı, nokta vb. içeremez).
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9-]{8,64}$');

  static bool isValidId(String id) => _idPattern.hasMatch(id);

  /// Native katmanın döndürdüğü manifest metnini çözer. Bozuk/eksik/şüpheli
  /// manifest için `null` döner (çağıran atlar; uygulama çökmez).
  static SharePayload? tryParse(String manifestJson, {required String root}) {
    try {
      final decoded = jsonDecode(manifestJson);
      if (decoded is! Map<String, dynamic>) return null;

      final id = decoded['id'];
      if (id is! String || !isValidId(id)) return null;

      final directory = p.join(root, id);
      final files = <SharedFile>[];
      for (final raw in _list(decoded['files'])) {
        final file = SharedFile._tryParse(raw, directory: directory);
        if (file != null) files.add(file);
      }
      final issues = <ShareIssue>[
        for (final raw in _list(decoded['issues'])) ?ShareIssue._tryParse(raw),
      ];

      final receivedAtMs = decoded['receivedAtMs'];
      return SharePayload(
        id: id,
        source: _string(decoded['source']) ?? 'unknown',
        receivedAt: receivedAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(receivedAtMs, isUtc: true)
            : DateTime.now().toUtc(),
        directory: directory,
        files: files,
        issues: issues,
        text: _string(decoded['text']),
        subject: _string(decoded['subject']),
      );
    } on Object {
      return null;
    }
  }

  SharePayload copyWith({List<SharedFile>? files, List<ShareIssue>? issues}) =>
      SharePayload(
        id: id,
        source: source,
        receivedAt: receivedAt,
        directory: directory,
        files: files ?? this.files,
        issues: issues ?? this.issues,
        text: text,
        subject: subject,
      );

  static List<Object?> _list(Object? value) =>
      value is List ? value.cast<Object?>() : const [];

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

/// Paylaşımdaki tek bir dosya — `<inbox>/<id>/<fileName>` yolunda durur.
final class SharedFile {
  const SharedFile({
    required this.fileName,
    required this.mimeType,
    required this.path,
    required this.sizeBytes,
  });

  final String fileName;
  final String mimeType;

  /// Uygulamanın kendi dizinindeki mutlak yol; ek olarak `ComposeScreen`e bu
  /// verilir (bkz. `openComposeFromNavigator`).
  final String path;

  final int sizeBytes;

  static SharedFile? _tryParse(Object? raw, {required String directory}) {
    if (raw is! Map) return null;
    final name = raw['fileName'];
    if (name is! String || !isSafeFileName(name)) return null;
    final size = raw['sizeBytes'];
    final mime = raw['mimeType'];
    return SharedFile(
      fileName: name,
      mimeType: mime is String && mime.isNotEmpty
          ? mime
          : 'application/octet-stream',
      path: p.join(directory, name),
      sizeBytes: size is int ? size : 0,
    );
  }

  /// Ad, tek bir yol bileşeni olmalı: ayırıcı, `..`, boş ad ya da kontrol
  /// karakteri (yol geçişi/`\0` enjeksiyonu) içeremez. Native taraf adı zaten
  /// temizler; bu ikinci savunma hattıdır.
  static bool isSafeFileName(String name) {
    if (name.isEmpty || name.length > 255) return false;
    if (name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(r'\')) return false;
    for (final unit in name.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return false;
    }
    return true;
  }
}

/// Bir dosyanın neden eklenemediği.
enum ShareIssueCode {
  /// Dosya boyut sınırını aşıyor.
  tooLarge,

  /// Kaynak dosyaya erişilemedi / okunamadı / izin yok.
  unreadable,

  /// Dosya boş (0 bayt) ya da kopyası bozuk.
  empty,

  /// Yürütülebilir vb. — posta sunucularının reddettiği türler.
  blockedType,

  /// Diske yazılamadı (yer yok, paylaşılan konteynere erişilemedi…).
  storage,

  /// Tanınmayan hata kodu.
  unknown;

  static ShareIssueCode parse(Object? raw) => switch (raw) {
    'tooLarge' => tooLarge,
    'unreadable' => unreadable,
    'empty' => empty,
    'blockedType' => blockedType,
    'storage' => storage,
    _ => unknown,
  };
}

/// Eklenemeyen dosya ve nedeni; kullanıcıya gösterilir.
final class ShareIssue {
  const ShareIssue({required this.code, this.fileName});

  final ShareIssueCode code;
  final String? fileName;

  static ShareIssue? _tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['fileName'];
    return ShareIssue(
      code: ShareIssueCode.parse(raw['code']),
      fileName: name is String && name.isNotEmpty ? name : null,
    );
  }
}

/// Sıkça kullanılan hazır e-posta yanıt ve metin şablonu.
class QuickTemplate {
  const QuickTemplate({
    required this.id,
    required this.title,
    required this.content,
    this.isBuiltIn = false,
  });

  /// Benzersiz kimlik.
  final String id;

  /// Şablonun kısa başlığı (ör. "Bilgilerinizi aldım", "Toplantı Onayı").
  final String title;

  /// Şablonun tam gövde metni.
  final String content;

  /// Sistemin varsayılan olarak sunduğu şablon mu? (silinemez, sıfırlanabilir)
  final bool isBuiltIn;

  QuickTemplate copyWith({
    String? id,
    String? title,
    String? content,
    bool? isBuiltIn,
  }) =>
      QuickTemplate(
        id: id ?? this.id,
        title: title ?? this.title,
        content: content ?? this.content,
        isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'isBuiltIn': isBuiltIn,
      };

  factory QuickTemplate.fromJson(Map<String, dynamic> json) => QuickTemplate(
        id: json['id'] as String,
        title: json['title'] as String,
        content: json['content'] as String,
        isBuiltIn: json['isBuiltIn'] as bool? ?? false,
      );
}

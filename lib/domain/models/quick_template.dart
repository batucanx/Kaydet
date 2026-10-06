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

  /// Sistemin varsayılan olarak sunduğu şablon mu? Yalnızca bilgi
  /// amaçlıdır ("Yerleşik" rozeti) — kullanıcı bunları da diğerleri gibi
  /// düzenleyebilir ve silebilir, hepsini kullanmak istemeyebilir.
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

  @override
  bool operator ==(Object other) =>
      other is QuickTemplate &&
      other.id == id &&
      other.title == title &&
      other.content == content &&
      other.isBuiltIn == isBuiltIn;

  @override
  int get hashCode => Object.hash(id, title, content, isBuiltIn);

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

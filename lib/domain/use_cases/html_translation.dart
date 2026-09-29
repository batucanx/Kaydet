import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Bir HTML iletisinden çevrilecek düz metin parçalarını çıkarır ve çevrilmiş
/// parçaları AYNI yapıya geri yerleştirir.
///
/// Yalnızca metin düğümleri (`Text`) çevrilir; etiketler, öznitelikler
/// (`href`, `src`, `class`, `style`…), `<style>`/`<script>` ve `<head>`
/// olduğu gibi kalır. Karakter kotası da bu yüzden yalnızca [segments]
/// üzerinden hesaplanır: HTML işaretlemesi sunucuya hiç gitmez.
class TranslatableHtml {
  TranslatableHtml._(this._document, this._slots);

  final Document _document;
  final List<_Slot> _slots;

  /// Çevrilecek metinler; sırası [apply]'a verilecek listenin sırasıdır.
  List<String> get segments => [for (final s in _slots) s.text];

  /// Toplam çevrilebilir karakter sayısı (kod noktası).
  int get characterCount => segments.fold(0, (sum, s) => sum + s.runes.length);

  bool get isEmpty => _slots.isEmpty;

  /// Çevrilmiş [translated] parçalarını yerleştirip HTML'i döndürür.
  /// Parça sayısı uyuşmazsa `null` döner (yapı bozulmasın diye kısmi
  /// uygulama yapılmaz).
  String? apply(List<String> translated) {
    if (translated.length != _slots.length) return null;
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[i];
      slot.node.data = '${slot.leading}${translated[i]}${slot.trailing}';
    }
    return _document.outerHtml;
  }

  /// [html]'i ayrıştırır. Çevrilecek metin yoksa [isEmpty] `true` olur.
  static TranslatableHtml parse(String html) {
    final document = html_parser.parse(html);
    final slots = <_Slot>[];
    _collect(document.body ?? document.documentElement, slots);
    return TranslatableHtml._(document, slots);
  }

  // Bu etiketlerin içindeki metin içerik değildir (kod/stil) ya da çevrilmez.
  static const _skipTags = {
    'script',
    'style',
    'noscript',
    'head',
    'title',
    'template',
    'svg',
    'math',
    'textarea',
    'option',
  };

  // Hiç harf içermeyen metin (sayı, işaret, madde imi) çevrilecek bir şey değil.
  static final _hasLetter = RegExp(r'\p{L}', unicode: true);
  static final _edges = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');
  static final _whitespaceRun = RegExp(r'\s+');

  static void _collect(Node? root, List<_Slot> out) {
    if (root == null) return;
    for (final node in root.nodes) {
      if (node is Text) {
        final match = _edges.firstMatch(node.data);
        if (match == null) continue;
        // İç boşluklar HTML'de zaten tek boşluk gibi görünür; sıkıştırmak hem
        // çeviri kalitesini artırır hem gönderilen karakteri azaltır.
        final core = match.group(2)!.replaceAll(_whitespaceRun, ' ');
        if (core.isEmpty || !_hasLetter.hasMatch(core)) continue;
        out.add(_Slot(node, match.group(1)!, core, match.group(3)!));
      } else if (node is Element) {
        if (_skipTags.contains(node.localName)) continue;
        _collect(node, out);
      }
    }
  }
}

/// Düz metin iletiler için aynı sözleşme: her boş olmayan satır bir parçadır,
/// satır sonları ve girinti korunur.
class TranslatablePlainText {
  TranslatablePlainText._(this._lines, this._indexes);

  final List<String> _lines;
  final List<int> _indexes;

  List<String> get segments => [for (final i in _indexes) _lines[i].trim()];

  bool get isEmpty => _indexes.isEmpty;

  String? apply(List<String> translated) {
    if (translated.length != _indexes.length) return null;
    final out = List<String>.of(_lines);
    for (var k = 0; k < _indexes.length; k++) {
      final i = _indexes[k];
      final original = _lines[i];
      final leading = original.substring(
        0,
        original.length - original.trimLeft().length,
      );
      out[i] = '$leading${translated[k]}';
    }
    return out.join('\n');
  }

  static TranslatablePlainText parse(String text) {
    final lines = text.split('\n');
    final indexes = <int>[
      for (var i = 0; i < lines.length; i++)
        if (TranslatableHtml._hasLetter.hasMatch(lines[i])) i,
    ];
    return TranslatablePlainText._(lines, indexes);
  }
}

class _Slot {
  const _Slot(this.node, this.leading, this.text, this.trailing);

  final Text node;
  final String leading;
  final String text;
  final String trailing;
}

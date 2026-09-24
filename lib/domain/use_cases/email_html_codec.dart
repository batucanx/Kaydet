/// Yazma editörünün Quill Delta'sı ↔ e-posta HTML'i.
///
/// İki yönlü ve BİRBİRİNE göre tasarlanmıştır: [EmailHtmlCodec.encode] alıcıya
/// giden ve taslak olarak saklanan HTML'i üretir, [EmailHtmlCodec.decode] aynı
/// biçimi taslak yeniden açılırken editöre geri okur. Kütüphanedeki
/// `HtmlToDelta` bunun için kullanılamaz: ölçüldü — satır aralığını,
/// hizalamayı, boş satırları ve `<b>` içindeki `font-size`'ı düşürüyor.
///
/// Giden HTML'in kuralları (Gmail, Outlook masaüstü/mobil, Apple Mail):
/// * Yalnızca satır içi (inline) CSS; `<style>`/sınıf yok — istemciler
///   bunları ayıklayabilir.
/// * Her satır ayrı bir blok (`<div>`), taban yazı tipi/boyutu/satır aralığı
///   HER SATIRDA açıkça yazılır: alıcının varsayılanına (Outlook'ta bazen
///   Times New Roman) bırakılmaz, editörde görülenle aynı sonucu verir.
/// * Boyut/satır aralığı değerleri [ComposeFontSize]/[ComposeLineSpacing]
///   modelinden geçer; serbest değer yazılamaz.
/// * Ardışık boşluklar `&nbsp;` ile korunur; kullanıcı metni her zaman
///   kaçışlanır.
library;

import 'package:flutter_quill/quill_delta.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'compose_formatting.dart';

abstract final class EmailHtmlCodec {
  /// Giden HTML'in taban yazı tipi ailesi. Editördeki uygulama fontu alıcıda
  /// yoktur; her istemcide bulunan, ölçüleri birbirine yakın bir yığın.
  static const String fontFamily = 'Arial,Helvetica,sans-serif';

  /// Delta'yı e-posta HTML'ine çevirir. İçerik yoksa boş metin döner.
  static String encode(Delta delta) => _Encoder(delta).build();

  /// [encode]'un çıktısını (ve makul ölçüde yabancı HTML'i) Delta'ya çevirir.
  /// Çıktıdaki her öznitelik doğrulanmıştır; boyutlar 4 seviyeden birine
  /// oturtulur. Sonuç her zaman `\n` ile biterek geçerli bir Quill belgesidir.
  static Delta decode(String html) => _Decoder().run(html);
}

/// Dışarıdan gelen Delta'yı (yapıştırma) editöre girmeden önce temizler.
///
/// Beyaz liste yaklaşımı: tanınmayan her öznitelik atılır, boyut/satır
/// aralığı/renk doğrulanıp normalleştirilir, gömülü nesneler (görsel vb.)
/// çıkarılır — editörde bunları çizecek bir yapı yoktur ve giden HTML'e
/// de taşınamazlar.
abstract final class ComposeDeltaSanitizer {
  static Delta sanitize(Delta delta) {
    final result = Delta();
    for (final op in delta.toList()) {
      if (!op.isInsert) {
        result.push(op);
        continue;
      }
      final data = op.data;
      if (data is! String) continue;
      final attributes = sanitizeAttributes(op.attributes);
      result.insert(data, attributes.isEmpty ? null : attributes);
    }
    return result;
  }

  /// Beyaz listedeki öznitelikleri doğrulanmış değerleriyle döndürür.
  static Map<String, Object> sanitizeAttributes(Map<String, dynamic>? source) {
    final out = <String, Object>{};
    if (source == null) return out;
    for (final MapEntry(:key, :value) in source.entries) {
      switch (key) {
        case 'bold' || 'italic' || 'underline' || 'strike' || 'blockquote':
          if (value == true) out[key] = true;
        case 'size':
          final size = ComposeFontSize.fromAttribute(value)?.attributeValue;
          if (size != null) out[key] = size;
        case 'line-height':
          final height = ComposeLineSpacing.fromAttribute(
            value,
          )?.attributeValue;
          if (height != null) out[key] = height;
        case 'color' || 'background':
          final hex = normalizeHexColor(value);
          if (hex != null) out[key] = hex;
        case 'link':
          final url = safeUrl(value);
          if (url != null) out[key] = url;
        case 'script':
          if (value == 'sub' || value == 'super') out[key] = value as String;
        case 'header':
          if (value is int && value >= 1 && value <= 6) out[key] = value;
        case 'indent':
          if (value is int && value >= 1) out[key] = value > 8 ? 8 : value;
        case 'align':
          if (value == 'center' || value == 'right' || value == 'justify') {
            out[key] = value as String;
          }
        case 'list':
          if (value == 'bullet' ||
              value == 'ordered' ||
              value == 'checked' ||
              value == 'unchecked') {
            out[key] = value as String;
          }
      }
    }
    return out;
  }

  static final RegExp _hex = RegExp(
    r'^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
  );

  /// `#RGB`, `#RRGGBB` ve Flutter'ın `#AARRGGBB` biçimini büyük harfli
  /// `#RRGGBB`'ye çevirir; tanınmazsa `null`. CSS'te 8 haneli renk
  /// `#RRGGBBAA` demektir, bu yüzden alfa kanalı ASLA HTML'e taşınmaz.
  static String? normalizeHexColor(Object? value) {
    if (value is! String) return null;
    final match = _hex.firstMatch(value.trim());
    if (match == null) return null;
    var digits = match.group(1)!.toUpperCase();
    if (digits.length == 3) {
      digits = digits.split('').map((c) => '$c$c').join();
    } else if (digits.length == 8) {
      digits = digits.substring(2);
    }
    return '#$digits';
  }

  /// Yalnızca güvenli şemalar; şemasız `www.x.com` biçimi https'e tamamlanır.
  static String? safeUrl(Object? value) {
    if (value is! String) return null;
    var url = value.trim();
    if (url.isEmpty || url.contains(RegExp(r'[\s<>"]'))) return null;
    final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(url);
    if (scheme == null) {
      if (!url.contains('.') || url.startsWith('.')) return null;
      url = 'https://$url';
    } else {
      final name = scheme.group(1)!.toLowerCase();
      if (name != 'http' &&
          name != 'https' &&
          name != 'mailto' &&
          name != 'tel') {
        return null;
      }
    }
    return url;
  }
}

// ---------------------------------------------------------------- kodlayıcı

/// Editörün Quill satırında hangi anahtarlar SATIR (blok) özniteliğidir; geri
/// kalanlar metin parçası (inline) özniteliğidir.
const Set<String> _blockKeys = {
  'header',
  'list',
  'indent',
  'align',
  'blockquote',
  'code-block',
  'line-height',
  'direction',
};

/// Quill'in başlık boyutları (`DefaultStyles` ile aynı) — editörde görülen
/// başlık, giden HTML'de aynı boyutta çıkar.
const Map<int, int> _headerPx = {1: 34, 2: 30, 3: 24, 4: 20, 5: 18, 6: 16};

/// Bir liste/girinti kademesinin genişliği (px).
const int _indentPx = 32;

final class _Run {
  const _Run(this.text, this.attrs);

  final String text;
  final Map<String, Object?> attrs;
}

final class _Line {
  final List<_Run> runs = [];
  Map<String, Object?> block = const {};
}

final class _Encoder {
  _Encoder(this._delta);

  final Delta _delta;
  final StringBuffer _out = StringBuffer();

  static const String _baseStyle =
      'margin:0;font-family:${EmailHtmlCodec.fontFamily};';

  String build() {
    final lines = _toLines();
    // Belge sonundaki boş satırlar görsel bir anlam taşımaz.
    while (lines.isNotEmpty &&
        lines.last.runs.isEmpty &&
        lines.last.block.isEmpty) {
      lines.removeLast();
    }

    var i = 0;
    while (i < lines.length) {
      final block = lines[i].block;
      if (_listTag(block) != null) {
        i = _writeList(lines, i);
      } else if (block['blockquote'] == true) {
        i = _writeQuote(lines, i);
      } else {
        _writeLine(lines[i]);
        i++;
      }
    }
    return _out.toString();
  }

  /// Delta'yı satırlara böler. Satırı bitiren `\n`in öznitelikleri o satırın
  /// BLOK özniteliğidir; metnin öznitelikleri parçanın inline özniteliğidir.
  List<_Line> _toLines() {
    final lines = <_Line>[];
    var current = _Line();
    for (final op in _delta.toList()) {
      final data = op.data;
      if (data is! String) continue; // Gömülü nesne (görsel vb.) taşınamaz.
      final inline = <String, Object?>{};
      final block = <String, Object?>{};
      for (final entry
          in (op.attributes ?? const <String, dynamic>{}).entries) {
        (_blockKeys.contains(entry.key) ? block : inline)[entry.key] =
            entry.value;
      }
      final parts = data.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) current.runs.add(_Run(parts[i], inline));
        if (i < parts.length - 1) {
          current.block = block;
          lines.add(current);
          current = _Line();
        }
      }
    }
    if (current.runs.isNotEmpty) lines.add(current);
    return lines;
  }

  // -------------------------------------------------------------- satırlar

  static String? _listTag(Map<String, Object?> block) =>
      switch (block['list']) {
        'bullet' => 'ul',
        'ordered' => 'ol',
        _ => null,
      };

  static int _indentOf(Map<String, Object?> block) {
    final value = block['indent'];
    return value is int ? value.clamp(0, 8) : 0;
  }

  static String _num(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}' : '$value';

  /// Bir satırın taban stili: yazı tipi + boyut + satır aralığı (+ hizalama).
  static String _lineStyle(Map<String, Object?> block, {int? headerLevel}) {
    final spacing =
        ComposeLineSpacing.fromAttribute(block['line-height']) ??
        ComposeLineSpacing.normal;
    final size = headerLevel != null
        ? _headerPx[headerLevel]!
        : ComposeFontSize.normal.px;
    final buffer = StringBuffer(_baseStyle)
      ..write('font-size:${size}px;')
      ..write('line-height:${_num(spacing.height)};');
    if (headerLevel != null) buffer.write('font-weight:bold;');
    final align = block['align'];
    if (align == 'center' || align == 'right' || align == 'justify') {
      buffer.write('text-align:$align;');
    }
    return buffer.toString();
  }

  void _writeLine(_Line line) {
    final block = line.block;
    final header = block['header'];
    final level = header is int && header >= 1 && header <= 6 ? header : null;
    final tag = level == null ? 'div' : 'h$level';
    var style = _lineStyle(block, headerLevel: level);
    final indent = _indentOf(block);
    if (indent > 0) style += 'margin-left:${indent * _indentPx}px;';

    final runs = <_Run>[
      // Onay kutulu listeler HTML'de karşılıksız; işaret metne dökülür.
      if (block['list'] == 'checked') const _Run('☑ ', {}),
      if (block['list'] == 'unchecked') const _Run('☐ ', {}),
      ...line.runs,
    ];
    _out.write('<$tag style="$style">');
    if (runs.isEmpty) {
      _out.write('<br>');
    } else {
      _writeRuns(runs);
    }
    _out.write('</$tag>');
  }

  int _writeQuote(List<_Line> lines, int start) {
    _out.write(
      '<blockquote style="margin:0;padding-left:12px;'
      'border-left:3px solid #CCCCCC;">',
    );
    var i = start;
    while (i < lines.length && lines[i].block['blockquote'] == true) {
      _writeLine(lines[i]);
      i++;
    }
    _out.write('</blockquote>');
    return i;
  }

  int _writeList(List<_Line> lines, int start) {
    final stack = <String>[];
    var i = start;
    while (i < lines.length && _listTag(lines[i].block) != null) {
      final line = lines[i];
      final tag = _listTag(line.block)!;
      final level = _indentOf(line.block);

      // Daha derin kademeleri kapat; üst kademenin `<li>`si açık kalır.
      while (stack.length > level + 1) {
        _out.write('</li></${stack.removeLast()}>');
      }
      if (stack.length == level + 1) {
        _out.write('</li>');
        if (stack.last != tag) {
          _out.write('</${stack.removeLast()}>');
          stack.add(tag);
          _out.write('<$tag style="margin:0;padding-left:24px;">');
        }
      } else {
        while (stack.length < level + 1) {
          stack.add(tag);
          _out.write('<$tag style="margin:0;padding-left:24px;">');
        }
      }

      _out.write('<li style="${_lineStyle(line.block)}">');
      _writeRuns(line.runs);
      i++;
    }
    while (stack.isNotEmpty) {
      _out.write('</li></${stack.removeLast()}>');
    }
    return i;
  }

  // ------------------------------------------------------------ metin parçaları

  void _writeRuns(List<_Run> runs) {
    final full = runs.map((r) => r.text).join();
    final nbsp = _nbspFlags(full);
    var offset = 0;
    for (final run in runs) {
      _out.write(_wrap(run, _escape(run.text, nbsp, offset)));
      offset += run.text.length;
    }
  }

  /// HTML ardışık boşlukları tek boşluğa indirir ve satır başı/sonundaki
  /// boşluğu yutar. Hangi boşlukların `&nbsp;` olması gerektiğini bulur:
  /// satır başı/sonu ve başka bir boşluğun hemen ardından gelenler.
  static List<bool> _nbspFlags(String text) {
    final flags = List<bool>.filled(text.length, false);
    var previousCollapsible = true; // satır başı
    for (var i = 0; i < text.length; i++) {
      if (text[i] == ' ') {
        final needsNbsp = previousCollapsible || i == text.length - 1;
        flags[i] = needsNbsp;
        // `&nbsp;`den sonra gelen boşluk artık çökmez.
        previousCollapsible = !needsNbsp;
      } else {
        previousCollapsible = false;
      }
    }
    return flags;
  }

  static String _escape(String text, List<bool> nbsp, int offset) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      switch (ch) {
        case '&':
          buffer.write('&amp;');
        case '<':
          buffer.write('&lt;');
        case '>':
          buffer.write('&gt;');
        case ' ':
          buffer.write(nbsp[offset + i] ? '&nbsp;' : ' ');
        case '\t':
          buffer.write('&nbsp;&nbsp;&nbsp;&nbsp;');
        case ' ':
          buffer.write('&nbsp;');
        default:
          // Denetim karakterleri (NUL vb.) MIME/HTML'i bozar.
          if (ch.codeUnitAt(0) >= 0x20) buffer.write(ch);
      }
    }
    return buffer.toString();
  }

  static String _attr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Bir metin parçasını biçim etiketleriyle sarar. Dıştan içe: bağlantı,
  /// kalın, eğik, altı çizili, üstü çizili, `<span style>` (renk/vurgu/boyut).
  static String _wrap(_Run run, String content) {
    final attrs = run.attrs;
    var html = content;

    final styles = <String>[];
    final color = ComposeDeltaSanitizer.normalizeHexColor(attrs['color']);
    final background = ComposeDeltaSanitizer.normalizeHexColor(
      attrs['background'],
    );
    final size = ComposeFontSize.fromAttribute(attrs['size']);
    if (color != null) styles.add('color:$color');
    if (background != null) styles.add('background-color:$background');
    if (size != null && size != ComposeFontSize.normal) {
      styles.add('font-size:${size.px}px');
    }
    if (styles.isNotEmpty) {
      html = '<span style="${styles.join(';')};">$html</span>';
    }

    if (attrs['strike'] == true) html = '<s>$html</s>';
    if (attrs['underline'] == true) html = '<u>$html</u>';
    if (attrs['italic'] == true) html = '<i>$html</i>';
    if (attrs['bold'] == true) html = '<b>$html</b>';
    html = switch (attrs['script']) {
      'sub' => '<sub>$html</sub>',
      'super' => '<sup>$html</sup>',
      _ => html,
    };

    final url = ComposeDeltaSanitizer.safeUrl(attrs['link']);
    if (url != null) html = '<a href="${_attr(url)}">$html</a>';
    return html;
  }
}

// ---------------------------------------------------------------- çözücü

/// Ağaç gezerken aşağı taşınan biçim bağlamı.
final class _Ctx {
  const _Ctx({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.background,
    this.link,
    this.script,
    this.fontPx = 16,
    this.header,
    this.quote = false,
    this.list,
    this.listDepth = 0,
    this.align,
    this.lineHeight,
    this.indent = 0,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final String? color;
  final String? background;
  final String? link;
  final String? script;
  final double fontPx;
  final int? header;
  final bool quote;
  final String? list;
  final int listDepth;
  final String? align;
  final double? lineHeight;
  final int indent;

  /// [align] `copyWith` ile `null`a çekilemez; sola hizalama için ayrı yol.
  _Ctx withoutAlign() => _Ctx(
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
    background: background,
    link: link,
    script: script,
    fontPx: fontPx,
    header: header,
    quote: quote,
    list: list,
    listDepth: listDepth,
    lineHeight: lineHeight,
    indent: indent,
  );

  _Ctx copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    String? color,
    String? background,
    String? link,
    String? script,
    double? fontPx,
    int? header,
    bool? quote,
    String? list,
    int? listDepth,
    String? align,
    double? lineHeight,
    int? indent,
  }) => _Ctx(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    color: color ?? this.color,
    background: background ?? this.background,
    link: link ?? this.link,
    script: script ?? this.script,
    fontPx: fontPx ?? this.fontPx,
    header: header ?? this.header,
    quote: quote ?? this.quote,
    list: list ?? this.list,
    listDepth: listDepth ?? this.listDepth,
    align: align ?? this.align,
    lineHeight: lineHeight ?? this.lineHeight,
    indent: indent ?? this.indent,
  );
}

final class _DecodedRun {
  _DecodedRun(this.text, this.attrs);

  String text;
  final Map<String, Object> attrs;
}

final class _DecodedLine {
  _DecodedLine(this.block);

  final Map<String, Object> block;
  final List<_DecodedRun> runs = [];
}

final class _Decoder {
  final List<_DecodedLine> _lines = [];
  _DecodedLine? _current;

  static const Set<String> _skipTags = {
    'script',
    'style',
    'head',
    'title',
    'meta',
    'link',
    'template',
    'noscript',
    'img',
    'hr',
  };

  static const Set<String> _blockTags = {
    'div', 'p', 'li', 'ul', 'ol', 'blockquote', 'pre', 'h1', 'h2', 'h3', //
    'h4', 'h5', 'h6', 'section', 'article', 'header', 'footer', 'main',
    'nav', 'aside', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th',
    'center', 'figure', 'address', 'form', 'dl', 'dt', 'dd',
  };

  /// `<font size=N>` (eski biçim, Gmail'in eski gönderimleri) → px.
  static const Map<String, double> _legacyFontSize = {
    '1': 10, '2': 13, '3': 16, '4': 18, '5': 24, '6': 32, '7': 48, //
  };

  Delta run(String source) {
    final body = html_parser.parse(source).body;
    if (body != null) _walk(body, const _Ctx());
    _flush();

    final delta = Delta();
    for (final line in _lines) {
      for (final run in line.runs) {
        // Kodlayıcı, korunması gereken boşlukları `&nbsp;` ile yazar.
        delta.insert(
          run.text.replaceAll(' ', ' '),
          run.attrs.isEmpty ? null : run.attrs,
        );
      }
      delta.insert('\n', line.block.isEmpty ? null : line.block);
    }
    if (delta.isEmpty) delta.insert('\n');
    return delta;
  }

  // ------------------------------------------------------------- gezinme

  void _walk(dom.Node node, _Ctx ctx) {
    if (node is dom.Text) {
      _text(node.data, ctx);
      return;
    }
    if (node is! dom.Element) return;

    final tag = node.localName ?? '';
    if (_skipTags.contains(tag)) return;
    if (tag == 'br') {
      _lineBreak(ctx);
      return;
    }

    final isBlock = _blockTags.contains(tag);
    final next = _applyElement(node, tag, ctx);
    if (isBlock) _flush();
    for (final child in node.nodes) {
      _walk(child, next);
    }
    if (isBlock) _flush();
  }

  /// Etiketin ve `style` özniteliğinin bağlama katkısı.
  _Ctx _applyElement(dom.Element element, String tag, _Ctx ctx) {
    var c = ctx;
    var isHeader = false;

    switch (tag) {
      case 'b' || 'strong':
        c = c.copyWith(bold: true);
      case 'i' || 'em' || 'cite' || 'dfn':
        c = c.copyWith(italic: true);
      case 'u' || 'ins':
        c = c.copyWith(underline: true);
      case 's' || 'strike' || 'del':
        c = c.copyWith(strike: true);
      case 'sub':
        c = c.copyWith(script: 'sub');
      case 'sup':
        c = c.copyWith(script: 'super');
      case 'a':
        final url = ComposeDeltaSanitizer.safeUrl(element.attributes['href']);
        if (url != null) c = c.copyWith(link: url);
      case 'font':
        final color = _cssColor(element.attributes['color']);
        if (color != null) c = c.copyWith(color: color);
        final legacy = _legacyFontSize[element.attributes['size']?.trim()];
        if (legacy != null) {
          c = c.copyWith(fontPx: ComposeFontSize.fromPx(legacy).px.toDouble());
        }
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        isHeader = true;
        c = c.copyWith(header: int.parse(tag.substring(1)));
      case 'blockquote':
        c = c.copyWith(quote: true);
      case 'ul':
        c = c.copyWith(list: 'bullet', listDepth: c.listDepth + 1);
      case 'ol':
        c = c.copyWith(list: 'ordered', listDepth: c.listDepth + 1);
      case 'li':
        if (c.list == null) c = c.copyWith(list: 'bullet', listDepth: 1);
      case 'center':
        c = c.copyWith(align: 'center');
    }

    final align = element.attributes['align']?.trim().toLowerCase();
    if (align == 'center' || align == 'right' || align == 'justify') {
      c = c.copyWith(align: align);
    }

    final style = element.attributes['style'];
    if (style != null && style.trim().isNotEmpty) {
      c = _applyStyle(
        style,
        c,
        isBlock: _blockTags.contains(tag),
        isHeader: isHeader,
      );
    }
    return c;
  }

  _Ctx _applyStyle(
    String style,
    _Ctx ctx, {
    required bool isBlock,
    required bool isHeader,
  }) {
    var c = ctx;
    for (final declaration in style.split(';')) {
      final colon = declaration.indexOf(':');
      if (colon < 0) continue;
      final key = declaration.substring(0, colon).trim().toLowerCase();
      final value = declaration
          .substring(colon + 1)
          .replaceAll(RegExp(r'!important', caseSensitive: false), '')
          .trim();
      if (value.isEmpty) continue;

      switch (key) {
        case 'color':
          final color = _cssColor(value);
          if (color != null) c = c.copyWith(color: color);
        case 'background-color' || 'background':
          final color = _cssColor(value);
          if (color != null) c = c.copyWith(background: color);
        case 'font-size' when !isHeader:
          final level = ComposeFontSize.fromAttribute(
            value,
            parentPx: c.fontPx,
          );
          if (level != null) c = c.copyWith(fontPx: level.px.toDouble());
        case 'font-weight' when !isHeader:
          final weight = int.tryParse(value);
          final lower = value.toLowerCase();
          if (lower == 'bold' ||
              lower == 'bolder' ||
              (weight != null && weight >= 600)) {
            c = c.copyWith(bold: true);
          }
        case 'font-style':
          if (value.toLowerCase().contains('italic')) {
            c = c.copyWith(italic: true);
          }
        case 'text-decoration' || 'text-decoration-line':
          final lower = value.toLowerCase();
          if (lower.contains('underline')) c = c.copyWith(underline: true);
          if (lower.contains('line-through')) c = c.copyWith(strike: true);
        case 'line-height':
          final height = _lineHeight(value, c.fontPx);
          if (height != null) c = c.copyWith(lineHeight: height);
        case 'text-align':
          final lower = value.toLowerCase();
          if (lower == 'center' || lower == 'right' || lower == 'justify') {
            c = c.copyWith(align: lower);
          } else if (lower == 'left') {
            // Soldan hizalı bir öznitelik taşımaz; üst bloktan gelen hizayı
            // sıfırlar.
            c = c.withoutAlign();
          }
        case 'margin-left' || 'padding-left' when isBlock && c.list == null:
          final px = ComposeFontSize.cssLengthToPx(value, parentPx: c.fontPx);
          if (px != null && px > 0) {
            c = c.copyWith(indent: (px / _indentPx).round().clamp(0, 8));
          }
      }
    }
    return c;
  }

  /// Birimsiz çarpan, `%`, `em` ve `px` biçimlerini çarpana çevirir.
  static double? _lineHeight(String value, double fontPx) {
    final lower = value.trim().toLowerCase();
    if (lower == 'normal') return ComposeLineSpacing.baseHeight;
    final unitless = double.tryParse(lower);
    if (unitless != null) return unitless.isFinite ? unitless : null;
    final px = ComposeFontSize.cssLengthToPx(lower, parentPx: fontPx);
    if (px == null) return null;
    // `em`/`%` zaten fontPx ile çarpılmış piksele döndü; çarpana geri çevir.
    return px / fontPx;
  }

  // --------------------------------------------------------------- renkler

  static const Map<String, String> _namedColors = {
    'black': '#000000',
    'white': '#FFFFFF',
    'red': '#FF0000',
    'green': '#008000',
    'blue': '#0000FF',
    'yellow': '#FFFF00',
    'orange': '#FFA500',
    'purple': '#800080',
    'gray': '#808080',
    'grey': '#808080',
    'pink': '#FFC0CB',
  };

  static final RegExp _rgb = RegExp(
    r'^rgba?\(\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*[, ]\s*(\d{1,3})\s*(?:[,/]\s*([0-9.]+%?)\s*)?\)$',
    caseSensitive: false,
  );

  static String? _cssColor(String? value) {
    if (value == null) return null;
    final text = value.trim().toLowerCase();
    if (text.isEmpty) return null;
    final named = _namedColors[text];
    if (named != null) return named;

    final match = _rgb.firstMatch(text);
    if (match != null) {
      final alpha = match.group(4);
      if (alpha != null &&
          (double.tryParse(alpha.replaceAll('%', '')) ?? 1) == 0) {
        return null; // Tamamen saydam renk.
      }
      final channels = [1, 2, 3].map((i) => int.parse(match.group(i)!));
      if (channels.any((c) => c > 255)) return null;
      return '#${channels.map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
    }
    // Kodlayıcının kendi çıktısı `#RRGGBB`dir; yabancı HTML'de `#RGB` gelir.
    // 8 haneli CSS rengi `#RRGGBBAA`dır (Flutter'ın `#AARRGGBB`si DEĞİL).
    final hex = RegExp(r'^#([0-9a-f]{8})$').firstMatch(text);
    if (hex != null) return '#${hex.group(1)!.substring(0, 6).toUpperCase()}';
    return ComposeDeltaSanitizer.normalizeHexColor(text);
  }

  // ---------------------------------------------------------- satır kurma

  Map<String, Object> _blockAttrs(_Ctx ctx) {
    final block = <String, Object>{};
    if (ctx.header != null) {
      block['header'] = ctx.header!;
    } else if (ctx.list != null) {
      block['list'] = ctx.list!;
      if (ctx.listDepth > 1) block['indent'] = (ctx.listDepth - 1).clamp(1, 8);
    } else if (ctx.quote) {
      block['blockquote'] = true;
    } else if (ctx.indent > 0) {
      block['indent'] = ctx.indent;
    }
    if (ctx.align != null) block['align'] = ctx.align!;
    final height = ComposeLineSpacing.fromAttribute(
      ctx.lineHeight,
    )?.attributeValue;
    if (height != null) block['line-height'] = height;
    return block;
  }

  Map<String, Object> _inlineAttrs(_Ctx ctx) {
    final attrs = <String, Object>{};
    if (ctx.bold) attrs['bold'] = true;
    if (ctx.italic) attrs['italic'] = true;
    if (ctx.underline) attrs['underline'] = true;
    if (ctx.strike) attrs['strike'] = true;
    if (ctx.color != null) attrs['color'] = ctx.color!;
    if (ctx.background != null) attrs['background'] = ctx.background!;
    final size = ComposeFontSize.fromPx(ctx.fontPx).attributeValue;
    if (size != null) attrs['size'] = size;
    if (ctx.link != null) attrs['link'] = ctx.link!;
    if (ctx.script != null) attrs['script'] = ctx.script!;
    return attrs;
  }

  static bool _sameAttrs(Map<String, Object> a, Map<String, Object> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _text(String raw, _Ctx ctx) {
    var text = raw.replaceAll(RegExp(r'[ \t\r\n\f]+'), ' ');
    if (text.isEmpty) return;

    final current = _current;
    final atLineStart =
        current == null ||
        current.runs.isEmpty ||
        current.runs.last.text.endsWith(' ');
    if (atLineStart && text.startsWith(' ')) text = text.substring(1);
    if (text.isEmpty) return;

    final line = _current ??= _DecodedLine(_blockAttrs(ctx));
    final attrs = _inlineAttrs(ctx);
    if (line.runs.isNotEmpty && _sameAttrs(line.runs.last.attrs, attrs)) {
      line.runs.last.text += text;
    } else {
      line.runs.add(_DecodedRun(text, attrs));
    }
  }

  /// `<br>`: metin varsa satırı bitirir (sonda tek başına olan `<br>` fazladan
  /// satır üretmez — tarayıcılardaki gibi); satır boşsa boş bir satır üretir.
  void _lineBreak(_Ctx ctx) {
    final current = _current;
    if (current != null && current.runs.isNotEmpty) {
      _flush();
    } else {
      _current = null;
      _lines.add(_DecodedLine(_blockAttrs(ctx)));
    }
  }

  void _flush() {
    final line = _current;
    _current = null;
    if (line == null) return;
    // Satır sonundaki (çöken) boşluk görünmez; kırp.
    while (line.runs.isNotEmpty) {
      final last = line.runs.last;
      last.text = last.text.replaceFirst(RegExp(r' +$'), '');
      if (last.text.isNotEmpty) break;
      line.runs.removeLast();
    }
    if (line.runs.isEmpty) return;
    _lines.add(line);
  }
}

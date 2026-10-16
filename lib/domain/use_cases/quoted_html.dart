/// Yanıtla / İlet sırasında orijinal iletinin HTML'ini (gömülü görselleriyle)
/// yazma editörünün belgesine (Delta) çevirir.
///
/// Veritabanındaki gövdede gömülü (`cid:`) görseller indirme sırasında zaten
/// `data:` adresine çözülmüştür (bkz. `CidResolver`). Görselin KENDİSİ bu
/// adreste durur; böylece yeni iletiye taşınan görsel geçici dosya yoluna
/// bağlı kalmaz: taslak yeniden açılsa, uygulama yeniden başlasa, cihaz
/// değişse bile baytlar belgenin içindedir. Gönderimde `data:` adresleri
/// `HtmlInlineProcessor` tarafından Content-ID'li MIME parçalarına çevrilir.
///
/// Kullanıcıya ASLA `cid:`, `file:`, cihaz yolu ya da göreli yol gösterilmez:
/// çözülemeyen görsel belgeye hiç girmez.
library;

import 'package:flutter_quill/quill_delta.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'email_html_codec.dart';

abstract final class QuotedHtml {
  /// Editörde ve giden iletide güvenle taşınabilen görsel türleri. SVG
  /// bilerek yok: betik taşıyabilir ve Outlook/Gmail çizmez.
  static const Set<String> dataImageMimes = {
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/pjpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  };

  static final RegExp dataImagePrefix = RegExp(
    r'^data:(image/[a-z0-9.+-]+)[^,]*;base64,',
    caseSensitive: false,
  );

  /// [html]'i editör belgesine çevirir. [asQuote] `true` ise (Yanıtla) her
  /// düz satır alıntı bloğuna alınır; İlet'te gövde olduğu gibi gelir.
  ///
  /// Görünür hiçbir içerik (metin ya da görsel) yoksa `null` döner; çağıran
  /// düz metne düşer.
  static Delta? toDelta(String html, {required bool asQuote}) {
    final body = html_parser.parse(html).body;
    if (body == null) return null;
    sanitizeImages(body);
    var delta = EmailHtmlCodec.decodeBody(body);
    if (!_hasVisibleContent(delta)) return null;
    if (asQuote) delta = _asBlockquote(delta);
    return delta;
  }

  /// Yanıtla / İlet için orijinal HTML'i BOZMADAN taşınacak parçaya çevirir:
  /// tablolar, satır içi stiller, `<style>` blokları, düğmeler ve görseller
  /// olduğu gibi kalır (Gmail/Outlook/Yandex'in alıntılaması gibi). Yalnızca
  /// çalıştırılabilir/aktif içerik (betik, iframe, form, `on*` öznitelikleri,
  /// `javascript:` bağlantıları) ve taşınamayan görseller ayıklanır.
  ///
  /// Görünür içerik yoksa `null` döner.
  static String? faithfulHtml(String html) {
    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return null;
    sanitizeImages(body);

    for (final el in body.querySelectorAll(
      'script, iframe, object, embed, form, meta, link, base, noscript',
    ).toList()) {
      el.remove();
    }
    for (final el in body.querySelectorAll('*')) {
      for (final name in el.attributes.keys.toList()) {
        final key = name.toString().toLowerCase();
        final value = el.attributes[name]?.trim().toLowerCase() ?? '';
        if (key.startsWith('on') ||
            ((key == 'href' || key == 'src' || key == 'action') &&
                value.startsWith('javascript:'))) {
          el.attributes.remove(name);
        }
      }
    }

    final hasText = body.text.trim().isNotEmpty;
    if (!hasText && body.querySelector('img') == null) return null;

    final styles = StringBuffer();
    for (final s in doc.querySelectorAll('style')) {
      styles.write(s.outerHtml);
    }
    return '$styles${body.innerHtml}';
  }

  /// Ağaçtaki `<img>`leri belge için güvenli hâle getirir: yalnızca `http(s)`
  /// ve geçerli `data:image/*;base64` kaynakları kalır; `cid:`, `file:`,
  /// `blob:`, göreli yol vb. ile izleme pikselleri (≤2 px) kaldırılır.
  static void sanitizeImages(dom.Element root) {
    for (final img in root.querySelectorAll('img').toList()) {
      final src = img.attributes['src']?.trim() ?? '';
      if (!isDisplayableSource(src) || _isTiny(img)) {
        img.remove();
        continue;
      }
      img.attributes['src'] = src;
      if (_px(img.attributes['width']) == null) {
        final styled = _styleLength(img.attributes['style'], 'width');
        if (styled != null) img.attributes['width'] = '${styled.round()}';
      }
    }
  }

  static bool isDisplayableSource(String src) {
    final lower = src.toLowerCase();
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      return true;
    }
    final match = dataImagePrefix.firstMatch(src);
    if (match == null) return false;
    return dataImageMimes.contains(match.group(1)!.toLowerCase());
  }

  static bool _isTiny(dom.Element img) {
    final style = img.attributes['style']?.toLowerCase() ?? '';
    if (RegExp(r'display\s*:\s*none').hasMatch(style)) return true;
    for (final name in const ['width', 'height']) {
      final value = _px(img.attributes[name]) ?? _styleLength(style, name);
      if (value != null && value <= 2) return true;
    }
    return false;
  }

  static double? _px(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(?:px)?\s*$').firstMatch(raw);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  static double? _styleLength(String? style, String property) {
    if (style == null) return null;
    final match = RegExp(
      '(?:^|;)\\s*$property\\s*:\\s*(\\d+(?:\\.\\d+)?)px',
      caseSensitive: false,
    ).firstMatch(style);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  static bool _hasVisibleContent(Delta delta) {
    for (final op in delta.toList()) {
      final data = op.data;
      if (data is Map) return true;
      if (data is String && data.trim().isNotEmpty) return true;
    }
    return false;
  }

  /// Başlık/liste/kod bloğu olmayan her satıra `blockquote` ekler.
  /// Satırı bitiren `\n`in öznitelikleri o satırın blok özniteliğidir.
  static Delta _asBlockquote(Delta source) {
    const exclusive = {'header', 'list', 'code-block', 'blockquote'};
    final result = Delta();
    for (final op in source.toList()) {
      final data = op.data;
      if (data is! String || !data.contains('\n')) {
        result.push(op);
        continue;
      }
      final parts = data.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) result.insert(parts[i], op.attributes);
        if (i == parts.length - 1) continue;
        final attrs = <String, dynamic>{...?op.attributes};
        if (!exclusive.any(attrs.containsKey)) attrs['blockquote'] = true;
        result.insert('\n', attrs.isEmpty ? null : attrs);
      }
    }
    return result;
  }
}

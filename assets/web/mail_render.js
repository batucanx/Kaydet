/*
 * Kaydet — e-posta gövdesi render betiği.
 *
 * `MailHtmlDocument` (lib/ui/features/mail_detail/mail_html_document.dart) bu
 * dosyayı, e-postanın HTML'iyle birlikte WebView'a verdiği belgenin <head>
 * bölümüne nonce'lu bir <script> olarak gömer. Belgedeki CSP yalnızca bu
 * nonce'a izin verdiği için e-postanın kendi betikleri çalışmaz.
 *
 * Yapılandırma `window.__kaydet` üzerinden gelir:
 *   transform : renkler koyu temaya çevrilsin mi (uygulama koyu VE e-posta
 *               kendi koyu temasını getirmiyor)
 *   bg, text  : uygulamanın zemin / metin rengi ([r, g, b])
 *   minFont   : metnin inebileceği en küçük yazı boyutu (px)
 *   channel   : içerik yüksekliğinin bildirildiği JavaScript kanalının adı
 *   doc       : bu belgenin kimliği (bildirimlerde geri gönderilir)
 *
 * Dört iş yapar:
 *
 *  1. Akışkanlaştırma — telefon genişliğine sığmayan sabit genişlikli düzenleri
 *     (600px'lik bülten tabloları gibi) yüzde genişliğe çevirir. Yalnızca
 *     gerçekten taşma varsa çalışır; responsive e-postaların kendi mobil
 *     CSS'ine dokunmaz. Sonuç kötüyse (hücreler ezilirse) geri alır.
 *
 *  2. Yazı boyutu tabanı — 6..minFont px arası metni minFont'a çıkarır
 *     (footer/dipnot yazıları). 6px altı (boşluk hileleri: font-size:1px)
 *     ve display:none öğeler dokunulmaz.
 *
 *  3. Renk dönüşümü — Outlook mobilin "kısmi renk çevirme" mantığı: açık
 *     zeminleri koyulaştırır, koyu metni/kenarlığı açar, zaten koyu zemine ve
 *     açık metne dokunmaz. Görsel/gradyan arka planlı alt ağaçlar (ve
 *     içindeki metin) tasarlandığı gibi bırakılır. Her metin, çevrildikten
 *     sonraki gerçek zeminine göre okunabilir kontrasta zorlanır.
 *
 *  4. Yükseklik bildirimi — okuma ekranında WebView kendi içinde kaydırmaz:
 *     boyu içeriğin boyuna eşitlenir ve e-posta başlığıyla birlikte ekranın
 *     TEK kaydırma alanında kayar. İçerik boyu her değiştiğinde uygulamaya
 *     bildirilir. Bunun ön koşulu olarak vh/vmin/vmax birimleri ekran boyuna
 *     göre piksele sabitlenir (aksi hâlde boy uzadıkça içerik de uzar).
 *
 * Tüm hesap `getComputedStyle` üzerinden yapılır: satır içi stil, <style>
 * sınıfları, bgcolor/color/text nitelikleri ve kalıtım hazır çözülmüş gelir.
 * Önce tüm okumalar, sonra tüm yazmalar yapılır (yerleşim titremesi yok).
 *
 * Hata ne olursa olsun e-posta olduğu gibi görünür kalır; betik asla render'ı
 * bozmaz. <html data-kd-*> nitelikleri hata ayıklama içindir.
 */
(function () {
  'use strict';

  var cfg = window.__kaydet || {};
  var MIN_FONT = cfg.minFont || 12;
  var doc = document;
  var root = doc.documentElement;
  var startedAt = performance.now();

  // ── Renk yardımcıları ─────────────────────────────────────────────────

  var RGB = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:[\s,\/]+([\d.]+)(%?))?\s*\)$/;

  /** "rgb(1, 2, 3)" / "rgba(1, 2, 3, .5)" → {r, g, b, a}; tanınmazsa null. */
  function parse(text) {
    var m = RGB.exec(text);
    if (!m) return null;
    var a = m[4] === undefined ? 1 : parseFloat(m[4]) / (m[5] ? 100 : 1);
    return { r: +m[1], g: +m[2], b: +m[3], a: a };
  }

  function css(c) {
    var rgb = Math.round(c.r) + ',' + Math.round(c.g) + ',' + Math.round(c.b);
    return c.a >= 1 ? 'rgb(' + rgb + ')' : 'rgba(' + rgb + ',' + c.a + ')';
  }

  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

  function linear(v) {
    v /= 255;
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }

  /** WCAG göreli parlaklığı (0..1). Açık/koyu kararı HSL'den değil bundan verilir:
   *  saf sarı HSL'de "orta", gerçekte çok parlaktır. */
  function lum(c) {
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
  }

  function contrast(a, b) {
    var l1 = lum(a), l2 = lum(b);
    if (l1 < l2) { var t = l1; l1 = l2; l2 = t; }
    return (l1 + 0.05) / (l2 + 0.05);
  }

  function toHsl(c) {
    var r = c.r / 255, g = c.g / 255, b = c.b / 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    var l = (max + min) / 2, h = 0, s = 0;
    if (max !== min) {
      var d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
    }
    return { h: h, s: s, l: l };
  }

  function hue(p, q, t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }

  function fromHsl(h, s, l, a) {
    var r = l, g = l, b = l;
    if (s !== 0) {
      var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
      r = hue(p, q, h + 1 / 3);
      g = hue(p, q, h);
      b = hue(p, q, h - 1 / 3);
    }
    return { r: r * 255, g: g * 255, b: b * 255, a: a };
  }

  // ── Koyu tema dönüşümü ────────────────────────────────────────────────

  var PAGE_BG = cfg.bg ? { r: cfg.bg[0], g: cfg.bg[1], b: cfg.bg[2], a: 1 } : { r: 0, g: 0, b: 0, a: 1 };
  var PAGE_TEXT = cfg.text ? { r: cfg.text[0], g: cfg.text[1], b: cfg.text[2], a: 1 } : { r: 255, g: 255, b: 255, a: 1 };
  var BG_HSL = toHsl(PAGE_BG);
  var BG_L = BG_HSL.l;             // beyaz zeminlerin ineceği parlaklık
  var TEXT_L = toHsl(PAGE_TEXT).l; // siyah metnin çıkacağı parlaklık

  var LIGHT_SURFACE = 0.5;  // göreli parlaklığı bunun üstündeki zemin "açık"
  var DARK_INK = 0.4;       // göreli parlaklığı bunun altındaki metin "koyu"
  var TEXT_CONTRAST = 4.5;
  var BORDER_CONTRAST = 1.8;

  /** Açık zemini koyulaştırır; renk tonu korunur. Zaten koyuysa aynı nesne döner.
   *  Nötr (beyaz/gri) zeminler uygulamanın zemin tonunu alır: beyaz zemin tam
   *  olarak `bg` olur, mail gövdesi üstteki başlıkla dikişsiz birleşir. */
  function darkSurface(c) {
    if (lum(c) < LIGHT_SURFACE) return c;
    var h = toHsl(c);
    var l = Math.min(0.42, BG_L + (1 - h.l) * 0.55);
    return h.s < 0.08 ? fromHsl(BG_HSL.h, BG_HSL.s, l, c.a) : fromHsl(h.h, h.s * 0.85, l, c.a);
  }

  /** Koyu metni açar; renk tonu korunur. Zaten açıksa aynı nesne döner. */
  function lightInk(c) {
    if (lum(c) >= DARK_INK) return c;
    var h = toHsl(c);
    return fromHsl(h.h, h.s, clamp(1 - h.l, 0.6, TEXT_L), c.a);
  }

  /** `bg` zemininde en az `min` kontrast verene kadar `fg`nin parlaklığını kaydırır. */
  function withContrast(fg, bg, min) {
    if (contrast(fg, bg) >= min) return fg;
    var h = toHsl(fg);
    var step = lum(bg) < 0.18 ? 0.04 : -0.04; // koyu zeminde aç, açık/orta zeminde koyulaştır
    var l = h.l, out = fg;
    for (var i = 0; i < 25; i++) {
      l = clamp(l + step, 0, 1);
      out = fromHsl(h.h, h.s, l, fg.a);
      if (contrast(out, bg) >= min || l === 0 || l === 1) break;
    }
    return out;
  }

  /** Kenarlık: açıksa koyulaşır, koyuysa (ör. siyah ızgara çizgisi) orta-açık olur. */
  function border(c, bg) {
    var n = c, h;
    if (lum(c) >= LIGHT_SURFACE) {
      h = toHsl(c);
      n = fromHsl(h.h, h.s * 0.85, Math.min(0.4, 0.16 + (1 - h.l) * 0.6), c.a);
    } else if (lum(c) < DARK_INK) {
      h = toHsl(c);
      n = fromHsl(h.h, h.s, clamp(1 - h.l, 0.45, 0.6), c.a);
    }
    return withContrast(n, bg, BORDER_CONTRAST);
  }

  var SIDES = ['top', 'right', 'bottom', 'left'];
  var ISLAND = { c: PAGE_BG, island: true };
  var PAGE = { c: PAGE_BG, island: false };

  function hasOwnText(el) {
    for (var n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3 && /\S/.test(n.nodeValue)) return true;
    }
    return false;
  }

  /** Bir öğenin işlenmesi için gereken tüm computed-style okumaları. */
  function read(el) {
    var info = { el: el, skip: true };
    if (!(el instanceof HTMLElement)) return info;
    var cs = getComputedStyle(el);
    if (cs.display === 'none') return info;
    info.skip = false;
    info.text = hasOwnText(el);
    var fs = parseFloat(cs.fontSize);
    info.raise = info.text && fs >= 6 && fs < MIN_FONT;
    if (info.raise) info.lineHeight = parseFloat(cs.lineHeight); // 'normal' → NaN
    if (cfg.transform) {
      info.bg = cs.backgroundColor;
      info.bgImage = cs.backgroundImage;
      if (info.text) info.fg = cs.color;
      for (var k = 0; k < 4; k++) {
        var s = SIDES[k], style = cs['border-' + s + '-style'];
        if (style !== 'none' && style !== 'hidden' && parseFloat(cs['border-' + s + '-width']) > 0) {
          (info.borders || (info.borders = [])).push([s, cs['border-' + s + '-color']]);
        }
      }
    }
    return info;
  }

  function put(el, prop, value) { el.style.setProperty(prop, value, 'important'); }

  /** Okunan bilgilere göre yazma; `eff` öğenin çevrilmiş etkin zeminidir. */
  function write(info, eff) {
    var el = info.el;

    if (cfg.transform && !eff.island) {
      if (info.bgImage && info.bgImage !== 'none') {
        eff = ISLAND; // görsel/gradyan: bu alt ağaç tasarlandığı gibi kalır
      } else {
        var bg = parse(info.bg);
        if (bg && bg.a > 0) {
          var nb = darkSurface(bg);
          if (nb !== bg) put(el, 'background-color', css(nb));
          if (bg.a >= 0.5) eff = { c: nb, island: false };
        }
        if (info.borders) {
          for (var i = 0; i < info.borders.length; i++) {
            var bc = parse(info.borders[i][1]);
            if (!bc || bc.a === 0) continue;
            var nbc = border(bc, eff.c);
            if (nbc !== bc) put(el, 'border-' + info.borders[i][0] + '-color', css(nbc));
          }
        }
        if (info.fg) {
          var fg = parse(info.fg);
          if (fg) {
            var nf = withContrast(lightInk(fg), eff.c, TEXT_CONTRAST);
            if (nf !== fg) put(el, 'color', css(nf));
          }
        }
      }
    }

    if (info.raise && el.tagName !== 'SUP' && el.tagName !== 'SUB') {
      put(el, 'font-size', MIN_FONT + 'px');
      // Sabit px satır yüksekliği yeni boyuta dar kalırsa satırlar birbirine biner.
      if (info.lineHeight < MIN_FONT * 1.25) put(el, 'line-height', '1.35');
    }
    return eff;
  }

  function enhance() {
    var body = doc.body;
    var list = [root, body].concat(Array.prototype.slice.call(body.getElementsByTagName('*')));
    var infos = new Array(list.length), i;
    for (i = 0; i < list.length; i++) infos[i] = read(list[i]);

    var effective = new Map();
    for (i = 0; i < infos.length; i++) {
      var info = infos[i];
      if (info.skip) continue;
      var parent = info.el.parentElement;
      effective.set(info.el, write(info, (parent && effective.get(parent)) || PAGE));
    }
  }

  // ── Akışkanlaştırma ───────────────────────────────────────────────────

  var FLUID_PROPS = ['width', 'max-width', 'min-width', 'box-sizing'];
  var BLOCKY = /^(block|table|flex|grid|list-item|inline-block|inline-table|flow-root)$/;
  var patched = [];
  var fluidWidth = -1;

  function revertFluid() {
    for (var i = 0; i < patched.length; i++) {
      var style = patched[i].el.style, prev = patched[i].prev;
      for (var j = 0; j < FLUID_PROPS.length; j++) {
        if (prev[j][0]) style.setProperty(FLUID_PROPS[j], prev[j][0], prev[j][1]);
        else style.removeProperty(FLUID_PROPS[j]);
      }
    }
    patched = [];
    root.removeAttribute('data-kd-fluid');
  }

  /** Metin taşıyan hücrelerin (önce, sonra) genişliklerini karşılaştırır: ezildiyse true. */
  function squeezed(before) {
    for (var i = 0; i < before.length; i++) {
      var w = before[i][0].getBoundingClientRect().width;
      if (before[i][1] >= 60 && w < 36) return true;
    }
    return false;
  }

  function applyFluid() {
    var body = doc.body;
    var vw = root.clientWidth;
    if (!body || !vw || vw === fluidWidth) return;
    fluidWidth = vw;
    revertFluid();
    if (root.scrollWidth <= vw + 1) return; // taşma yok: e-postanın kendi düzeni çalışıyor

    var bs = getComputedStyle(body);
    var avail = body.clientWidth - (parseFloat(bs.paddingLeft) || 0) - (parseFloat(bs.paddingRight) || 0);

    var all = body.getElementsByTagName('*'), plans = [], cells = [], i, w, cs;
    for (i = 0; i < all.length; i++) {
      var el = all[i], tag = el.tagName;
      w = el.getBoundingClientRect().width;
      if (tag === 'TD' || tag === 'TH') {
        if (w >= 60 && /\S{4}/.test(el.textContent || '')) cells.push([el, w]);
        // Mobil CSS'te `display:block; width:100%` yapılan hücre, padding yüzünden
        // (content-box) kutusundan taşar; genişliği değil ölçü modelini düzeltiriz.
        if (w > avail + 1 && getComputedStyle(el).display === 'block') {
          plans.push([el, [['box-sizing', 'border-box'], ['max-width', '100%']]]);
        }
      } else if (w > avail + 1 && tag !== 'IMG' && el instanceof HTMLElement) {
        cs = getComputedStyle(el);
        if (BLOCKY.test(cs.display) && cs.position !== 'absolute' && cs.position !== 'fixed') {
          var isTable = cs.display === 'table' || cs.display === 'inline-table';
          var decls = [['width', '100%'], ['max-width', Math.round(w) + 'px'], ['min-width', '0']];
          if (!isTable) decls.push(['box-sizing', 'border-box']);
          plans.push([el, decls]);
        }
      }
    }
    if (!plans.length) return;

    for (i = 0; i < plans.length; i++) patch(plans[i][0], plans[i][1]);

    if (squeezed(cells)) revertFluid();
    else root.setAttribute('data-kd-fluid', String(patched.length));
  }

  /** Öğenin önceki satır içi değerlerini saklayıp yeni bildirimleri yazar (geri alınabilir). */
  function patch(el, decls) {
    var style = el.style, prev = [], j;
    for (j = 0; j < FLUID_PROPS.length; j++) {
      prev.push([style.getPropertyValue(FLUID_PROPS[j]), style.getPropertyPriority(FLUID_PROPS[j])]);
    }
    patched.push({ el: el, prev: prev });
    for (j = 0; j < decls.length; j++) put(el, decls[j][0], decls[j][1]);
  }

  // ── Görünüm birimleri ─────────────────────────────────────────────────

  // WebView içerik boyuna uzatıldığı için "100vh" ekranı değil tüm içeriği
  // ifade eder: vh'ye bağlı bir blok her uzamada yeniden uzar ve boy sonsuza
  // dek büyür. vh/vb/vmin/vmax (s/l/d önekleriyle) e-postanın tasarlandığı
  // gibi ekran boyuna göre piksele sabitlenir; vw'ye dokunulmaz (genişlik
  // zaten ekran genişliğidir). `url(...)` içindeki dosya adları eşleşmez:
  // sayıdan önce boşluk/`(`/`,`, birimden sonra da `.`/harf olmaması aranır.
  var VIEWPORT_UNIT = /(^|[\s(,])(-?(?:\d+\.?\d*|\.\d+))[sld]?(vh|vb|vmin|vmax)(?![\w.%-])/gi;
  var HAS_VIEWPORT_UNIT = /\d[sld]?(?:vh|vb|vmin|vmax)(?![\w-])/i;

  function viewportUnitPx(unit) {
    var w = screen.width || root.clientWidth, h = screen.height || w;
    unit = unit.toLowerCase();
    if (unit === 'vmin') return Math.min(w, h) / 100;
    if (unit === 'vmax') return Math.max(w, h) / 100;
    return h / 100;
  }

  function pinDeclarations(style) {
    for (var i = 0; i < style.length; i++) {
      var prop = style[i], value = style.getPropertyValue(prop);
      if (!HAS_VIEWPORT_UNIT.test(value)) continue;
      var pinned = value.replace(VIEWPORT_UNIT, function (m, lead, num, unit) {
        return lead + parseFloat(num) * viewportUnitPx(unit) + 'px';
      });
      if (pinned !== value) style.setProperty(prop, pinned, style.getPropertyPriority(prop));
    }
  }

  function pinRules(rules) {
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      if (rule.style && HAS_VIEWPORT_UNIT.test(rule.style.cssText)) pinDeclarations(rule.style);
      if (rule.cssRules) pinRules(rule.cssRules); // @media, @supports, @keyframes…
    }
  }

  function pinViewportUnits() {
    var sheets = doc.styleSheets, i, rules;
    for (i = 0; i < sheets.length; i++) {
      rules = null;
      try { rules = sheets[i].cssRules; } catch (e) { /* başka kökenden gelen sayfa okunamaz */ }
      if (rules) pinRules(rules);
    }
    var inline = doc.querySelectorAll('[style*="vh" i],[style*="vb" i],[style*="vmin" i],[style*="vmax" i]');
    for (i = 0; i < inline.length; i++) {
      if (inline[i].style) pinDeclarations(inline[i].style);
    }
  }

  // ── Yükseklik bildirimi ───────────────────────────────────────────────

  // Uygulamaya {doc, h, w} gönderilir: h içeriğin yüksekliği, w görünen alanın
  // genişliği (ikisi de CSS pikseli). Ekrandaki yüksekliği uygulama kendi
  // genişliği / w ölçeğiyle bulur — sığmayan sabit genişlikli e-postalar
  // Android'de "ekrana sığdır" ile uzaklaştırılmış (ölçek < 1) açılır.
  //
  // Ölçülen şey belgenin kaydırma yüksekliği DEĞİL, gövdeyi saran <kd-root>'tur:
  // `scrollHeight` görünen alandan küçük olamaz (boy hiç kısalamaz) ve
  // `body { height: 100% }` gibi kurallarda WebView'ın kendi boyunu geri
  // döndürür (boy her bildirimde padding kadar büyür).
  // Her bildirim, uygulama tarafında WebView'ı yeniden boyutlandırıp gerçek
  // bir Android görünüm yerleşimi (relayout) tetikler (bkz. `_HtmlWebView`
  // belgesi) — ucuz değildir. Çok sayıda görsel/yazı tipi olan uzun
  // e-postalarda yüklemeler birbirine yakın aralıklarla art arda gelir; bu
  // gecikme, birbirine bu kadar yakın gelen tetikleyicileri TEK bildirime
  // toplar (aşağıdaki `scheduleReport`).
  var REPORT_DEBOUNCE_MS = 120;
  var lastHeight = -1, lastWidth = -1, reportTimer = 0;

  function contentHeight() {
    var wrap = doc.getElementsByTagName('kd-root')[0], body = doc.body;
    if (!wrap || !body) return 0;
    var bs = getComputedStyle(body);
    return wrap.getBoundingClientRect().bottom + (window.pageYOffset || 0) +
      (parseFloat(bs.paddingBottom) || 0) + (parseFloat(bs.borderBottomWidth) || 0) +
      (parseFloat(bs.marginBottom) || 0);
  }

  function report() {
    reportTimer = 0;
    var channel = cfg.channel && window[cfg.channel];
    if (!channel || typeof channel.postMessage !== 'function') return;
    var vv = window.visualViewport;
    var w = (vv && vv.width) || window.innerWidth;
    var h = Math.ceil(contentHeight());
    if (!(h > 0 && w > 0)) return;
    if (Math.abs(h - lastHeight) < 1 && Math.abs(w - lastWidth) < 0.5) return;
    lastHeight = h;
    lastWidth = w;
    channel.postMessage(JSON.stringify({ doc: cfg.doc, h: h, w: w }));
  }

  // Geriye sayan (trailing) debounce: her yeni tetikleyici sayacı sıfırlar,
  // bildirim ancak `REPORT_DEBOUNCE_MS` boyunca yeni bir tetikleyici gelmeyince
  // gider. Böylece art arda gelen çok sayıda görsel/yazı tipi yüklemesi TEK
  // bir bildirime/yeniden boyutlandırmaya iner. rAF yerine zamanlayıcı: WebView
  // ekranın dışındayken (başlık uzun, gövde henüz aşağıda) rAF hiç çalışmayabilir.
  function scheduleReport() {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(function () {
      reportTimer = 0;
      guarded(report);
    }, REPORT_DEBOUNCE_MS);
  }

  function observeLayout() {
    var wrap = doc.getElementsByTagName('kd-root')[0];
    if (wrap && window.ResizeObserver) new ResizeObserver(scheduleReport).observe(wrap);
    // Görsel/yazı tipi yüklemeleri: `load`/`error` kabarcıklanmaz, yakalama
    // aşamasında dinlenir (boyut vermeyen görseller yüklenince yerleşim değişir).
    doc.addEventListener('load', scheduleReport, true);
    doc.addEventListener('error', scheduleReport, true);
    if (doc.fonts && doc.fonts.ready) doc.fonts.ready.then(function () { scheduleReport(); });
    if (window.visualViewport) window.visualViewport.addEventListener('resize', scheduleReport);
    report();
  }

  // ── Başlatma ──────────────────────────────────────────────────────────

  function guarded(fn) {
    try { fn(); } catch (e) { root.setAttribute('data-kd-error', String(e && e.message || e)); }
  }

  function start() {
    guarded(pinViewportUnits);
    guarded(applyFluid);
    guarded(enhance);
    guarded(observeLayout);
    root.setAttribute('data-kd-ms', String(Math.round(performance.now() - startedAt)));
  }

  if (doc.readyState === 'loading') doc.addEventListener('DOMContentLoaded', start);
  else start();

  // WebView'ın gerçek genişliği ilk yerleşimde henüz oturmamış olabilir; genişlik
  // değişince (ya da yükleme bitince) akışkanlaştırma o genişliğe göre yeniden kurulur.
  window.addEventListener('load', function () { guarded(applyFluid); guarded(report); });
  var frame = 0;
  window.addEventListener('resize', function () {
    scheduleReport();
    if (frame) return;
    frame = requestAnimationFrame(function () { frame = 0; guarded(applyFluid); });
  });
})();

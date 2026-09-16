# Bölüm 4 — Tasarım Sistemi

Karar: **Koyu öncelikli, özgün KAYDET mobil dili.** Referansın koyu paleti ve mavi vurgusu esas alınır, düzen sıfırdan telefon için kurgulanır. Açık tema da tam destekli.

## 4.1 İlkeler

1. **Hiçbir widget'ta ham renk yok.** Her renk `Theme.of(context).extension<KaydetTokens>()` üzerinden gelir. Kod incelemesinde `Color(0xFF...)` görülürse reddedilir.
2. **Koyu temada gölge kullanılmaz.** Koyu zeminde `BoxShadow` görünmez. Yükseklik (elevation), daha açık yüzey katmanlarıyla ifade edilir.
3. **Liste okunabilirliği her şeyin önünde.** Uygulamanın %80'i mail listesinde geçer; oradaki hiyerarşi (okundu/okunmadı, gönderen/konu/özet) tasarımın merkezidir.
4. **Android dokunma hedefi minimum 48×48 dp.** İkon 20 dp olsa bile dokunma alanı 48 dp'ye genişletilir.
5. **Renk tek başına anlam taşımaz.** Okunmadı durumu hem mavi nokta **hem** kalın yazı tipiyle belirtilir.

## 4.2 Katman 1 — Primitive Token'lar (ham değerler)

### Nötr skala (mavi-gri slate)
| Token | Değer | Kullanım |
|---|---|---|
| `slate-950` | `#10171A` | En derin katman, yan menü |
| `slate-900` | `#161F23` | Uygulama arka planı (koyu) |
| `slate-850` | `#1C2529` | Yüzey / kart |
| `slate-800` | `#222E33` | Yükseltilmiş yüzey, üst bar |
| `slate-700` | `#2C3A40` | İnce ayraç |
| `slate-600` | `#374850` | Belirgin ayraç, kenarlık |
| `slate-500` | `#4A5D66` | Devre dışı öğe |
| `slate-400` | `#6B7D85` | Üçüncül metin |
| `slate-300` | `#9FB0B8` | İkincil metin |
| `slate-100` | `#E8EEF1` | Birincil metin (koyu tema) |
| `white` | `#FFFFFF` | Açık tema arka planı |

### Mavi skala
| Token | Değer |
|---|---|
| `blue-400` | `#4A9EE0` |
| `blue-500` | `#3A8DDE` |
| `blue-600` | `#2478C7` |
| `blue-700` | `#1B72C4` |
| `blue-800` | `#1565B0` |

### Anlamsal renkler
`red-400 #EC5A5F` · `red-600 #C62A2F` · `green-500 #30A46C` · `amber-500 #F5A623`

### Ölçekler
```
Boşluk (4 dp tabanlı):  0 · 4 · 8 · 12 · 16 · 20 · 24 · 32 · 40 · 48
Köşe yarıçapı:          0 · 4 · 8 · 12 · 16 · 999 (tam yuvarlak)
İkon boyutu:            sm 16 · md 20 · lg 24 · xl 32
Süre (ms):              anlık 0 · hızlı 120 · temel 200 · yavaş 300 · sayfa 320
```

## 4.3 Katman 2 — Anlamsal Token'lar

| Anlamsal token | Koyu tema | Açık tema | Kontrast (koyu) |
|---|---|---|---|
| `bg` | `slate-900` `#161F23` | `#FFFFFF` | — |
| `surface` | `slate-850` `#1C2529` | `#F6F8F9` | — |
| `surfaceElevated` | `slate-800` `#222E33` | `#FFFFFF` | — |
| `textPrimary` | `#E8EEF1` | `#0F1619` | **14.29:1** ✅ |
| `textSecondary` | `#9FB0B8` | `#5A6B73` | **7.47:1** ✅ |
| `textTertiary` | `#6B7D85` | `#7C8B93` | **3.90:1** ✅ |
| `accent` (metin/ikon) | `#4A9EE0` | `#1B72C4` | **5.79:1** ✅ |
| `accentFill` (dolgu) | `#2478C7` | `#1B72C4` | beyaz metin **4.58:1** ✅ |
| `onAccentFill` | `#FFFFFF` | `#FFFFFF` | — |
| `danger` (metin/ikon) | `#EC5A5F` | `#C62A2F` | **4.94:1** ✅ |
| `dangerFill` | `#C62A2F` | `#C62A2F` | beyaz metin **5.57:1** ✅ |
| `success` | `#30A46C` | `#1A7F4B` | **5.30:1** ✅ |
| `warning` | `#F5A623` | `#B26A00` | **8.26:1** ✅ |
| `divider` | `#2C3A40` | `#E3E8EA` | — |
| `border` | `#374850` | `#D3DBDE` | — |
| `scrim` | `rgba(0,0,0,0.55)` | `rgba(0,0,0,0.45)` | — |
| `accentSubtle` (seçili zemin) | `rgba(74,158,224,0.12)` | `rgba(27,114,196,0.08)` | — |

> **Neden iki ayrı mavi?** Koyu temada tek bir vurgu rengi iki işi birden yapamaz. `#4A9EE0` metin/ikon olarak arka planda 5.79:1 verir ama üzerine beyaz yazı konursa 2.89:1'e düşer (başarısız). Bu yüzden dolgu butonlar için bir ton koyu `#2478C7` kullanılır: beyaz metinle 4.58:1, arka plana karşı 3.66:1 — ikisi de geçer. Tek renk kullanan koyu temalar bu yüzden ya okunmaz butonlar ya sönük linkler üretir.

## 4.4 Katman 3 — Bileşen Token'ları

### Mail liste satırı
| Özellik | Değer |
|---|---|
| Yükseklik | ~80 dp (3 satır metin) |
| İç boşluk | yatay 16, dikey 10 |
| Avatar | 40×40, tam yuvarlak |
| Avatar ↔ metin boşluğu | 12 |
| Ayraç | 1 dp `divider`, avatarın solundan başlamaz (tam genişlik) |
| Basılı durum | `surface` (yükseklik değişmez, layout kaymaz) |
| Seçili durum | `accentSubtle` zemin + 3 dp sol `accent` şerit |
| Okunmadı | Gönderen `w700 textPrimary` + konu `w600` + 8 dp `accent` nokta |
| Okundu | Gönderen `w500 textSecondary` + konu `w400` |

### Diğer bileşenler
| Bileşen | Token'lar |
|---|---|
| **Üst bar** | yükseklik 56, zemin `bg`, altında 1 dp `divider`, başlık `titleMedium` |
| **Seçim modu üst barı** | zemin `accentFill`, içerik `onAccentFill` |
| **Alt navigasyon** | yükseklik 60 + güvenli alan, zemin `surfaceElevated`, seçili ikon `accent` + dolu, seçili olmayan `textTertiary` + çizgisel |
| **FAB (Yaz)** | 56×56, `accentFill`, ikon `onAccentFill`, köşe 16 |
| **Etiket çipi** | yükseklik 20, yatay boşluk 8, köşe 4, `labelSmall`, etikete özgü renk |
| **Birincil buton** | yükseklik 48, köşe 12, `accentFill` / `onAccentFill` |
| **İkincil buton** | yükseklik 48, köşe 12, 1 dp `border`, metin `textPrimary` |
| **Yıkıcı buton** | `dangerFill` / beyaz |
| **Metin alanı** | yükseklik 48, zemin `surface`, köşe 10, odakta 1.5 dp `accent` kenarlık |
| **Kaydırma eylemi (sağa)** | zemin `success`, ikon arşiv, beyaz |
| **Kaydırma eylemi (sola)** | zemin `dangerFill`, ikon çöp, beyaz |
| **Diyalog** | köşe 16, zemin `surfaceElevated`, scrim `scrim` |
| **Alt sayfa (bottom sheet)** | köşe üst 20, tutamaç 32×4 `border` |

## 4.5 Tipografi

**Yazı tipi: Inter.** Türkçe karakterleri (ş, ğ, İ, ı, ö, ü, ç) tam destekler, ekran okunabilirliği için tasarlanmıştır, değişken ağırlık sunar.

> `google_fonts` paketi yerine Inter **uygulama içine gömülecek** (assets). Çevrimdışı öncelikli bir uygulamada yazı tipini çalışma anında indirmek, ilk açılışta yazı sıçramasına ve uçak modunda yedek fonta düşmeye yol açar.

| Rol | Boyut / satır yüks. | Ağırlık | Kullanım |
|---|---|---|---|
| `titleLarge` | 20 / 28 | 700 | Ekran başlığı, mail konusu (detay) |
| `titleMedium` | 16 / 22 | 600 | Üst bar başlığı, bölüm başlığı |
| `bodyLarge` | 16 / 24 | 400 | **Mail gövdesi** (satır yüksekliği 1.5 — Outlook okuma bölmesi ölçeği) |
| `listSender` | 16 / 20 | 500 / **700** | Liste: gönderen (okundu / okunmadı) |
| `listSubject` | 15 / 20 | 400 / **600** | Liste: konu |
| `listPreview` | 14 / 18 | 400 | Liste: özet — `textTertiary` |
| `labelMedium` | 12 / 16 | 600 | Butonlar, sekmeler |
| `labelSmall` | 11 / 14 | 600 | Tarih, çipler, sayaçlar |
| `overline` | 10 / 14 | 700 | Bölüm etiketleri, +0.8 harf aralığı, BÜYÜK HARF |

**Türkçe kuralı:** Büyük harfe çevirme (`toUpperCase`) yalnızca `overline` rolünde ve **`tr` locale ile** yapılır (`'ısı'.toUpperCase('tr')` → `ISI`, varsayılan locale'de yanlışlıkla `ISI` yerine `ISI` farkı ve `i→İ` dönüşümü bozulur). Dart'ta `toUpperCase()` locale duyarsızdır; bu yüzden büyük harf dönüşümü **çalışma anında yapılmaz**, metin zaten büyük yazılır veya `intl` üzerinden çevrilir.

**Dinamik yazı boyutu:** Sistem yazı boyutu ayarı desteklenir, `textScaler` 1.0–1.6 aralığında sınırlanır; liste satırı sabit yükseklik yerine minimum yükseklikle tanımlanır, böylece büyük yazıda taşma olmaz.

## 4.6 Avatar Renk Paleti (üretildi ve doğrulandı)

Gönderen adının ilk karakterinden deterministik seçilir (aynı kişi hep aynı renk). 15 ton, tüm tonlarda **harf/zemin kontrastı ≥ 6:1**.

| # | Ad | Koyu zemin | Koyu harf | Açık zemin | Açık harf |
|---|---|---|---|---|---|
| 1 | kırmızı | `#56312E` | `#E8B4B0` | `#F0DCDB` | `#6F2520` |
| 2 | turuncu | `#563A2E` | `#E8C1B0` | `#F0E1DB` | `#6F3820` |
| 3 | kehribar | `#56442E` | `#E8CEB0` | `#F0E6DB` | `#6F4A20` |
| 4 | altın | `#564C2E` | `#E8DAB0` | `#F0EBDB` | `#6F5B20` |
| 5 | zeytin | `#55562E` | `#E6E8B0` | `#EFF0DB` | `#6C6F20` |
| 6 | yeşil | `#44562E` | `#CEE8B0` | `#E6F0DB` | `#4A6F20` |
| 7 | çimen | `#2E563C` | `#B0E8C3` | `#DBF0E2` | `#206F3A` |
| 8 | zümrüt | `#2E564E` | `#B0E8DD` | `#DBF0EC` | `#206F5F` |
| 9 | turkuaz | `#2E5156` | `#B0E1E8` | `#DBEDF0` | `#20646F` |
| 10 | gök | `#2E4656` | `#B0D1E8` | `#DBE7F0` | `#204E6F` |
| 11 | mavi | `#2E3456` | `#B0B7E8` | `#DBDEF0` | `#202B6F` |
| 12 | indigo | `#3A2E56` | `#C1B0E8` | `#E1DBF0` | `#38206F` |
| 13 | mor | `#4C2E56` | `#DAB0E8` | `#EBDBF0` | `#5B206F` |
| 14 | orkide | `#562E4E` | `#E8B0DD` | `#F0DBEC` | `#6F205F` |
| 15 | gül | `#562E3D` | `#E8B0C5` | `#F0DBE3` | `#6F203D` |

**Seçim algoritması:** React'teki `name.charCodeAt(0) % 15` yetersiz — "Ahmet", "Ali", "Ayşe" hep aynı rengi alır. Yerine e-posta adresinin tamamından **FNV-1a hash** kullanılır: aynı kişi hep aynı renk, farklı kişiler dengeli dağılır.

**Seçili durumda** avatar `accentFill` zemin + beyaz onay ikonuna döner (React'teki davranış korunur).

## 4.7 Yükseklik (Elevation) — koyu temada gölge yok

| Seviye | Koyu tema | Açık tema |
|---|---|---|
| 0 (zemin) | `bg` | `bg` |
| 1 (kart, liste yüzeyi) | `surface` | `surface` + 1 dp kenarlık |
| 2 (üst bar, alt bar) | `surfaceElevated` | `bg` + alt gölge `0 1 3 rgba(0,0,0,.08)` |
| 3 (FAB, alt sayfa) | `surfaceElevated` + 1 dp `border` | `bg` + gölge `0 4 12 rgba(0,0,0,.12)` |
| 4 (diyalog) | `surfaceElevated` + scrim | `bg` + gölge `0 8 24 rgba(0,0,0,.16)` |

## 4.8 Hareket (Motion)

| Etkileşim | Süre | Eğri |
|---|---|---|
| Basılı durum geri bildirimi | 120 ms | `Curves.easeOut` |
| Liste öğesi kaydırma eylemi | 200 ms | `Curves.easeOutCubic` |
| Sayfa geçişi (ileri) | 320 ms | `Curves.fastOutSlowIn` |
| Sayfa geçişi (geri) | 240 ms | `Curves.fastOutSlowIn` |
| Yan menü aç/kapa | 280 / 220 ms | `Curves.easeOutCubic` |
| Alt sayfa | 260 / 200 ms | `Curves.easeOutCubic` |
| Seçim modu üst bar rengi | 200 ms | `Curves.easeInOut` |

**Kurallar:**
- **Çıkış her zaman girişten hızlı** (kullanıcı zaten kararını vermiştir).
- Liste öğelerine giriş animasyonu (stagger) **yapılmaz** — sonsuz kaydırmalı listede her sayfa yüklemesinde titreşim yaratır.
- `MediaQuery.disableAnimationsOf(context)` true ise tüm süreler 0'a iner; erişilebilirlik ayarına saygı duyulur.
- Animasyon asla `width`/`height` üzerinden yapılmaz (layout yeniden hesabı) — `opacity`, `transform`, `Align` kullanılır.

## 4.9 İkonlar

**`lucide_icons_flutter` 3.1.19** (7 gün önce güncellendi) — React prototipindeki Lucide ailesi Flutter'da birebir korunur. Böylece prototipteki ikon kararları (Inbox, Send, Pin, Tag, Archive, Trash2...) aynen taşınır.

- Tüm ikonlar **çizgisel (outline)**, çizgi kalınlığı **2.0** — tek istisna: seçili alt navigasyon sekmesi ve sabitlenmiş mail göstergesi **dolu** olur.
- Boyutlar yalnızca token'lardan: 16 / 20 / 24 / 32.
- Her ikon butonunun `tooltip` ve `semanticLabel` değeri Türkçe yazılır (ekran okuyucu için zorunlu).
- **Emoji ikon olarak kullanılmaz.**

## 4.10 Flutter Uygulaması

```dart
// ui/core/theme/tokens.dart
@immutable
class KaydetTokens extends ThemeExtension<KaydetTokens> {
  final Color bg, surface, surfaceElevated;
  final Color textPrimary, textSecondary, textTertiary;
  final Color accent, accentFill, onAccentFill, accentSubtle;
  final Color danger, dangerFill, success, warning;
  final Color divider, border, scrim;
  final List<AvatarTone> avatarTones;
  // + copyWith / lerp
}
```

- `KaydetTokens.dark` ve `KaydetTokens.light` iki sabit örnek.
- `ThemeData(extensions: [KaydetTokens.dark])`, erişim: `context.tokens.accent` (kısayol uzantısı).
- Tema modu: sistem / açık / koyu — Ayarlar'dan seçilir, `SharedPreferences`'ta saklanır.
- **Doğrulama:** CI'da basit bir betik `lib/ui/**` altında `Color(0x` ve `Colors.` kullanımını arar; bulursa derleme başarısız olur.

## 4.11 Erişilebilirlik Kontrol Listesi (teslim öncesi)

- [ ] Birincil metin ≥ 4.5:1, ikincil ≥ 3:1 — **her iki temada** (ölçüldü ✅)
- [ ] Tüm dokunma hedefleri ≥ 48×48 dp
- [ ] Her ikon butonunda Türkçe `semanticLabel`
- [ ] Renk tek başına anlam taşımıyor (okunmadı = nokta + kalınlık)
- [ ] Ekran okuyucu odak sırası görsel sırayla aynı
- [ ] `disableAnimations` desteği
- [ ] Sistem yazı boyutu 1.6×'ta taşma yok
- [ ] Güvenli alanlar (çentik, gezinme çubuğu) her sabit barda hesaba katıldı
- [ ] Modal scrim opaklığı %45–60

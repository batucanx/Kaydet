# KAYDET — Flutter Mail İstemcisi | Yol Haritası

## Alınan Kararlar (2026-09-14)

| Konu | Karar |
|---|---|
| Çekirdek | **Gerçek IMAP/SMTP** istemcisi (simülasyon değil) |
| Platform | **Android** (tek hedef) |
| State | **Riverpod** (kod üretimli, `@riverpod`) |
| Veritabanı | **Drift** (SQLite + FTS5 tam metin arama) |
| Navigasyon | **go_router** |
| v1 kapsamı | Ek dosyalar + HTML render + Thread görünümü + Swipe hareketleri + Karanlık tema — **hepsi ilk sürümde** |
| Referans | Kullanıcı referans görselleri sağlayacak (UI bölümünde istenecek) |

## Ortam Durumu

- Flutter **3.44.8** (stable), Dart **3.12.2**, JDK **21** — uygun.
- Android SDK 36.1.0 kurulu, ancak **`cmdline-tools` eksik** → lisans kabulü ve bazı Gradle işlemleri bloklanabilir.
- **Bağlı Android cihaz/emülatör yok** (yalnızca Chrome/Edge görünüyor).
- Yapılacak: `cmdline-tools` kurulumu + en az bir emülatör veya fiziksel cihaz.

## Bölümler

| # | Dosya | Bölüm | Durum |
|---|---|---|---|
| 0 | — | Ortam hazırlığı & proje iskeleti | ✅ Tamam |
| 0.5 | `02` §2.11 | **Spike:** gerçek sunucuya karşı doğrulama | ⏸ Şifre ve cihaz olmadığı için yapılamadı — README'de kontrol listesi |
| 1 | `01` | Mimari, domain modeli, veritabanı şeması | ✅ **Onaylandı** |
| 2 | `02` | Mail motoru: IMAP/SMTP senkronizasyon stratejisi | ✅ **Onaylandı** |
| 3 | `03` | Referans görsel analizi | ✅ **Onaylandı** |
| 4 | `04` | Tasarım sistemi (token'lar, tema, tipografi) | ✅ Onaylandı ve uygulandı |
| 5 | — | Ekran ekran UI + etkileşim planı | ✅ Doğrudan koda döküldü (34 uçtan uca test) |
| 6 | — | Arka plan senkronizasyonu + bildirimler | ✅ Kodlandı (cihazda doğrulanmalı) |
| 7 | `README.md` | Test, hata yönetimi, yayın | ✅ 133 test, release APK |
| 8 | `05` | v1.1 — eM Client paritesi (çoklu hesap, OAuth, takvim/kişiler/notlar, üretkenlik) | 🔄 Faz 1 (çoklu hesap) tamam, gerisi bekliyor |

## Karar Günlüğü

**Bölüm 1–2**
- **Sabitleme = IMAP `\Flagged`** — cihazlar arası senkron, `starred` alanı kaldırıldı.
- **Etiketler** — sunucu keyword destekliyorsa sunucuya, desteklemiyorsa yerel + uyarı.
- **Çoklu hesap** — şema hazır, arayüz v1.1'de açılacak. **[Güncelleme 2026-09-15: v1.1'de "hesap değiştirici" modeliyle kodlandı, bkz. `05`.]**
- **`enough_mail` sürümü sabitlenecek** ve soyut servis arayüzü arkasına alınacak (13 aydır güncellenmemiş).

**Bölüm 3–4 (referans görselleri sonrası)**
- **Kapsam: önce Mail.** Takvim (CalDAV) ve Kişiler (CardDAV) v2'ye alındı; veritabanı ve navigasyon üç modüle hazır kurulur.
- **Tasarım: koyu öncelikli özgün KAYDET mobil dili** — referansın paleti, telefona uygun ergonomi. Açık tema da tam destekli.
- **Test hesabı: `pazarlik.com.tr`** — IMAP 993/SSL, SMTP 465/SSL, DAV 2080.
- **Takvim arayüzü (v2): `table_calendar` + özel zaman çizelgesi** — Syncfusion lisans riski alınmadı.

## Doğrulanmış Sunucu Ayarları

```
IMAP   mail.pazarlik.com.tr : 993  SSL/TLS
SMTP   mail.pazarlik.com.tr : 465  SSL/TLS
DAV    mail.pazarlik.com.tr : 2080 SSL/TLS   (v2: takvim + kişiler)
Kullanıcı adı: tam e-posta adresi
```

Kural: Her bölüm onaylanmadan bir sonrakine geçilmez, kod yazılmaz.

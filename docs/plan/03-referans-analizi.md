# Bölüm 3 — Referans Görsel Analizi

## 3.1 Referans Neyin Ekran Görüntüsü?

Verilen 10 görselin tamamı **Roundcube Webmail (Elastic teması, koyu mod)** — cPanel üzerinde çalışan `webmail.pazarlik.com.tr` adresindeki webmail arayüzü. URL kanıtı: `webmail.pazarlik.com.tr/cpsess4454100806/3rdparty/roundcube/?_task=mail&_mbox=INBOX`

Bu, bir **masaüstü web arayüzüdür** — mobil uygulama tasarımı değildir. Üç panelli düzen (sol rail + klasör listesi + mail listesi + okuma bölmesi) doğrudan telefona taşınamaz.

## 3.2 Sunucu Ayarları (görselden çıkarıldı — Bölüm 1.8'in cevabı)

`GELEN-ORNEK.png` içindeki cPanel yapılandırma maili net bilgi veriyor:

| Servis | Sunucu | Port | Güvenlik |
|---|---|---|---|
| **IMAP** | mail.pazarlik.com.tr | **993** | SSL/TLS |
| POP3 | mail.pazarlik.com.tr | 995 | SSL/TLS (kullanılmayacak) |
| **SMTP** | mail.pazarlik.com.tr | **465** | SSL/TLS (implicit) |
| **CalDAV / CardDAV** | https://mail.pazarlik.com.tr | **2080** | SSL/TLS |

- Kullanıcı adı: tam e-posta adresi (`info@pazarlik.com.tr`)
- IMAP, POP3 ve SMTP kimlik doğrulama ister.
- Prototipteki `port 110 / NONE` ayarı **yanlıştı**; doğrusu 993/SSL.

## 3.3 Uygulamanın Gerçek Kapsamı: 4 Modül

Sol rail, uygulamanın mail istemcisinden çok daha fazlası olduğunu gösteriyor:

| Rail öğesi | Modül | React prototipinde var mıydı? |
|---|---|---|
| **Hazırla** | Mail yazma | ✅ vardı |
| **İletiler** | Mail | ✅ vardı |
| **Kişiler** | Adres defteri (CardDAV) | ❌ **YOK** |
| **Calendar** | Takvim (CalDAV) | ❌ **YOK** |
| **Ayarlar** | Ayarlar | ✅ vardı |
| Webmail Home / Açık kip / Hakkında / Kapat | cPanel dönüşü, tema, hakkında, çıkış | kısmen |

## 3.4 Mail Modülü — Referansta Görülüp Prototipte Olmayanlar

**Klasörler (gerçek sunucu):** Gelen · Taslak · Gönderilmiş · İstenmeyen · Çöp · **Arşiv**
> Prototipte Arşiv yoktu (sadece `alert()`), "Sabitlenenler" ise KAYDET'e özgü sanal klasör olarak kalacak (`\Flagged`).

**Liste satırı düzeni (referans):** Gönderen (üst satır) + tarih sağda → alt satırda okunmadı noktası (●) + konu + ek ataşı (📎). Yani referansta **2 satır**, React prototipinde 3 satır (gönderen / konu / özet) vardı.

**Okuma ekranı:** Konu → gönderen avatarı + "X göndericisinden <tarih> tarihinde" → `Ayrıntılar` / `Üst bilgiler` / `Düz metin` bağlantıları → ekler şeridi → gövde.

**Araç çubuğu:** Yanıtla · Toplu yanıtla (reply-all) · İlet · Sil · Arşivle · İstenmeyen · İşaretle · Diğer

**Yazma ekranında yeni olanlar:**
- **Gönderici (identity) seçimi** — birden fazla kimlik
- **Alındı onayı istensin** (read receipt / MDN)
- **Teslim onayı istensin** (DSN)
- **Öncelik** (Normal / Yüksek / Düşük → `X-Priority` başlığı)
- **Gönderilen ileti şuraya kaydedilsin** (hedef klasör seçimi)
- **Hazır yanıt** (canned responses)
- **İmza** butonu
- **Zengin metin editörü** (HTML mail yazma)
- Ek dosya limiti: **75 MB**

**Alt bilgi:** Kota göstergesi (%0) + sayfalama (İletiler: 1-3, Toplam: 3)

## 3.5 Kişiler Modülü (CardDAV)

Gruplar: Kişisel adresler · Imported Contacts · Derlenmiş alıcılar (collected recipients) · Güvenilen göndericiler · **cPanel CardDAV**

Araçlar: Ekle · Yazdır · Sil · Ara · İçe aktar · Dışa aktar · Diğer

> "Derlenmiş alıcılar" ve "Güvenilen göndericiler" Roundcube'ün otomatik defterleridir; bunlar sunucu tarafı özelliğidir, mobil uygulamada karşılığı yerel olarak üretilebilir.

## 3.6 Takvim Modülü (CalDAV)

**Takvimler:** Default · cPanel CalDAV Calendar (her biri aç/kapa + görünürlük ikonu, renk göstergesi)

**Görünümler:** Day · Week · Month · **Agenda** — üstte tarih aralığı, `Bugün` butonu, ileri/geri okları, saat dilimi (Europe/Istanbul), sol altta mini ay takvimi (hafta numaralı).

**Etkinlik ekleme — 4 sekmeli diyalog:**

| Sekme | Alanlar |
|---|---|
| **Summary** | Summary, Location, Description, Start (tarih+saat), End, **all-day** anahtarı, Reminder (+ ekleme), Calendar, Category, Status, **Show me as** (Busy/Free), Priority, URL |
| **Recurrence** | Repeat (never / günlük / haftalık / aylık / yıllık → RRULE) |
| **Participants** | Role (Organizer...), Participant (e-posta), Status, "Add participant", **Invitation/notification comment** (iTIP daveti gönderir) |
| **Attachments** | Dosya ekle — limit **1,0 GB** |

Araçlar: Ekle · Print · İçe aktar · Export

## 3.7 Görsel Dil (referanstan ölçülen)

| Öğe | Değer |
|---|---|
| Uygulama arka planı | Koyu lacivert-gri (~`#1C2529` / `#222E33` bandı) |
| Panel ayrımı | Daha koyu sol rail, ince açık ayraçlar |
| Vurgu / bağlantı | Canlı mavi (~`#3A8DDE` / `#4FA3E3`) |
| Seçili satır | Mavi sol kenar çizgisi + hafif açık arka plan |
| Okunmadı göstergesi | Dolu daire (●) + kalın konu |
| Birincil buton (Gönder/Save) | Mavi dolgu, beyaz metin |
| Tehlike | Kırmızı (Kapat / Sil) |
| Tipografi | Sistem sans-serif, düşük kontrastlı ikincil metin |
| İkonlar | Çizgisel (outline), etiketli (ikon + altında metin) |

## 3.8 Eksik Referanslar

Bu ekranların görselleri gelmedi:

- [ ] **Ayarlar** ekranının içeriği (tercihler, klasörler, kimlikler, filtreler...)
- [ ] **Kişi ekleme / kişi detay** formu (liste boş geldi)
- [ ] **Giriş (login)** ekranı
- [ ] Gerçek **HTML içerikli bir mail**in okuma görünümü (örnekler düz metindi)
- [ ] **Hazır yanıt** (canned response) ekranı
- [ ] **İstenmeyen / Çöp / Arşiv** klasörlerinin görünümü
- [ ] **Mobil görünüm** — Roundcube Elastic teması telefonda tek panele düşer. Varsa o görüntüler bizim için masaüstü görselinden çok daha değerli.
- [ ] Takvimde **dolu bir hafta/ay** görünümü (etkinlikli)

## 3.9 Teknik Fizibilite: CalDAV / CardDAV (pub.dev doğrulaması, 2026-09-14)

| İhtiyaç | Paket | Durum |
|---|---|---|
| CalDAV istemcisi | **`caldav` 1.5.0** (2026-06-13) | ✅ Aktif. Etkinlik CRUD, RFC 6764 sunucu keşfi, çoklu kimlik doğrulama. Dart 3.10+ (bizde 3.12 ✓) |
| vCard ayrıştırma/üretme | **`vcard_dart` 2.1.0** (2026-01-20) | ✅ vCard 2.1/3.0/4.0 + jCard/xCard, bağımlılık yok |
| **CardDAV protokolü** | — | ⚠️ **Hazır paket yok.** `dio` + `xml` ile ince bir WebDAV katmanı yazılacak (PROPFIND / REPORT / PUT / DELETE). CalDAV'a göre çok daha basit, ~300 satır |
| Takvim arayüzü | `syncfusion_flutter_calendar` 34.2.7 | ⚠️ **Ticari lisans.** Gün/hafta/ay/ajanda görünümleri referansla birebir örtüşüyor ama Syncfusion community lisansı yalnızca yıllık geliri 1M $ altındaki ve 5'ten az geliştiricili şirketler için ücretsiz |
| Takvim arayüzü (alternatif) | `table_calendar` 3.2.1 | ✅ MIT, aktif. Ama yalnızca **ay görünümü** verir; gün/hafta zaman çizelgesi elle yazılır |

## 3.10 Karara Bağlanacaklar

1. **Kapsam:** Mail + Kişiler + Takvim aynı anda mı, yoksa önce Mail mi?
2. **Tasarım yönü:** Roundcube'ün koyu teması mı taklit edilecek, yoksa prototipteki beyaz minimalist KAYDET dili mi korunacak?
3. **Hangi hesap?** Referanslar `pazarlik.com.tr`, React prototipi `barzamakina.com.tr` diyordu.
4. **Takvim arayüzü:** Syncfusion (lisans) / table_calendar + özel zaman çizelgesi / tamamen özel.

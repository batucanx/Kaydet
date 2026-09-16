# KAYDET — İnşa İlerlemesi

> Bu dosya otonom çalışma sırasında bağlam kaybına karşı tutulur. Her adım bitince güncellenir.

## Sabit Bağlam (her oturumda geçerli)

- **Proje kökü:** `C:\Projects\KAYDET` — Flutter uygulaması kökte, planlar `docs/plan/`, referanslar `Referances/`
- **Kapsam v1:** yalnızca **Mail**. Takvim (CalDAV) ve Kişiler (CardDAV) v2 — navigasyonda "yakında" olarak durur.
- **Sunucu:** `mail.pazarlik.com.tr` — IMAP 993 SSL, SMTP 465 SSL, kullanıcı adı tam e-posta
- **Şifre yok:** Gerçek sunucuya karşı test yapılamaz. Kimlik bilgileri giriş ekranından girilir, `flutter_secure_storage`'a yazılır.
- **Cihaz yok:** Android emülatör/cihaz bağlı değil, `cmdline-tools` eksik. Doğrulama `flutter analyze` + `flutter test` ile yapılır.
- **Tasarım:** `docs/plan/04-tasarim-sistemi.md` — token'lar birebir uygulanır, ham renk yasak.

## Kod Üretimi Kararı (plandan sapma, gerekçeli)

Plan `freezed` + `riverpod_generator` + `drift_dev` öngörüyordu = üç ayrı build_runner üreteci.
**Karar: yalnızca `drift_dev` kullanılıyor.** Modeller ve provider'lar elle yazılıyor.
**Gerekçe:** Üç üreteç arasında sürüm çakışması riski var ve otonom çalışmada kullanıcıya soru soramadan bu tür bir çakışmayı çözmek pahalı. Riverpod'un kodsuz API'si (`NotifierProvider`, `StreamProvider`) tam desteklidir. Elle yazılan modeller biraz daha uzun ama sıfır risk.

## Aşamalar

| # | Aşama | Durum |
|---|---|---|
| A | Proje iskeleti + bağımlılık çözümü | ✅ |
| B | Çekirdek: token'lar, tema, Result, Türkçe, tarih | ✅ |
| C | Veri: Drift şeması + DAO'lar + güvenli depolama | ✅ (17 test geçti) |
| D | Domain: modeller + use case'ler | ✅ |
| E | Servisler: IMAP/SMTP soyutlaması + enough_mail uygulaması | ✅ |
| F | Repository'ler + senkronizasyon motoru + bekleyen işlem kuyruğu | ✅ |
| G | UI: giriş, kabuk, liste, detay, yazma, ayarlar | ✅ |
| H | Arka plan senkronizasyonu + bildirimler | ✅ |
| I | Testler + `flutter analyze` temiz + son kontrol | ✅ (136 test, 0 uyarı, release APK derleniyor) |

## Ek Kararlar (inşa sırasında)

- **Drift satır sınıfları doğrudan UI'de kullanılıyor.** Plan ayrı domain modelleri öngörüyordu; ancak drift'in ürettiği sınıflar zaten değişmez (immutable), `copyWith` ve eşitlik taşıyor. Asıl izole edilmesi gereken riskli bağımlılık `enough_mail` idi ve o tamamen `data/services/` içinde kaldı. İki kat model yazmak kod hacmini ve hata yüzeyini gereksiz büyütürdü.
- **Inter yazı tipi `latin-ext` alt kümesiyle indirildi.** Varsayılan `latin` alt kümesinde Ğ ğ Ş ş İ karakterleri YOK; bu doğrulanmadan gömülseydi Türkçe metinler bozuk görünecekti. Dört ağırlığın da Türkçe kapsamı testle doğrulandı.
- **Arama tam metin (FTS5) + Türkçe katlama.** "sahan" → "Şahan", "ozet" → "Özeti" testle doğrulandı.
- **FTS sorgusu temizleniyor.** Ham kullanıcı girdisi FTS5'e verilirse `"`, `*`, `NEAR(` gibi karakterler sözdizimi hatası fırlatır ve arama çöker. Her sözcük tırnaklanıp önek eşlemeye çevriliyor; testle doğrulandı.
- **Önizleme metni gövdeden üretiliyor.** Kısmi gövde çekme (`BODY[1]<0.2048>`) her sunucuda güvenilir değil; bunun yerine en yeni iletilerin gövdesi arka planda önceden indirilip önizleme oradan çıkarılıyor.

## Günlük

- Proje iskeleti kuruldu, 223 paket çakışmasız çözüldü.
- `enough_mail` API'si kaynak koddan doğrulandı (tahmin edilmedi).
- Veritabanı 17 testle doğrulandı: şema, kısmi tekil indeks, cascade, FTS5, UIDVALIDITY temizliği, kuyruk, gövde budama.

## İnşa Sırasında Testlerin Yakaladığı Gerçek Hatalar

Bunlar tahmin değil; testler çalıştırıldığında ortaya çıkan ve düzeltilen
davranış hatalarıdır.

1. **`İlt:` ön eki temizlenmiyordu.** Düzenli ifadenin `caseSensitive: false`
   seçeneği `İ` (U+0130) harfini `i` ile eşleştirmez. Türkçe yanıt ön ekiyle
   gelen iletiler ayrı konuşmalarda kalıyordu. Ön ek karşılaştırması artık
   `foldForSearch` üzerinden yapılıyor.
2. **Boş konulu, başlıksız iletiler tek konuşmada birikiyordu.** Yedek kimlik
   mikrosaniye damgasından üretiliyordu ve aynı mikrosaniyede üretilen iki
   kimlik çakışıyordu. Sayaç eklendi.
3. **Kullanıcı eylemleri sunucuya geç gidiyordu.** Silme/okundu/sabitleme
   kuyruğa giriyor ama kuyruk yalnızca eşitleme sırasında işleniyordu; yani
   işlem 15 dakikaya kadar bekleyebiliyordu. Artık her eylemden sonra kuyruk
   anında tetikleniyor (`kickQueue`), ağ yoksa bağlantı gelince işleniyor.
4. **Yazı tipinde Türkçe karakterler eksikti.** Google Fonts varsayılan `latin`
   alt kümesinde Ğ ğ Ş ş İ yok. `latin-ext` ile yeniden indirildi ve dört
   ağırlığın da kapsamı doğrulandı.
5. **Bağlantı zamanlayıcısı kapanışta iptal edilmiyordu.** `disconnect()`
   canlı-tutma zamanlayıcısını kilidin arkasında iptal ediyordu; artık
   eşzamanlı olarak durduruluyor.
6. **Kalıcı silme onaysızdı.** "Silmeden önce sor" ayarı vardı ama hiçbir yerde
   okunmuyordu; Çöp Kutusu içinde tek dokunuşla ileti sunucudan da kalıcı
   siliniyordu. Artık kalıcı silmede onay diyaloğu çıkıyor (3 testle korunuyor).

## Planlanandan Sapmalar (gerekçeli)

- **Tek kod üreteci.** `freezed` ve `riverpod_generator` yerine yalnızca
  `drift_dev`. Üç üreteç arasındaki sürüm çakışmasını kullanıcıya soramadan
  çözmek pahalı olurdu; Riverpod'un kodsuz API'si tam desteklidir.
- **Drift satır sınıfları doğrudan arayüzde.** Asıl izole edilmesi gereken
  riskli bağımlılık `enough_mail`'di ve tamamen servis katmanında kaldı.
- **`permission_handler` kaldırıldı.** Hiç kullanılmıyordu ve `android-37`
  platformunu zorunlu kılarak derlemeyi engelliyordu. Bildirim izni
  `flutter_local_notifications`, mikrofon izni `speech_to_text` üzerinden.
- **`flutter_widget_from_html` yerine `_core`.** Tam paket webview ve
  video_player getiriyordu; yalnızca HTML render gerekiyor.

## Sonuç

- `flutter analyze` → **0 uyarı**
- `flutter test` → **136 test, hepsi geçiyor**
- `flutter build apk --release --split-per-abi` → **22–25 MB, başarılı**
- Gerçek sunucuya karşı ve cihazda çalıştırma **yapılamadı** (şifre ve cihaz yok);
  ayrıntı ve kontrol listesi için `README.md`.

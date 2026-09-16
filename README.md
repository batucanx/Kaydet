# KAYDET

Android için gerçek IMAP/SMTP e-posta istemcisi. Flutter ile yazıldı.

---

## Hızlı başlangıç

```bash
flutter pub get
dart run build_runner build
flutter run
```

Uygulama açılışta giriş ekranı gösterir. E-posta adresi yazıldığında sunucu
adları alan adından tahmin edilir (`info@pazarlik.com.tr` → `mail.pazarlik.com.tr`);
gerekirse "Sunucu ayarları" bölümünden düzeltilir.

`pazarlik.com.tr` için doğru ayarlar:

| | Sunucu | Port | Güvenlik |
|---|---|---|---|
| IMAP | mail.pazarlik.com.tr | 993 | SSL/TLS |
| SMTP | mail.pazarlik.com.tr | 465 | SSL/TLS |

Şifre yalnızca cihazda, Android Keystore ile şifrelenmiş olarak saklanır
(`flutter_secure_storage`). Veritabanına, log'a veya koda hiçbir zaman yazılmaz.

### Sürüm alma

```bash
flutter build apk --release --split-per-abi
```

Çıktı: cihaz mimarisi başına ~22–25 MB APK. Tek dosyalık (fat) APK 67 MB olur
çünkü üç mimarinin de yerel kütüphanelerini taşır; dağıtım için `--split-per-abi`
veya `flutter build appbundle` tercih edilmelidir.

---

## Ne yapar

**Mail**
- Gerçek IMAP bağlantısı: klasörler, iletiler, bayraklar, ekler
- Çevrimdışı öncelikli: her şey cihazda saklanır, uçak modunda tam çalışır
- Sonsuz kaydırma — yerelde biterse sunucudan bir sonraki sayfa indirilir
- Tam metin arama (SQLite FTS5) — Türkçe karakter katlamasıyla: "sahan" → "Şahan"
- Konuşma (thread) gruplama — `References`/`In-Reply-To` başlıklarından yerel hesap
- HTML ileti gösterimi; uzak görseller gizlilik için varsayılan olarak engelli
- Ek dosya indirme ve cihazda açma; gönderirken dosya ekleme
- Çoklu seçim: sil, okundu/okunmadı, sabitle, arşivle, taşı, etiketle
- Kaydırma hareketleri: sağa arşivle, sola sil
- Yazma: Kime/Bilgi/Gizli, yanıtla, tümünü yanıtla, ilet
- Sesli yazma (Türkçe konuşma tanıma)
- Otomatik taslak kaydetme (3 sn yazma duraklamasında) + çıkışta taslak diyaloğu
- Giden kutusu: ağ yokken yazılan ileti kaybolmaz, bağlantı gelince gönderilir
- Bildirimler + arka plan senkronizasyonu (WorkManager)
- Koyu ve açık tema, sistem ayarını izleme
- Etiket yönetimi (ad + renk); sunucu destekliyorsa IMAP anahtar kelimesi olarak yazılır

**Yakında (v2)**
- Takvim (CalDAV) ve Kişiler (CardDAV) — hamburger menüdeki modül listesinde sekmeleri hazır, içerikleri yok

---

## Mimari

```
lib/
├── core/        Result/AppFailure, Türkçe metin, tarih, avatar hash
├── data/
│   ├── database/     Drift şeması + sorgular (tek doğruluk kaynağı)
│   ├── services/     ImapService, SmtpService, SecureStore, bildirim, ayarlar
│   └── repositories/ MailConnection, SyncEngine, MailRepository, AccountRepository
├── domain/      Servis sınırı modelleri + use case'ler (threading, klasör eşleme, metin)
├── app/         Riverpod sağlayıcıları, SyncController, arka plan görevi
└── ui/          Tema token'ları, ortak widget'lar, ekranlar
```

**Temel kural:** Arayüz hiçbir zaman ağı beklemez. Her kullanıcı eylemi önce
yerel veritabanına yazılır (ekran anında tepki verir), sonra kuyruğa girer ve
sunucuya işlenir. Sunucu reddederse bir sonraki eşitleme yerel durumu düzeltir —
sistem kendini onarır.

**`enough_mail` yalnızca iki dosyada geçer** (`imap_service.dart`, `smtp_service.dart`).
Paket 13 aydır güncellenmediği için sürümü sabitlendi (`enough_mail: 2.1.7`) ve
soyut arayüz arkasına alındı; gerekirse değişecek kod iki dosyadır.

Ayrıntılı planlar: [`docs/plan/`](docs/plan/)

---

## Mail istemcilerinin bozulduğu yerler ve buradaki karşılıkları

| Tehlike | Bu uygulamadaki önlem |
|---|---|
| **UIDVALIDITY değişimi** — sunucu klasörü yeniden oluşturduğunda eski UID'ler geçersizleşir; kontrol edilmezse **yanlış ileti silinir** | Her eşitlemede karşılaştırılır; değiştiyse klasörün yerel önbelleği silinip baştan indirilir (yerel taslaklar korunur) |
| **`BODY[]` ile okuma** sunucuya iletiyi okundu işaretletir | Her yerde yalnızca `BODY.PEEK[]` kullanılır |
| **Gönderim + Sent'e yazma tek işlem sayılırsa** APPEND hatasında ileti iki kez gönderilir | SMTP gönderimi ve IMAP `APPEND` ayrı adımlardır; gönderim başarılıysa bir daha asla tekrarlanmaz |
| **Silme = EXPUNGE** sayılırsa veri geri dönülemez biçimde kaybolur | Normal klasörde silme Çöp Kutusu'na taşır; kalıcı silme yalnızca Çöp Kutusu/İstenmeyen içinde ve **onay diyaloğuyla** (testle doğrulandı) |
| **Bozuk MIME** tüm listeyi çökertir | Ayrıştırılamayan ileti ham hâliyle gösterilir, liste açılmaya devam eder |
| **Türkçe klasör adları** (`Gönderilmiş Öğeler`, `Önemsiz`) tanınmaz | Önce sunucunun SPECIAL-USE bayrağı, sonra Türkçe/İngilizce ad eşleme tablosu |
| **Her ekranın kendi bağlantısını açması** sunucunun eşzamanlı bağlantı limitine takılır | Hesap başına tek kalıcı bağlantı + 4 dakikada bir NOOP + üstel geri çekilmeyle yeniden bağlanma |
| **Eylemin sunucuya geç gitmesi** — başka cihazdan bakan kullanıcı eski durumu görür | Kuyruk her eylemden sonra anında tetiklenir; ağ yoksa bağlantı gelince |
| **Türkçe büyük/küçük harf** — `'ISI'.toLowerCase()` yanlış sonuç verir | Tüm metin işlemleri `trLower`/`trUpper`/`foldForSearch` üzerinden geçer |
| **Yanıtta `References` zincirinin kopması** — alıcının istemcisi konuşmayı böler | Yanıt ve tümünü-yanıtla `In-Reply-To` + `References` başlıklarını doğru kurar |
| **Okundu işaretinin anında konması** — yanlış iletiye dokunup çıkan kullanıcı onu okumuş sayılır | 1,5 saniyelik gecikme |
| **Uzak görseller** gönderene iletinin okunduğunu bildirir | Varsayılan olarak engellenir, kullanıcı isterse gösterir |

---

## Doğrulama

```bash
flutter analyze   # 0 uyarı
flutter test      # 136 test
```

| Katman | Kapsam |
|---|---|
| Veritabanı (17) | Şema, kısmi tekil indeks, cascade silme, FTS5 araması, Türkçe katlama, UIDVALIDITY temizliği, kuyruk, gövde budama |
| Türkçe metin (20) | Harf dönüşümü, arama katlaması, konu ön eki temizleme (Re/Fwd/Yanıt/İlt), adres→ad |
| Konuşma gruplama (12) | Referans zinciri, çok seviyeli yanıt, başlıksız iletiler, boş konu ayrımı |
| Klasör eşleme (14) | İngilizce + Türkçe klasör adları, sunucu bayrağı önceliği, sıralama, silme davranışı |
| Metin/model (36) | HTML→düz metin, önizleme, adres ayrıştırma, References zinciri, tarih biçimleri, avatar dağılımı |
| **Uçtan uca arayüz (37)** | Giriş, liste, seçim modu, arama, okuma, yazma, gönderme, taslak, klasör gezinme, ayarlar, eşitleme, kalıcı silme koruması |

Uçtan uca testlerde **gerçek veritabanı, gerçek repository'ler ve gerçek
eşitleme motoru** çalışır; yalnızca IMAP/SMTP ağ katmanı taklit edilir. Böylece
"sildiğimde sunucuya `MOVE` gidiyor mu, `EXPUNGE` gitmiyor mu" gibi davranışlar
gerçekten doğrulanır.

---

## Doğrulanmamış kalanlar

Bunlar dürüstçe listelenmiştir; kod yazıldı ama aşağıdaki nedenlerle
çalıştırılarak sınanamadı:

1. **Gerçek sunucuya bağlantı.** Hesap şifresi elimde olmadığı için
   `mail.pazarlik.com.tr` sunucusuna karşı hiçbir gerçek oturum açılmadı.
   IMAP/SMTP kodu `enough_mail` API'si kaynak koddan okunarak yazıldı ve
   sahte bir sunucuya karşı test edildi, ancak gerçek sunucunun tuhaflıkları
   (sunucuya özgü klasör adları, standart dışı yanıtlar) ilk gerçek girişte
   ortaya çıkabilir.
2. **Cihazda çalıştırma.** Bağlı Android cihaz veya emülatör olmadığı için
   uygulama ekranda görülmedi. Release APK derleniyor ve 37 uçtan uca widget
   testi geçiyor; ancak dokunma hissi, kaydırma akıcılığı ve bildirimlerin
   gerçek davranışı cihazda gözlenmelidir.
3. **Sesli yazma ve ek dosya seçme** cihaz yetenekleri gerektirir; kod yolu
   yazıldı, gerçek mikrofon/dosya seçiciyle sınanmadı.
4. **Arka plan senkronizasyonu** ancak gerçek cihazda, uygulama arka plandayken
   doğrulanabilir.

### İlk gerçek çalıştırmada bakılacaklar

```bash
flutter run   # bağlı cihaz veya emülatörle
```

- [ ] Giriş: doğru şifreyle bağlanıyor mu, yanlış şifrede net hata veriyor mu
- [ ] Klasörler doğru Türkçe adlarla ve doğru sırayla geliyor mu
- [ ] İlk 50 ileti ne kadar sürede düşüyor
- [ ] Türkçe konu başlıkları düzgün çözülüyor mu (RFC 2047 kodlaması)
- [ ] Bir iletiyi sil → webmail'de Çöp Kutusu'na taşındı mı
- [ ] Sabitle → webmail'de yıldızlı göründü mü
- [ ] Kendine mail gönder → hem ulaştı hem Gönderilenler'de göründü mü
- [ ] Uygulamayı kapat, dışarıdan mail gönder → bildirim geldi mi

---

## Bilinen uyarı: Kotlin Gradle Plugin (KGP)

Derleme sırasında şu uyarı çıkar (hata değil, derleme başarılı olur):

```
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): workmanager_android
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
```

Flutter, Android derlemesinde Kotlin desteğini kendi içine alıyor. Eskiden her
eklenti KGP'yi kendisi uyguluyordu; yakında bunu Flutter yapacak ve iki taraf
çakışacak. Bu projedeki kodla ilgili değildir; çözüm eklenti yazarındadır.

Durum: `flutter_timezone` (kullanılmıyordu, kaldırıldı) ve `speech_to_text`
(7.5.0'a yükseltildi, düzeltilmiş) listeden çıktı. Geriye yalnızca
`workmanager_android` kaldı; en güncel sürümü (0.10.10) kullanılıyor ve henüz
düzeltilmiş bir sürümü yok.

Flutter bu uyarıyı hataya çevirdiğinde yapılacaklar, kolaydan zora:
1. `workmanager` paketinin güncel sürümünü bekle (muhtemel ve en ucuzu).
2. Flutter sürümünü geçici olarak sabitle.
3. Arka plan senkronizasyonunu başka bir yöntemle kur (ör. `android_alarm_manager_plus`
   veya doğrudan platform kanalı).

Bu üçü de yalnızca arka plan senkronizasyonunu etkiler; uygulamanın geri kalanı
bağımsızdır.

---

## Ortam notu

`flutter doctor` şu uyarıyı veriyor:

```
[!] Android toolchain — cmdline-tools component is missing
```

Derleme çalışıyor, ancak SDK lisansı kabulü gereken işlemler için Android
Studio üzerinden **Android SDK Command-line Tools** kurulmalıdır.

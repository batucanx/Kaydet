# Kaydet push backend

iOS'ta arka planda soket açık tutmanın bir yolu yok, Android'de ise üreticilerin pil
yönetimi kalıcı bağlantıyı öldürüyor; bu yüzden "anlık" mail bildirimi bir sunucu gerektirir:
bu servis her hesabın IMAP INBOX'ını IDLE ile dinler, yeni (okunmamış) ileti gördüğünde
iOS cihazlara Apple'a (APNs), Android cihazlara Google'a (FCM) doğrudan push gönderir.

- **iOS:** görünür bildirim APNs ile gelir (gönderen + konu yükte).
- **Android:** yalnızca-veri, yüksek öncelikli FCM mesajı gelir ve YALNIZCA "yeni ileti var"
  bilgisini taşır (gönderen/konu Google'dan geçmez). Uygulama uyanıp iletiyi IMAP'ten kendisi
  çeker ve yerel bildirimi üretir (eylem düğmeleri, gruplama). FCM bu cihazda kullanılamıyorsa
  (Play hizmetleri yok, sunucuda FCM kapalı) uygulama `lib/app/push_service.dart` ön plan
  servisine düşer.

## Kurulum

1. **Apple Developer Portal** → Certificates, Identifiers & Profiles → Keys → yeni bir **APNs
   Auth Key** oluştur (.p8 indirilir, yalnızca BİR KEZ indirilebilir). Key ID'yi not al.
2. Portal'da uygulamanın App ID'sinde **Push Notifications** özelliğini aç, ardından Xcode'da
   provisioning profilini yeniden indir/oluştur (özellik sonradan açıldıysa eski profil push'u
   sessizce reddeder).
3. `cp .env.example .env` ve doldur:
   - `API_KEY`: `openssl rand -hex 32` — uygulamanın bu sunucuya kimlik doğrularken kullandığı
     paylaşılan anahtar (APNs anahtarı DEĞİL).
   - `ENCRYPTION_KEY`: `openssl rand -hex 32` — IMAP şifrelerini AES-256-GCM ile şifreler.
   - `APNS_KEY_PATH`/`APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_BUNDLE_ID`: adım 1'den.
4. `.p8` dosyasını `APNS_KEY_PATH`'in gösterdiği yere koy (repo'ya asla eklenmez, `.gitignore`
   zaten `*.p8`'i kapsıyor).
5. `npm install && npm run build && npm start`.

Başlangıçta anahtar bir JWT imzalayarak doğrulanır; "APNs anahtarı yüklenemedi/imzalanamadı"
hatasıyla çıkarsa `.p8` dosyası/Key ID/Team ID yanlış demektir — bu, gerçek bir push denemesini
beklemeden hemen görülür.

## Android push (Firebase Cloud Messaging) kurulumu

Yalnızca Android bildirimi için gerekir; iOS bundan bağımsız çalışır.

1. [Firebase Console](https://console.firebase.google.com) → proje oluştur (Analytics gerekmez).
2. Projeye bir **Android uygulaması** ekle, paket adı: `tr.com.kaydetmail`.
   İndirilen `google-services.json` dosyasını `android/app/` altına koy (dosya yoksa
   derleme yine geçer, ama FCM kapalı kalır ve uygulama ön plan servisine düşer).
3. Proje ayarları → **Hizmet hesapları** → "Yeni özel anahtar oluştur" ile JSON'u indir.
   İçeriğini ham ya da base64 olarak `FCM_SERVICE_ACCOUNT` ortam değişkenine ver
   (Railway'de Variables; dosya yolu için `FCM_SERVICE_ACCOUNT_PATH`). Bu JSON gizlidir,
   repoya eklenmez. Anahtar sızarsa Firebase'den iptal edip yenisini üret.
4. Başlangıçta anahtar doğrulanır (`FCM anahtarı doğrulandı (proje: ...)`). Yanlışsa sunucu
   açılmaz; ayarlanmamışsa uyarı verir ve Android kayıtları `503 android_push_unavailable`
   alır (iOS etkilenmez).
5. Doğrulama: fiziksel Android cihazda uygulamayı kur, hesabı ekle, uygulamayı son
   kullanılanlardan **kaydırma** (ayarlardan "Zorla durdur" YAPMA — Android zorla durdurulan
   uygulamaya hiçbir push iletmez), başka bir adresten mail gönder; bildirim birkaç saniyede
   düşmeli.

**Bilinen sınırlar (Android'in kendi kuralları):** zorla durdurulan uygulama push almaz;
uygulamayı günlerce açmayıp bildirimlerle hiç etkileşmeyen kullanıcılarda Android "bekleme
kovası" yüzünden yüksek öncelikli mesajlar geciktirilebilir; Xiaomi/Huawei gibi
üreticiler "otomatik başlat" izni verilmemiş uygulamaların FCM'ini engeller. Hiçbiri bu
kodla aşılamaz; yedek olarak periyodik WorkManager görevi (15 dk) çalışır.

## Kalıcı depolama (yayın öncesi zorunlu)

Abonelikler ve şifreli IMAP parolaları `DATABASE_PATH` içindeki SQLite dosyasında durur.
Konteynerin kendi dosya sistemi her deploy/yeniden başlatmada sıfırlanır; **bir Volume bağlamazsan
tüm abonelikler silinir** ve kullanıcılar uygulamayı açana kadar push alamaz.

1. Hosting'de (ör. Railway) servise bir **Volume** ekle, bağlama yolu: `/app/data`.
2. `DATABASE_PATH=/app/data/kaydet.sqlite` olarak ayarla (varsayılan `./data/kaydet.sqlite`,
   Docker'da `/app/data/kaydet.sqlite`'e denk gelir; yine de açıkça yaz).
3. Dosya açılamazsa sunucu **hata verip kapanır** (bellekte sahte bir veritabanına düşmez);
   açılışta "Veritabanı açılamadı" görürsen yol/izin/Volume ayarını kontrol et.
4. Doğrulama: bir hesap kaydet, servisi yeniden deploy et, hesabın hâlâ listelendiğini
   (`GET /v1/accounts?pushToken=...&platform=ios`) gör.
5. Volume'un anlık görüntüsünü (snapshot) aç ve `ENCRYPTION_KEY`'i veritabanından ayrı sakla;
   anahtar kaybolursa yedekteki parolalar çözülemez.

### Otomatik yedek

Sunucu açılışta ve sonra her `BACKUP_INTERVAL_HOURS` (24) saatte bir `VACUUM INTO` ile tutarlı bir
kopya alır (`kaydet-YYYYMMDD-HHMMSS.sqlite`, UTC), en yeni `BACKUP_KEEP` (7) tanesini tutar.
Varsayılan klasör veritabanının yanındaki `backups/`'tır (`BACKUP_DIR` ile değişir,
`BACKUP_ENABLED=false` kapatır). Yedek alınamazsa sunucu çalışmaya devam eder, logda
`YEDEK ALINAMADI` görünür; bu satırı uyarıya bağla.

Önemli sınır: yedek **aynı Volume'da** olduğundan bozulmaya ve yanlış silmeye karşı korur, Volume'un
kendisini kaybetmeye karşı korumaz. Bunun için Volume snapshot'ı ya da yedek klasörünü düzenli
olarak dışarı (S3 vb.) kopyalamak gerekir. Yedeğin içindeki parolalar `ENCRYPTION_KEY` ile
şifreli kalır.

**Geri yükleme:** servisi durdur, seçtiğin yedeği `DATABASE_PATH`'e kopyala (varsa yanındaki
`-wal` ve `-shm` dosyalarını sil), servisi başlat. Bunu yayından önce bir kez gerçekten dene.

## Kurulum doğrulaması (paylaşılan API anahtarına ek katman)

`API_KEY` uygulamanın içine derlenir ve çıkarılabilir. Bu yüzden `/health` dışındaki her istek
ayrıca kuruluma özel `X-Install-Id` + `X-Install-Secret` başlıklarını taşır (uygulama ilk
açılışta rastgele üretir, Keychain/Keystore'da saklar).

- Sunucu ilk görüşte `sha256(secret)` saklar (düz sır yok), sonra sabit zamanlı karşılaştırır.
- Çeviri kotası artık istemcinin gönderdiği `userId`'ye değil, doğrulanmış kurulum kimliğine
  bağlıdır; `userId` değiştirerek kota aşılamaz.
- Yeni kurulum kaydı IP başına saatte `INSTALLS_PER_IP_HOUR` (30) ile, kurulum başına hesap
  sayısı `MAX_ACCOUNTS_PER_INSTALL` (25) ile sınırlıdır (IDLE bağlantı kaynağını korur).
- Ters vekil (Railway) arkasında `TRUST_PROXY=true` kalmalı; yoksa IP limiti herkesi tek IP sayar.
- Hatalar: `401 install_required` (başlık yok/biçimsiz), `401 install_invalid` (yanlış sır),
  `429 install_rate_limited`, `429 install_account_limit`.

**Sınır:** Bu, kötü niyetli bir betiği tamamen durdurmaz; yeni kimlik üretmek ucuzdur, yalnızca
IP başına yavaşlatılır. Gerçek cihaz kanıtı için iOS'ta App Attest, Android'de Play Integrity
gerekir (ayrı iş). **Dağıtım sırası:** eski uygulama sürümleri başlıkları göndermediği için bu
sunucu sürümüyle `401` alır; sunucuyu, yeni istemci kullanıcılara ulaştıktan sonra yayına alın.

## Uygulamaya bağlama

Sunucu **gerçek bir `https://` adresinden** telefonun erişebileceği bir yerde çalışmalı
(loopback yalnızca `flutter run` ile aynı makinede geliştirme için istemci tarafında serbest
bırakılmıştır). URL'yi ve `API_KEY`'i `lib/app/push_backend_config.dart` dosyasına yaz (bkz. o
dosyanın yanındaki `.example` şablonu) — bu dosya git'e eklenmez, her build'de (Xcode "Run",
`flutter run`, `flutter build ipa`) otomatik olarak derlemeye girer.

## Mail çevirisi (Azure AI Translator, F0)

Akış: Flutter → bu sunucu (`POST /v1/translate`, `POST /v1/translate/detect`) → Azure
Translator (Text Translation REST v3.0). Azure anahtarı yalnızca sunucu ortamında durur
(`AZURE_TRANSLATOR_KEY`, `.env` git'e eklenmez); URL'ye değil `Ocp-Apim-Subscription-Key` başlığına
konur. Sunucu, istemciden yalnızca çevrilebilir düz metin parçalarını (HTML etiketi yok) ve konuyu
alır. Mail açılınca istemci önce kısa bir örnekle **dil algılama** ister (`/v1/translate/detect`,
en çok 400 karakter, aynı limitlerden geçer ve karakter harcar; sonuç istemcide önbelleklenir);
kaynak dil Türkçe ise çeviri arayüzü gösterilmez. Çeviri için sırayla:

1. **Önbellek** (`translated_email_cache`, anahtar: kullanıcı + ileti + kaynak dil + hedef dil;
   içerik değişmişse kullanılmaz) — varsa Azure'a ve limit kontrollerine hiç gidilmez.
2. Karakter hesabı (konu + metin; boş ve tekrarlanan parçalar sayılmaz/gönderilmez).
3. Genel **ve** kullanıcı limiti — `kullanım + istek > limit` ise Azure çağrılmaz, `429` +
   `TRANSLATION_MONTHLY_LIMIT_REACHED` / `TRANSLATION_USER_LIMIT_REACHED`.
4. **Atomik ayırma** (SQLite `IMMEDIATE` işlemi; `translation_usage`, `user_translation_usage`
   aylık satırlar, `reserved`/`consumed` ayrımı). Kullanım = harcanan + ayrılan olduğundan
   eşzamanlı istekler toplamı aşamaz.
5. Azure (istek başına en çok 500 öğe / 40.000 karakter; Azure sınırı 1000 / 50.000), sonuç
   önbelleğe yazılır.

Azure hata verirse (400/401/403/429/5xx): istek kesin işlenmedi sayılır, ayrılan kota iade edilir
ve istemciye `503 TRANSLATION_UNAVAILABLE` döner. Belirsizse (zaman aşımı, bağlantı kopması)
karakterler harcanmış sayılır. Sunucu yanıt beklerken kapanırsa açılışta ayrılmış karakterler
harcanmış sayılır. Aylık kayıtlar (`2026-09`) silinmez; ay değişince sayaç kendiliğinden sıfırdan
başlar (UTC takvim ayı).

Ortam değişkenleri (bkz. `.env.example`): `AZURE_TRANSLATOR_ENABLED`,
`AZURE_TRANSLATOR_ENDPOINT`, `AZURE_TRANSLATOR_KEY`, `AZURE_TRANSLATOR_REGION`,
`AZURE_TRANSLATOR_MONTHLY_LIMIT` (1800000), `AZURE_TRANSLATOR_WARNING_LIMIT` (1600000),
`AZURE_TRANSLATOR_USER_MONTHLY_LIMIT` (200000), `AZURE_TRANSLATOR_MAX_REQUEST_CHARS` (100000).
Geliştirmede `AZURE_TRANSLATOR_MONTHLY_LIMIT=10000` gibi küçük bir değerle denenebilir.

Loglar yalnızca dil, karakter sayısı, önbellek isabeti ve süreyi içerir; mail içeriği ve anahtar
loglanmaz. Sunucu önbelleği çevrilmiş mail metnini SQLite'ta (şifresiz) saklar ve 90 günden eskisini
açılışta siler.

### Elle yapılması GEREKEN: Azure Portal

1. portal.azure.com → **Create a resource → "Translator"** (Azure AI services). Fiyatlandırma
   katmanı: **Free F0** (aylık 2.000.000 karakter; abonelik başına bir F0 kaynağı sınırı vardır).
2. Kaynak oluşunca **Keys and Endpoint**: `KEY 1` → `AZURE_TRANSLATOR_KEY`; **Location/Region**
   → `AZURE_TRANSLATOR_REGION` (ör. `westeurope`); metin çeviri uç noktası genelde
   `https://api.cognitive.microsofttranslator.com` (varsayılan). Özel alan adlı kaynak
   kullanıyorsan `https://<ad>.cognitiveservices.azure.com` yaz (yol otomatik ayarlanır).
3. Değerleri sunucunun secret deposuna (Railway variables vb.) gir; `backend/.env` git'e eklenmez
   (`.gitignore` kapsıyor). Anahtar sızarsa portaldan `KEY 2`'ye geç ve `KEY 1`'i yeniden üret.
4. **Harcama koruması:** F0 katmanında kota bitince Azure isteği reddeder, ücret kesmez. Yine de
   **Cost Management → Budgets** ile düşük bir bütçe ve e-posta uyarısı eklemek iyi olur; F0'dan
   ücretli S1'e yalnızca sen elle geçersin (kod bunu yapmaz). Bu yüzden ücretli katmana
   geçmeden önce `AZURE_TRANSLATOR_*_LIMIT` değerlerini ve bütçeyi gözden geçir.
5. Sunucuyu yeniden başlat; `AZURE_TRANSLATOR_KEY` boşsa çeviri "kullanılamıyor" döner.

## Çok hesaplı bildirim modeli (hesap başına bağımsız izleme)

Bildirim **etkin hesaba bağlı değildir**. Cihazdaki her hesap sunucuda kendi satırıdır
(`accounts`: `device_id` + `client_account_id`, UNIQUE) ve kendi IDLE izleyicisine sahiptir. Bir
hesabı kaydetmek/silmek/yeniden kaydetmek yalnızca o satıra dokunur. Push her hesap için
AYRI gönderilir ve yükte o hesabın `accountId`'si bulunur (iOS: `thread-id` hesap başınadır;
Android: uygulama yalnızca o hesabı eşitler).

**İzleme asla "sessizce" düşmez:**

- Kimlik hatası (`AUTHENTICATIONFAILED`) izleyiciyi **öldürmez**: 5 → 15 → 30 → 60 dk aralıkla
  (hesap kilitlenmesin diye seyrek) yeniden denenir. Eskiden izleyici bir kez reddedilince sunucu
  yeniden başlayana dek hesap bildirimsiz kalıyordu.
- `GET /v1/accounts` her hesabın **gerçek** durumunu döner: `watching`, `connecting`,
  `auth_failed`, `unreachable`, `stopped` (`clientAccountIds` eski istemciler için durur).
  "Kayıtlı" olmak "izleniyor" demek değildir; istemci `auth_failed`/`stopped` hesabı en çok her
  10 dk'da bir taze şifreyle yeniden kaydeder, düzelmezse (Android) cihazdan IDLE yapan ön plan
  servisi devreye girer ve Ayarlar > Bildirimler hangi hesabın etkilendiğini gösterir.
- Push iletilemezse (ağ, APNs/FCM kesintisi) ileti imleci (`last_uid`) **ilerletilmez**; 30 sn →
  2 dk → 5 dk → 15 dk aralıkla yeniden taranır. Kalıcı reddedilen (geçersiz token) push'ta imleç
  ilerler.
- Bir hesabın taraması (yeni ileti → push) hesap başına tek koşar: istemci hesabı yeniden
  kaydedip izleyici yenilenirken eski ve yeni izleyici aynı iletiyi iki kez bildirmez.
- Token yenilenince (FCM `onNewToken`, APNs) aynı kurulumun eski cihaz satırı silinmez, hesapları
  yeni token'a **taşınır**: çalışan izleyici ve son görülen UID korunur (geçiş anında gelen ileti
  atlanmaz, aynı posta kutusu iki kez izlenmez).
- Android FCM mesajlarında `collapse_key` **yoktur**. FCM, çevrimdışı/Doze'daki cihaz için aynı
  anda en çok 4 farklı collapse key saklar; hesap başına anahtar 5 hesapta bildirim kaybettirirdi.
  Saklama süresi (TTL) 24 saattir. Cihazın bekleyen mesajları silinirse uygulama
  `onDeletedMessages` ile tüm hesapları tarar.

Sunucu günlüğünde hesap başına durum satırları görünür: `hesap N: INBOX açık, IDLE bekleniyor`
(sağlıklı), `kimlik doğrulama başarısız ... dk sonra yeniden denenecek` (kimlik reddedildi),
`push iletilemedi, ... yeniden denenecek` (sağlayıcı kesintisi).

## Sorun giderme

- `/health` her zaman 200 döner, kimlik doğrulaması istemez — sunucunun ayakta olup olmadığını
  hızlıca kontrol etmek için.
- Konsol günlüğü her push denemesi için `sent` / `invalid_token` (token silinir) / `error` +
  neden yazar; token, IMAP şifresi ya da ileti içeriği ASLA loglanmaz.
- `BadDeviceToken`: token'ın ait olduğu ortam (`development`/`production`) yanlış — Debug
  derlemeleri sandbox, Release/TestFlight/ad-hoc production token üretir.
- Push hiç ulaşmıyorsa: fiziksel cihazda mı test ediliyor (simülatör gerçek push almaz), kurumsal
  Wi-Fi Apple'ın push sunucularına giden bağlantıyı engelliyor olabilir mi (hücresel/kişisel
  hotspot ile bir kez dene).
- `npm run smoke`: gerçek bir IMAP hesabını dinler, APNs'e İSTEK ATMADAN gönderilecek bildirimi
  konsola yazar — IMAP/watcher tarafını APNs'ten bağımsız doğrulamak için.

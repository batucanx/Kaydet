# Kaydet push backend

iOS'ta arka planda soket açık tutmanın bir yolu yok, bu yüzden "anlık" mail bildirimi bir
sunucu gerektirir: bu servis her hesabın IMAP INBOX'ını IDLE ile dinler, yeni (okunmamış)
ileti gördüğünde Apple'a (APNs) doğrudan push gönderir. Android bunu gerektirmez — Android
tarafı `lib/app/push_service.dart` üzerinden cihazda kalıcı bir ön plan servisiyle aynı işi
sunucusuz yapar.

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

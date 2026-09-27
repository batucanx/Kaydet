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

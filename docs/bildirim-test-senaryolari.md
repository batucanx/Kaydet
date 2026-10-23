# Çok hesaplı bildirim — gerçek cihaz test senaryoları

Amaç: cihazdaki **tüm** hesapların (en çok 5, sunucu sınırı 25) yeni iletisi, uygulama
hangi durumda olursa olsun, eksiksiz ve **bir kez** bildirilir. Bildirim "aktif hesap"a bağlı
değildir.

Her senaryoda 5 hesap ekli olsun (A–E; A etkin hesap). Test iletisi her seferinde **dış bir
adresten** gönderilir (kendi kendine göndermek bazı sağlayıcılarda hemen okunmuş görünür).
Bir senaryo "geçti" sayılması için tablodaki beklenen sonuç, **her hesap için ayrı** gözlenmelidir.

## Hazırlık

1. Sunucu: `backend` yayında, `FCM_SERVICE_ACCOUNT` (Android) ve APNs anahtarı (iOS) tanımlı.
   Günlükte her hesap için `izleme başlatıldı` ve `INBOX açık, IDLE bekleniyor` satırlarını gör.
2. Uygulama: Ayarlar > Bildirimler: bildirimler açık, kontrol sıklığı **Anlık** (Android). Sistem
   ayarlarından Kaydet bildirimleri açık.
3. Android: **gerçek cihaz** (Google Play hizmetli). iOS: **gerçek cihaz** (simülatör push almaz).
   iOS Debug derlemesi sandbox, TestFlight/Release production token üretir
   (`PUSH_APNS_ENV` bkz. `lib/app/remote_push_controller.dart`).
4. Sunucu durumunu doğrula (kurulum kimliği başlıkları uygulamadan alınır; geliştirme için günlük
   yeterlidir):

   ```bash
   curl -s -H "Authorization: Bearer $API_KEY" -H "X-Install-Id: $INSTALL_ID" \
        -H "X-Install-Secret: $INSTALL_SECRET" \
        "https://<sunucu>/v1/accounts?pushToken=<token>&platform=android"
   ```

   Beklenen: beş hesabın hepsi `"status": "watching"`.

## Senaryolar (hepsi her platformda, her hesap için)

| # | Durum | Nasıl getirilir | Beklenen |
|---|-------|-----------------|----------|
| 1 | Uygulama açık, A etkin | A listesi ekranda | A: liste anında güncellenir + bildirim. B–E: bildirim (hesap e-postası bildirimde yazar) |
| 2 | Uygulama açık, **Tüm Hesaplar** görünümü | Birleşik Gelen Kutusu | Beş hesabın da iletisi bildirilir (**eski hata: yalnızca A**) |
| 3 | Arka planda (Home) | Home tuşu | Beş hesap bildirir; çift bildirim yok |
| 4 | Son kullanılanlardan **kaydırılmış** | Görev listesinden kaydır. Android: `adb shell am kill tr.com.pazarlik.kaydet` | Beş hesap bildirir (Android: FCM → `FcmSyncWorker`; iOS: APNs görünür bildirim) |
| 5 | Ekran kilitli / cihaz kilitli | Ekranı kapat | Beş hesap bildirir; Android'de şifre okunabilmeli (iOS: Keychain `first_unlock`) |
| 6 | Cihaz **yeniden başlatıldı**, uygulama açılmadı | `adb reboot` / cihazı yeniden başlat; ilk kilit açılışından sonra bekle | Yeniden başlatma sırasında gelen iletiler dâhil beş hesap bildirir (FCM TTL 24 sa; ayrıca 15 dk'lık periyodik görev) |
| 7 | Android **Doze** | `adb shell dumpsys deviceidle force-idle` sonra mail gönder | Yüksek öncelikli FCM Doze'u delip bildirir (birkaç sn). Sonunda `dumpsys deviceidle unforce` |
| 8 | Android **Uygulama bekleme kovası** | `adb shell am set-standby-bucket tr.com.pazarlik.kaydet rare` | Bildirim gelir; gecikirse bkz. "Bilinen sınırlar" |
| 9 | Uçak modu → kapat | Uçak modunda 5 hesaba mail gönder, sonra kapat | Ağ gelince beş hesabın hepsi bildirir (FCM'de 4'ten fazla `collapse_key` sorunu bulunmamalı) |
| 10 | Ağ değişimi | Wi‑Fi ↔ mobil veri | Sonraki mailler bildirir; izleyici kopmaz (sunucu tarafı ağdan bağımsızdır) |
| 11 | **Aynı anda 5 mail** | Beş hesaba ardışık hızlı mail | Beş bildirim, her biri kendi hesabında; hiçbiri düşmez; çift bildirim yok |
| 12 | Bir hesaptan **çıkış** | C'den çıkış yap | Yalnızca C'nin kaydı silinir (`GET /v1/accounts` 4 hesap); A, B, D, E bildirmeye devam eder |
| 13 | Etkin hesabı değiştir | A → D etkin | Beş hesap yine bildirir; bildirime dokunmak ilgili hesabı açar |
| 14 | **Şifre değişti** (sağlayıcıda) | E'nin şifresini web'den değiştir | Sunucu E'yi `auth_failed` raporlar; Ayarlar > Bildirimler E'yi uyarıyla gösterir (Android: yedek servis çalışır); uygulamada şifreyi güncelleyince ≤ 10 dk içinde `watching` olur. A–D etkilenmez |
| 15 | **Sunucu yeniden başlatıldı** | Railway'de yeniden deploy | Birkaç dk içinde beş hesap yeniden `watching`; aradaki iletiler özet bildirimle gelir (imleç korunur) |
| 16 | **Token yenilendi** | Android: Ayarlar > Uygulamalar > Google Play hizmetleri > Depolama > Verileri temizle (FCM `onNewToken` tetiklenir; `force-stop` YAPMA). iOS: uygulamayı silip yeniden yükle (yeni APNs token) | Beş hesap yeni token'a taşınır, bildirim sürer; eski token satırı sunucuda kalmaz (`SELECT push_token FROM devices` tek satır) |
| 17 | Bildirim izni kapalı → açık | Sistem ayarlarından kapat/aç | Açıldıktan sonra beş hesap bildirir; kapalıyken ayarlarda uyarı görünür |
| 18 | Okunmuş ileti | Maili başka cihazdan oku | Bildirim gölgeden kalkar (uygulama açılınca/eşitlemede); yeniden bildirilmez |
| 19 | Tek tek ileti vs özet | Bir hesaba 8 mail | En çok 5 ayrı bildirim + özet; diğer hesapların bildirimleri etkilenmez |

## Sunucu tarafı doğrulama (cihaz gerekmeden)

```bash
cd backend && npx vitest run
```

Çok hesaplı davranışı kapsayan testler: `test/watcher.test.ts` (kimlik hatasında izleme
sürer, hesaplar bağımsız, push iletilemezse imleç ilerlemez), `test/api.test.ts` (hesap başına
durum, token yenilemede taşıma, hesap silme izolasyonu), `test/notifier.test.ts` (5 hesap, FCM
collapse key yok).

İstemci tarafı: `flutter test test/multi_account_notification_test.dart
test/remote_push_sync_test.dart test/remote_push_controller_test.dart
test/push_backend_client_test.dart`.

## Hata ayıklama

- Android: `adb logcat -s KaydetFcm KaydetFcmSync FirebaseMessaging`. `Tanınmayan FCM mesajı`
  yükte `type` eksik demektir; `FCM bekleyen mesajları sildi` FCM'in düşürdüğü push'ları tüm
  hesap taramasıyla telafi ettiğini gösterir.
- iOS: Console.app'te `APNs device token received` / `Push background sync finished`.
  `BadDeviceToken`: token ortamı (sandbox/production) uyuşmuyor.
- Sunucu: `hesap N: ...` satırları. `auth_failed` kalıcıysa sağlayıcı sunucunun IP'sini
  engelliyor olabilir (uygulama telefondan bağlanabilirken sunucudan bağlanamaz): Android'de yedek
  ön plan servisi bu hesabı cihazdan izler; iOS'ta başka çare yoktur (bkz. Bilinen sınırlar).

## Bilinen sınırlar (kodla aşılamaz)

- **Android "Zorla durdur":** zorla durdurulan uygulamaya hiçbir push iletilmez; kullanıcı
  uygulamayı bir kez açana kadar bildirim gelmez. Görev listesinden kaydırmak zorla durdurma
  değildir.
- **Android üretici katmanları** (Xiaomi, Huawei, Oppo…): "otomatik başlat" izni verilmemiş
  uygulamanın FCM'ini engeller. Pil optimizasyonundan hariç tutma ve üreticinin otomatik başlat
  ayarı gerekir.
- **Android bekleme kovası:** hiç açılmayan uygulamada yüksek öncelikli mesajlar gecikebilir.
- **iOS:** kullanıcı uygulamayı kaydırarak kapatırsa iOS arka plan çalıştırmayı durdurur;
  **görünür bildirim yine gelir** (sunucu APNs'e kendisi gönderir), yalnızca liste uygulama açılınca
  eşitlenir. Sağlayıcı sunucunun IP'sini engelliyorsa iOS'ta cihazdan izleme yedeği yoktur.
- **iOS Notification Service Extension** (`ios/NotificationService`) Xcode projesine HENÜZ
  eklenmemiş bir hedeftir; bildirim görünür ama "liste anında dolsun" özeti çalışmaz. Hedefi Xcode'dan
  ekleyin (bkz. dosya içi açıklamalar).

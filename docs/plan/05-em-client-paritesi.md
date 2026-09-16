# Bölüm 5 — eM Client Paritesi (v1.1 Yol Haritası)

## Karar (2026-09-15)

Kullanıcı isteği: KAYDET'in genel yapısı (özellik seti, davranış) eM Client mobile ile
aynı olsun; yalnızca tasarım kendi dili olarak kalsın.

Kapsam netleştirmesi (kullanıcı onayıyla, aynı gün):

| Konu | Karar |
|---|---|
| Gelen kutusu modeli | **Hesap değiştirici** — eM Client'ın birleşik gelen kutusu değil. Tek seferde bir hesap görünür, üstte hızlı geçiş var. |
| OAuth uygulama kaydı | Kullanıcı kendi Google Cloud / Microsoft Entra ID hesabıyla oluşturacak; Claude bunu yapamaz (hesap/kimlik oluşturma yasak). |
| Takvim + Kişiler + Notlar | Kapsama **alındı** (önceki "v2'ye bırakıldı" kararının üzerine yazıldı). |
| PGP/S-MIME, AI yardım + anlık çeviri, bulut depolama entegrasyonu | **Kapsam dışı.** MDM zaten sorulmadan kapsam dışı bırakıldı (kurumsal özellik, bu uygulamaya uygun değil). |

## Faz Tablosu

| Faz | İçerik | Durum |
|---|---|---|
| 1 | Çoklu hesap (hesap değiştirici) | ✅ Kodlandı (2026-09-15) |
| 2a | **Gmail** OAuth2 girişi | ✅ Kodlandı (2026-09-15) |
| 2b | **Outlook/MS365** — Graph API (IMAP/SMTP değil) | ⏸ Beklemede — kullanıcı kararı (2026-09-15): önce Gmail bitsin. Ayrıca bkz. "Outlook kararı düzeltmesi" altında. |
| 3 | Takvim + Kişiler + Notlar (CalDAV/CardDAV) | 🕒 Bekliyor — kendi ayrı bölüm planı gerekir, Faz 1-2'den sonra |
| 4 | Üretkenlik eşleniği (snooze, gönderiyi geri al, hızlı metin/şablon, izleme pikseli algılama, uygulama kilidi) | 🕒 Bekliyor — küçük ve bağımsız parçalar, paralel alınabilir |
| — | PGP/S-MIME, AI yardım + çeviri, bulut depolama entegrasyonu, MDM | ❌ Kapsam dışı (kullanıcı kararı) |

### Outlook kararı düzeltmesi (2026-09-15)

İlk planda Outlook için de IMAP/SMTP + OAuth (`IMAP.AccessAsUser.All`, `SMTP.Send`)
öngörülmüştü — kullanıcı Azure Portal'da bu izinleri eklemeye çalışırken "Applications
that sign in personal Microsoft accounts don't support permissions that require admin
consent" hatasına takıldı. Araştırma sonucu (Microsoft MVP yanıtı, learn.microsoft.com):
bu kapsamlar artık **kullanımdan kaldırılıyor** (yalnızca EWS/PowerShell için kalmış) ve
kişisel/lisanssız tenant'larda zaten görünmüyor. Microsoft'un güncel yolu **Graph API**
(`Mail.Read`, `Mail.Send`) — bu, mevcut IMAP/SMTP mimarimize eklenebilecek bir OAuth
detayı değil, Outlook hesapları için **ayrı bir mail servisi** (REST tabanlı, enough_mail
devre dışı) demek. Bu yüzden Outlook, Faz 2b olarak ayrıldı ve kendi planı yazılana kadar
beklemede.

## Faz 1 — Çoklu Hesap (tamamlandı)

**Mimari:** `Accounts` tablosu zaten çoklu hesaba hazırdı (bkz. `01-mimari-ve-veri-modeli.md`);
eksik olan tekillik garantisi ve arayüzdü.

- `AppDatabase.deactivateAllAccounts()` — her hesap geçişi/eklemesi öncesi tüm hesapları
  pasifleştirir. Öncesinde `isActive=true` iki satırda aynı anda kalabiliyordu (hangi
  hesabın gösterileceği belirsizdi) — bu, gerçek bir kusurdu, sadece eksik özellik değil.
- `AccountRepository.switchAccount(accountId)` — hesaplar arası geçiş, önceki hesabın
  IMAP bağlantısını kapatır.
- `AccountRepository.signOut(accountId)` — artık hedef hesabın **etkin olup olmadığını**
  ayırt eder: etkin değilse paylaşılan IMAP bağlantısına dokunmaz (aksi hâlde alakasız
  bir hesabı silmek etkin hesabın canlı oturumunu keserdi). Etkin hesap silinirse ve
  başka hesap kaldıysa, kalan en eski hesap otomatik etkinleşir — uygulama Giriş
  ekranına düşmez.
- `AccountRepository.watchAllAccounts()` / `providers.dart#allAccountsProvider` — hesap
  değiştirici listesi.
- UI:
  - `SettingsScreen` — "HESAPLAR" bölümü: liste (geçiş + kaldırma), "Hesap ekle" düğmesi.
  - `AppShell` — yan menü başlığına dokununca hızlı hesap değiştirici (bottom sheet).
  - `LoginScreen` — `isAddingAccount` modu: mevcut hesaba dokunmadan push edilir, başarılı
    girişte kendini kapatır.

**Değişen dosyalar:** `lib/data/database/app_database.dart`,
`lib/data/repositories/account_repository.dart`, `lib/app/providers.dart`,
`lib/ui/features/settings/settings_screen.dart`, `lib/ui/features/shell/app_shell.dart`,
`lib/ui/features/auth/login_screen.dart`, `test/app_flow_test.dart`.

## Faz 2a — Gmail OAuth2 (tamamlandı)

Gmail standart sunucu adresleriyle çalışır (`imap.gmail.com:993`, `smtp.gmail.com:465`),
tek fark kimlik doğrulama — kullanıcı tarayıcıya yönlendirilip OAuth onayı veriyor,
alınan access token `AUTHENTICATE XOAUTH2` ile IMAP/SMTP'de şifrenin yerini alıyor.
`enough_mail` 2.1.7 bunu protokol seviyesinde zaten destekliyor
(`authenticateWithOAuth2`, SMTP `AuthMechanism.xoauth2`).

**Alınan kimlikler (Google Cloud Console, proje "kaydet"):**

| Değer | Bilgi |
|---|---|
| OAuth Client ID (Android) | `856471546230-onihb0lsnk7qh1apqbcv7qt5no3m6dod.apps.googleusercontent.com` — gizli değil, client secret taşımaz |
| Paket adı | `tr.com.pazarlik.kaydet` |
| Debug SHA-1 | `43:DE:A2:51:19:75:44:53:9E:56:4F:32:CA:66:33:82:E1:8C:9B:BC` — yalnızca debug derlemesi; release keystore alınınca Google Cloud Console'a **ikinci bir Android istemcisi** olarak eklenmeli |

**Mimari:**

- `MailCredential` sealed sınıfı (`PasswordCredential` \| `OAuthCredential`) —
  `MailServerConfig.password` yerine `MailServerConfig.credential` (bkz.
  `domain/models/mail_models.dart`). `ImapService`/`SmtpService` credential türüne göre
  `LOGIN` veya `AUTHENTICATE XOAUTH2` gönderir.
- `SecureStore` genişledi: `readOAuthTokens`/`writeOAuthTokens`/`deleteOAuthTokens` —
  access+refresh token JSON olarak, şifrenin gittiği yere (Android Keystore) gider.
- `Accounts.authMethod` sütunu eklendi (`password` \| `googleOAuth`, şema v1→v2 migration
  ile). Hangi hesabın hangi kimlik doğrulamayı kullandığını ayırt eder.
- `GoogleOAuthService` (yeni, `data/services/google_oauth_service.dart`) —
  `flutter_appauth` ile tarayıcı OAuth akışı, `refresh()` ile sessiz token yenileme,
  Google userinfo uç noktasından e-posta adresi çekme.
- `MailConnection._credentialFor()` — bağlanmadan önce OAuth token süresi dolmuşsa
  otomatik yeniler; aksi hâlde sunucu genel bir kimlik hatası döner, kullanıcı gerçek
  sebebi göremezdi.
- `AccountRepository.signInWithGoogle()` — `signIn()` ile ortak kayıt adımını
  `_persistAccount()` yardımcı metodunda paylaşır (DRY).
- Android: `build.gradle.kts`'e `appAuthRedirectScheme` manifest placeholder'ı
  (istemci kimliğinin tersine çevrilmiş hâli) eklendi; `AndroidManifest.xml`'deki
  `android:taskAffinity=""` kaldırıldı (flutter_appauth'ın resmi sorun giderme notu —
  bu satır OAuth yönlendirmesinin uygulamaya geri dönmesini engelleyebiliyor).
- Giriş ekranına "Google ile devam et" düğmesi eklendi (mevcut IMAP formunun üstünde,
  ayraçla ayrılmış).

**Değişen/eklenen dosyalar:** `lib/domain/models/mail_models.dart`,
`lib/data/services/secure_store.dart`, `lib/data/services/google_oauth_service.dart`
(yeni), `lib/data/services/imap_service.dart`, `lib/data/services/smtp_service.dart`,
`lib/data/database/tables.dart`, `lib/data/database/app_database.dart`,
`lib/data/repositories/account_repository.dart`,
`lib/data/repositories/mail_connection.dart`, `lib/app/providers.dart`,
`lib/app/background_sync.dart`, `lib/ui/features/auth/login_screen.dart`,
`android/app/build.gradle.kts`, `android/app/src/main/AndroidManifest.xml`,
`pubspec.yaml` (`flutter_appauth: 12.1.0`, `http: ^1.6.0`).

**Kullanıcının yapması gereken (kod tarafında bekleyen bir şey yok):** Google Cloud
Console'da "Android" tipi istemciler için ayrı bir yönlendirme URI'si alanı yok —
Google, paket adı + SHA-1 eşleşmesine güveniyor, ekstra bir ayar gerekmiyor. Cihazda/
emülatörde `flutter run` ile "Google ile devam et"i test etmek yeterli.

## Faz 2b — Outlook/MS365 (Graph API) — bekliyor

Yukarıdaki "Outlook kararı düzeltmesi"ne bakın. Gerektiğinde ayrı bir bölüm planı
yazılacak: `Mail.Read`/`Mail.Send`/`Mail.ReadWrite` delegated Graph izinleri, REST
tabanlı yeni bir `OutlookMailService` (enough_mail'den bağımsız), Microsoft Entra ID
kaydının Graph izinleriyle güncellenmesi.

## Faz 3 — Takvim + Kişiler + Notlar — bekliyor

`00-yol-haritasi.md`'deki önceki not hâlâ geçerli: `table_calendar` + özel zaman
çizelgesi (Syncfusion lisans riski alınmadı), DAV `mail.pazarlik.com.tr:2080` test
sunucusunda doğrulanmıştı. Bu faz kendi ayrı bölüm planını (veri modeli, CalDAV/CardDAV
senkron stratejisi, ekran akışı) gerektirir — Faz 1-2 bitmeden detaylandırılmayacak.

## Faz 4 — Üretkenlik eşleniği — bekliyor

Küçük, birbirinden bağımsız parçalar — herhangi bir sırayla, diğer fazlara paralel
alınabilir:

- Erteleme (snooze)
- Gönderiyi geri al (undo send — SMTP'ye gönderimden önce kısa bir bekleme penceresi)
- Hızlı Metin / Şablonlar
- İzleme pikseli algılama (mevcut `showRemoteImages` anahtarının ötesinde, mesaj
  başına uyarı)
- Uygulama kilidi (PIN/biyometrik — `local_auth`)

---

Kural (00-yol-haritasi.md'den değişmedi): Her bölüm onaylanmadan bir sonrakine
geçilmez, kod yazılmaz. Faz 2 kod tarafı, kullanıcının OAuth kaydı tamamlanmadan
başlamaz.

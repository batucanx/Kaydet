# Bölüm 5 — eM Client Paritesi (v1.1 Yol Haritası)

## Karar (2026-09-15)

Kullanıcı isteği: KAYDET'in genel yapısı (özellik seti, davranış) eM Client mobile ile
aynı olsun; yalnızca tasarım kendi dili olarak kalsın.

Kapsam netleştirmesi (kullanıcı onayıyla, aynı gün):

| Konu | Karar |
|---|---|
| Gelen kutusu modeli | **Hesap değiştirici** — eM Client'ın birleşik gelen kutusu değil. Tek seferde bir hesap görünür, üstte hızlı geçiş var. |
| OAuth uygulama kaydı | Kullanıcı kendi Microsoft Entra ID hesabıyla oluşturacak; Claude bunu yapamaz (hesap/kimlik oluşturma yasak). |
| Takvim + Kişiler + Notlar | Kapsama **alındı** (önceki "v2'ye bırakıldı" kararının üzerine yazıldı). |
| PGP/S-MIME, AI yardım + anlık çeviri, bulut depolama entegrasyonu | **Kapsam dışı.** MDM zaten sorulmadan kapsam dışı bırakıldı (kurumsal özellik, bu uygulamaya uygun değil). |

## Faz Tablosu

| Faz | İçerik | Durum |
|---|---|---|
| 1 | Çoklu hesap (hesap değiştirici) | ✅ Kodlandı (2026-09-15) |
| 2a | **Gmail** OAuth2 girişi | ❌ Kaldırıldı (2026-09-21) — kullanıcı Google ile girişi istemiyor |
| 2b | **Outlook/MS365** — Graph API (IMAP/SMTP değil) | ⏸ Beklemede. Bkz. "Outlook kararı düzeltmesi" altında. |
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

## Faz 2a — Gmail OAuth2 (kaldırıldı)

Faz 2a 2026-09-15'te kodlanmış, 2026-09-21'de kullanıcı kararıyla **tamamen
kaldırıldı**: uygulamada yalnızca IMAP/SMTP + şifre girişi var.

Kaldırılanlar:

- `GoogleOAuthService` (`data/services/google_oauth_service.dart`), `OAuthTokenSet`,
  `GoogleSignInResult`; `flutter_appauth` ve `http` bağımlılıkları.
- `OAuthCredential` — `MailCredential` artık yalnızca `PasswordCredential` taşır.
- `SecureStore` içindeki OAuth token okuma/yazma/silme; `MailConnection` içindeki
  token yenileme; `AccountRepository.signInWithGoogle()`.
- `Accounts.authMethod` sütunu ve `AuthMethod` enum'u. Şema **v6 → v7** göçü sütunu
  siler (`m.dropColumn`). Eski bir Google hesabı cihazda kaldıysa şifresi olmadığı
  için "kayıtlı şifre yok" hatası verir; hesap kaldırılıp IMAP/SMTP ile yeniden
  eklenmelidir. Eski OAuth token'ı hesap silinirken güvenli depodan da temizlenir
  (`FlutterSecureStore.deletePassword`).
- Giriş ekranındaki "Google ile devam et" düğmesi, `android/app/build.gradle.kts`
  içindeki `appAuthRedirectScheme` placeholder'ı.

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
- İzleme pikseli algılama (uzak görseller artık her zaman yüklendiği için
  mesaj başına uyarı)
- Uygulama kilidi (PIN/biyometrik — `local_auth`)

---

Kural (00-yol-haritasi.md'den değişmedi): Her bölüm onaylanmadan bir sonrakine
geçilmez, kod yazılmaz. Faz 2 kod tarafı, kullanıcının OAuth kaydı tamamlanmadan
başlamaz.

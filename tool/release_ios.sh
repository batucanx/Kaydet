#!/usr/bin/env bash
# Kaydet — iOS release derle ve App Store Connect'e (TestFlight) yükle.
# YALNIZCA macOS'ta çalışır (Xcode gerekir).
#
# Kullanım:
#   bash tool/release_ios.sh <build-numarası> [build-adı]
#   bash tool/release_ios.sh 2            # 1.0.0 (2)
#   bash tool/release_ios.sh 3 1.1.0      # 1.1.0 (3)
#
# Aynı sürüm için her yüklemede build numarası ARTMALIDIR; App Store Connect
# daha önce yüklenmiş bir numarayı reddeder.
#
# Bir kez ~/.zshrc'ye yazılacak ortam değişkenleri (App Store Connect API anahtarı):
#   export ASC_KEY_ID="ABC123DEFG"
#   export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# ve AuthKey_<ASC_KEY_ID>.p8 dosyası ~/.appstoreconnect/private_keys/ altında olmalı.
set -euo pipefail

die() { echo "HATA: $*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Bu betik yalnızca macOS'ta çalışır."
command -v flutter >/dev/null || die "flutter bulunamadı (PATH)."
command -v pod >/dev/null || die "CocoaPods bulunamadı (brew install cocoapods)."
command -v xcrun >/dev/null || die "Xcode komut satırı araçları bulunamadı."

BUILD_NUMBER="${1:-}"
BUILD_NAME="${2:-}"
[[ -n "$BUILD_NUMBER" ]] || die "Build numarası gerekli. Örn: bash tool/release_ios.sh 2"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "Build numarası tam sayı olmalı: '$BUILD_NUMBER'"
: "${ASC_KEY_ID:?ASC_KEY_ID tanımlı değil (bkz. dosya başı)}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID tanımlı değil (bkz. dosya başı)}"
[[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" ]] \
  || die "~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8 bulunamadı."

cd "$(dirname "$0")/.."

echo "==> Bağımlılıklar"
flutter pub get
( cd ios && pod install --repo-update )

# Runner VE ShareExtension hedeflerinde Team seçili olmalı; aksi halde arşiv
# imzalanamaz. (Generated.xcconfig `flutter pub get` ile üretildikten SONRA sorulur.)
for target in Runner ShareExtension; do
  team="$(xcodebuild -project ios/Runner.xcodeproj -target "$target" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ DEVELOPMENT_TEAM = /{print $2; exit}')"
  [[ -n "$team" ]] || die "'$target' hedefinde Team seçili değil. Xcode > Runner > Signing & Capabilities'ten seçip (ve değişikliği commit edip) tekrar deneyin."
  echo "    $target -> Team $team"
done

echo "==> IPA derleniyor (release, build $BUILD_NUMBER)"
ARGS=(--release "--build-number=$BUILD_NUMBER")
if [[ -n "$BUILD_NAME" ]]; then ARGS+=("--build-name=$BUILD_NAME"); fi
flutter build ipa "${ARGS[@]}"

IPA="$(ls -1 build/ios/ipa/*.ipa 2>/dev/null | head -n1 || true)"
[[ -n "$IPA" ]] || die "build/ios/ipa altında .ipa bulunamadı."
echo "==> IPA: $IPA"

# Paylaşım uzantısı pakete girmiş mi? (girmediyse "Paylaş → Kaydet" çalışmaz)
unzip -l "$IPA" | grep -q "PlugIns/ShareExtension.appex" \
  || die "ShareExtension.appex IPA içinde yok; Runner'ın 'Embed Foundation Extensions' fazını kontrol edin."

echo "==> Doğrulama (App Store Connect)"
xcrun altool --validate-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Yükleme (App Store Connect)"
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Tamam. İşleme birkaç dakika sürer; App Store Connect > TestFlight'ta görünür."

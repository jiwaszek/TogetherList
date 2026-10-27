#!/usr/bin/env bash
# Captures App Store screenshots in English and Polish on the iPhone 6.9" and
# iPad 13" simulators, using the DEBUG demo household (-ScreenshotSeed), then
# adds the captions (scripts/compose-screenshots.swift).
#
#   scripts/appstore-screenshots.sh
#
# Output: AppStore/screenshots/raw/<lang>/<device>/*.png   (plain captures)
#         AppStore/screenshots/<lang>/<device>/*.png       (captioned, upload these)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IPHONE="${IPHONE_SIM:-iPhone 17 Pro Max}"
IPAD="${IPAD_SIM:-iPad Pro 13-inch (M5)}"
DERIVED="$ROOT/.build/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/TogetherList.app"

udid() { xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'; }

echo "Building…"
xcodebuild -project TogetherList.xcodeproj -scheme TogetherList -configuration Debug \
  -destination "id=$(udid "$IPHONE")" -derivedDataPath "$DERIVED" build -quiet
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

capture() {   # device-name folder
  local sim; sim=$(udid "$1"); local folder=$2
  xcrun simctl boot "$sim" 2>/dev/null || true
  xcrun simctl bootstatus "$sim" -b >/dev/null
  xcrun simctl ui "$sim" appearance light
  xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl uninstall "$sim" "$BID" 2>/dev/null || true
  xcrun simctl install "$sim" "$APP"

  for lang in en pl; do
    local out="$ROOT/AppStore/screenshots/raw/$lang/$folder"; mkdir -p "$out"
    local locale amount
    if [[ $lang == pl ]]; then locale=pl_PL; amount="86,40"; else locale=en_US; amount="54.90"; fi
    shot() {   # file  extra-args…
      local file=$1; shift
      xcrun simctl terminate "$sim" "$BID" 2>/dev/null || true
      sleep 1
      xcrun simctl launch "$sim" "$BID" -UseInMemoryBackend -ScreenshotSeed "$lang" \
        -AppLanguage "$lang" -AppleLanguages "($lang)" -AppleLocale "$locale" "$@" >/dev/null
      sleep "${SHOT_DELAY:-9}"
      xcrun simctl io "$sim" screenshot "$out/$file.png" >/dev/null 2>&1
      echo "  $lang/$folder/$file.png"
    }
    shot 1-list -DebugOpenFirstList YES
    shot 2-checkout -DebugOpenFirstList YES -DebugCheckout YES -DebugCheckoutAmount "$amount"
    shot 3-balances -DebugTab balances
    shot 4-invite -DebugOpenFirstList YES -DebugShare YES
    shot 5-history -DebugTab history
    shot 6-lists
  done
  xcrun simctl terminate "$sim" "$BID" 2>/dev/null || true
  xcrun simctl status_bar "$sim" clear
}

echo "iPhone ($IPHONE)…"; capture "$IPHONE" iphone-6.9
echo "iPad ($IPAD)…";     capture "$IPAD" ipad-13

echo "Adding captions…"
swift "$ROOT/scripts/compose-screenshots.swift" "$ROOT/AppStore"
echo "Done: AppStore/screenshots/{en,pl}/"

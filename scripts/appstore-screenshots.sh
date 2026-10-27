#!/usr/bin/env bash
# Captures App Store screenshots in English and Polish on the iPhone 6.3",
# iPhone 6.9" and iPad 13" simulators, using the DEBUG demo household
# (-ScreenshotSeed), then adds the captions (scripts/compose-screenshots.swift).
#
#   scripts/appstore-screenshots.sh                  # all sizes
#   scripts/appstore-screenshots.sh iphone-6.3       # only some: iphone-6.3 iphone-6.9 ipad-13
#
# Sizes (portrait): iphone-6.3 1206 × 2622 (iPhone 17 Pro), iphone-6.9 1320 × 2868
# (iPhone 17 Pro Max), ipad-13 2064 × 2752 (iPad Pro 13").
#
# Output: AppStore/screenshots/raw/<lang>/<device>/*.png   (plain captures)
#         AppStore/screenshots/<lang>/<device>/*.png       (captioned, upload these)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IPHONE_63="${IPHONE_63_SIM:-iPhone 17 Pro}"
IPHONE_69="${IPHONE_69_SIM:-iPhone 17 Pro Max}"
IPAD="${IPAD_SIM:-iPad Pro 13-inch (M5)}"
SIZES=("${@:-iphone-6.3 iphone-6.9 ipad-13}")
SIZES=(${SIZES[*]})
DERIVED="$ROOT/.build/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/TogetherList.app"

udid() { xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'; }

echo "Building…"
xcodebuild -project TogetherList.xcodeproj -scheme TogetherList -configuration Debug \
  -destination "id=$(udid "$IPHONE_63")" -derivedDataPath "$DERIVED" build -quiet
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

for size in "${SIZES[@]}"; do
  case $size in
    iphone-6.3) echo "iPhone 6.3\" ($IPHONE_63)…"; capture "$IPHONE_63" iphone-6.3 ;;
    iphone-6.9) echo "iPhone 6.9\" ($IPHONE_69)…"; capture "$IPHONE_69" iphone-6.9 ;;
    ipad-13)    echo "iPad 13\" ($IPAD)…";         capture "$IPAD" ipad-13 ;;
    *) echo "Unknown size $size (use iphone-6.3, iphone-6.9 or ipad-13)"; exit 1 ;;
  esac
done

echo "Adding captions…"
swift "$ROOT/scripts/compose-screenshots.swift" "$ROOT/AppStore"
echo "Done: AppStore/screenshots/{en,pl}/"

#!/usr/bin/env bash
# PDFium'un hazır iOS derlemelerini (bblanchon/pdfium-binaries) indirir ve
# Xcode'un bağlayıp uygulamaya gömebileceği Vendor/PDFium.xcframework'e çevirir.
# Yalnızca macOS'ta çalışır (install_name_tool, xcodebuild).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${PDFIUM_TAG:-chromium/8076}"
BASE="https://github.com/bblanchon/pdfium-binaries/releases/download/${TAG/\//%2F}"
WORK=Vendor/.pdfium
OUT=Vendor/PDFium.xcframework
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK"

frameworks=()
for slice in device-arm64:iPhoneOS simulator-arm64:iPhoneSimulator; do
  name="${slice%%:*}"
  platform="${slice##*:}"
  src="$WORK/$name/src"
  fw="$WORK/$name/PDFium.framework"
  mkdir -p "$src" "$fw/Headers" "$fw/Modules"
  curl -fsSL "$BASE/pdfium-ios-$name.tgz" | tar -xz -C "$src"

  # App Store dinamik kütüphaneyi yalnızca framework paketi içinde kabul eder.
  cp "$src/lib/libpdfium.dylib" "$fw/PDFium"
  install_name_tool -id @rpath/PDFium.framework/PDFium "$fw/PDFium"

  cp "$src"/include/*.h "$fw/Headers/"
  {
    echo '#include "fpdfview.h"'
    for header in "$fw"/Headers/fpdf_*.h; do
      echo "#include \"$(basename "$header")\""
    done
  } > "$fw/Headers/PDFium.h"
  cat > "$fw/Modules/module.modulemap" <<'EOF'
framework module PDFium {
  umbrella header "PDFium.h"
  export *
  module * { export * }
}
EOF

  source "$src/VERSION"
  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>PDFium</string>
  <key>CFBundleIdentifier</key><string>com.jordenss00.PDFium</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>PDFium</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$MAJOR.$MINOR.$BUILD</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>17.0</string>
</dict>
</plist>
EOF
  frameworks+=(-framework "$fw")
done

xcodebuild -create-xcframework "${frameworks[@]}" -output "$OUT"

# Uygulamadaki "Lisanslar" ekranı için üçüncü taraf lisans metinleri.
rm -rf Vendor/PDFium-licenses
mkdir -p Vendor/PDFium-licenses
cp "$WORK/device-arm64/src/LICENSE" Vendor/PDFium-licenses/pdfium-binaries.txt
cp "$WORK/device-arm64/src/licenses/"* Vendor/PDFium-licenses/
echo "PDFium $TAG -> $OUT"

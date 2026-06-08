#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Awake"
BUNDLE_ID="com.mackhaymond.Awake"
VERSION="1.0"
BUILD="1"
MIN_OS="14.0"
DEST="${APP_NAME}.app"

cd "$(dirname "$0")"

# 1. Compile a release executable.
#    For a universal binary: swift build -c release --arch arm64 --arch x86_64
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

# 2. Assemble the bundle skeleton.
rm -rf "${DEST}"
mkdir -p "${DEST}/Contents/MacOS" "${DEST}/Contents/Resources"

# 3. Copy the executable (CFBundleExecutable must equal this filename).
cp "${BIN_PATH}" "${DEST}/Contents/MacOS/${APP_NAME}"
chmod +x "${DEST}/Contents/MacOS/${APP_NAME}"

# 4. App icon: render the cup-on-squircle .iconset via the binary, then iconutil.
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
"${DEST}/Contents/MacOS/${APP_NAME}" --appicon "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${DEST}/Contents/Resources/AppIcon.icns"

# 5. Write Info.plist.
cat > "${DEST}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>               <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>${MIN_OS}</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key>   <true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIconName</key>              <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>      <string>© 2026 Awake</string>
</dict>
</plist>
PLIST

# 6. Validate.
plutil -lint "${DEST}/Contents/Info.plist"

# 7. Ad-hoc codesign (sufficient to run on this Mac).
codesign --force --deep --sign - "${DEST}"

# 8. Verify.
codesign --verify --verbose "${DEST}"

echo "Built ${DEST}"
echo "Run:  open ${DEST}     (registers with LaunchServices; menu-bar icon appears)"

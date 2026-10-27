#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）并打包 DMG
set -e
cd "$(dirname "$0")"
SRC="main.swift Monitor.swift Battery.swift Dashboard.swift BatteryView.swift Tests.swift"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13 $SRC -o mo_arm
swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13 $SRC -o mo_x86
lipo -create mo_arm mo_x86 -output MacOptimizer
A="build/Mac一键优化.app"; rm -rf build; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp MacOptimizer "$A/Contents/MacOS/"; cp AppIcon.icns "$A/Contents/Resources/"; cp Info.plist "$A/Contents/"
# 固定自签名证书：登录项、通知授权在更新后保持有效；没有证书时退回临时签名
KC="$HOME/.filebutler-signing/signing.keychain-db"
if [ -f "$KC" ] && [ -f "$HOME/.filebutler-signing/pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.filebutler-signing/pass")" "$KC"
  codesign --force --deep --keychain "$KC" -s "FileButler Local Signing" -i com.yost.macoptimizer "$A"
else
  codesign --force --deep -s - "$A"
fi
mkdir -p build/dmg; cp -R "$A" build/dmg/; ln -s /Applications build/dmg/Applications
hdiutil create -volname "Mac一键优化" -srcfolder build/dmg -ov -format UDZO "build/Mac一键优化.dmg" >/dev/null
echo "完成：build/Mac一键优化.dmg"

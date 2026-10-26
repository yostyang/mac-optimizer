#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）并打包 DMG
set -e
cd "$(dirname "$0")"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13 main.swift -o mo_arm
swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13 main.swift -o mo_x86
lipo -create mo_arm mo_x86 -output MacOptimizer
A="build/Mac一键优化.app"; rm -rf build; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp MacOptimizer "$A/Contents/MacOS/"; cp AppIcon.icns "$A/Contents/Resources/"; cp Info.plist "$A/Contents/"
codesign --force --deep -s - "$A"
mkdir -p build/dmg; cp -R "$A" build/dmg/; ln -s /Applications build/dmg/Applications
hdiutil create -volname "Mac一键优化" -srcfolder build/dmg -ov -format UDZO "build/Mac一键优化.dmg"
echo "完成：build/Mac一键优化.dmg"

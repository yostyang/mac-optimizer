#!/bin/bash
# 编译通用版（Apple 芯片 + Intel）并打包 DMG
set -e
cd "$(dirname "$0")"
SRC="main.swift Monitor.swift Battery.swift Dashboard.swift BatteryView.swift ChargeCore.swift ChargeView.swift Tests.swift ChargeTests.swift DNSCore.swift Display.swift DisplayView.swift Network.swift NetView.swift BTBattery.swift V15Tests.swift"
HSRC="ChargeCore.swift ChargeHelper.swift DNSCore.swift"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13 $SRC -o mo_arm
swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13 $SRC -o mo_x86
lipo -create mo_arm mo_x86 -output MacOptimizer
# 充电助手：自签名（无 Team ID）时，macOS 按助手的 cdhash 记录用户授权（launchd LWCR）。
# 助手二进制只要变一个字节，升级后就要用户重新允许。所以只有助手源码变化时才重新编译/签名，
# 否则复用缓存里已签名的同一份文件（cdhash 不变，授权保留）。
HKEY=$(cat $HSRC com.yost.macoptimizer.chargehelper.plist | shasum | cut -c1-16)
HCACHE="helper-cache/$HKEY"
if [ ! -f "$HCACHE/MacOptimizerChargeHelper" ]; then
  swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13 $HSRC -o ch_arm
  swiftc -O -parse-as-library -swift-version 5 -target x86_64-apple-macos13 $HSRC -o ch_x86
  lipo -create ch_arm ch_x86 -output MacOptimizerChargeHelper
  HNEW=1
else
  cp "$HCACHE/MacOptimizerChargeHelper" MacOptimizerChargeHelper; HNEW=0
  echo "充电助手源码未变：复用已签名助手 ${HKEY}（升级不需要重新授权）"
fi
A="build/Mac一键优化.app"; rm -rf build; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources" "$A/Contents/Library/LaunchDaemons"
cp MacOptimizer MacOptimizerChargeHelper "$A/Contents/MacOS/"; cp com.yost.macoptimizer.chargehelper.plist "$A/Contents/Library/LaunchDaemons/"; cp AppIcon.icns "$A/Contents/Resources/"; cp Info.plist "$A/Contents/"
# 固定自签名证书：登录项、通知授权在更新后保持有效；没有证书时退回临时签名
KC="$HOME/.filebutler-signing/signing.keychain-db"
if [ -f "$KC" ] && [ -f "$HOME/.filebutler-signing/pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.filebutler-signing/pass")" "$KC"
  # 先单独签助手（自己的标识），再签 App（不用 --deep，避免覆盖助手标识）
  if [ "$HNEW" = 1 ]; then
    codesign --force --options runtime --keychain "$KC" -s "FileButler Local Signing" -i com.yost.macoptimizer.chargehelper "$A/Contents/MacOS/MacOptimizerChargeHelper"
    mkdir -p "$HCACHE"; cp "$A/Contents/MacOS/MacOptimizerChargeHelper" "$HCACHE/"
    echo "⚠️ 充电助手源码有变化：新助手需要用户在「登录项与扩展」里重新允许一次"
  fi
  codesign --force --keychain "$KC" -s "FileButler Local Signing" -i com.yost.macoptimizer "$A"
else
  codesign --force -s - -i com.yost.macoptimizer.chargehelper "$A/Contents/MacOS/MacOptimizerChargeHelper"; codesign --force -s - "$A"
fi
mkdir -p build/dmg; cp -R "$A" build/dmg/; ln -s /Applications build/dmg/Applications
hdiutil create -volname "Mac一键优化" -srcfolder build/dmg -ov -format UDZO "build/Mac一键优化.dmg" >/dev/null
echo "完成：build/Mac一键优化.dmg"

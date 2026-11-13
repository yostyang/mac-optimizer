#!/bin/bash
# 不启动 App、不读写真实 DNS；临时目录退出时自动清理。
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc ${SWIFTFLAGS:-} -D SAFETY_CORE_TESTS -parse-as-library -swift-version 5 \
  CleanCore.swift DNSCore.swift SafetyCoreTests.swift -o "$OUT/safety-core"
"$OUT/safety-core"
python3 release-tests.py

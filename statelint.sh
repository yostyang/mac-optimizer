#!/bin/bash
# 2.14 统一状态检查：下列页面的「正在… / 暂无 / 没有检测到」和整页转圈，必须用 StateLine（加载 / 空白 / 未知 / 过期 / 失败 / 完成）。
# 按钮自己的文字（例如「扫描中…」）不算状态行，不检查。新页面接入统一状态后把文件加进 FILES。
cd "$(dirname "$0")"
FILES="main.swift NetView.swift NetworkOverview.swift V26Split.swift V25Shell.swift V24View.swift Clean.swift CleanFooter.swift Changes.swift SplitRatioEditor.swift"
BAD=$(grep -nE 'Text\("(正在|暂无|没有检测到)|Text\([A-Za-z_.]+ \? "(正在|暂无)|ProgressView\(\)\.frame\(maxWidth: \.infinity, maxHeight' $FILES)
N=$(printf '%s' "$BAD" | grep -c . || true)
if [ "$N" -gt 0 ]; then
  echo "$BAD" | sed 's/^/  ✗ /'
  echo "statelint: 0 通过, $N 失败（页面状态请用 StateLine）"; exit 1
fi
echo "statelint: 1 通过, 0 失败（页面状态均用 StateLine）"

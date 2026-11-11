#!/bin/bash
# 2.13 字号检查（测试门槛 A 的一部分）：正文 13 pt、说明文字不小于 12 pt。
# 10–11 pt 只允许用于单位和时间，必须在同一行行尾注明「// 单位」或「// 时间」；纯图标（不是文字）注明「// 图标」。
# 测试文件（*Tests.swift）不参与界面，不检查。
cd "$(dirname "$0")"
FILES=$(ls *.swift | grep -v -E 'Tests\.swift$')
BAD=$(grep -nE 'size: *([0-9]|1[01])(\.[0-9]+)?[,)]|DS\.num\( *([0-9]|1[01])(\.[0-9]+)?[,)]|\.font\(\.(caption|caption2|footnote)\)|\.system\(\.(caption|caption2|footnote)' $FILES | grep -vE '// *(单位|时间|图标)')
N=$(printf '%s' "$BAD" | grep -c . || true)
if [ "$N" -gt 0 ]; then
  echo "$BAD" | sed 's/^/  ✗ /'
  echo "fontlint: 0 通过, $N 失败（说明文字小于 12 pt）"; exit 1
fi
echo "fontlint: 1 通过, 0 失败（说明文字均 ≥ 12 pt；10–11 pt 仅限标注为单位/时间的行）"

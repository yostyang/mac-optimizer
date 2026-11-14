#!/bin/bash
# 2.13 字号检查（测试门槛 A 的一部分）：正文 13 pt、说明文字不小于 12 pt。
# 10–11 pt 只允许用于单位和时间，必须在同一行行尾注明「// 单位」或「// 时间」；纯图标（不是文字）注明「// 图标」。
# 测试文件（*Tests.swift）不参与界面，不检查。
# 2.16 N6 另查：页面文字不再直接写 .system(size:)，例外须登记用途（见下）。
cd "$(dirname "$0")"
FILES=$(ls *.swift | grep -v -E 'Tests\.swift$')
BAD=$(grep -nE 'size: *([0-9]|1[01])(\.[0-9]+)?[,)]|DS\.num\( *([0-9]|1[01])(\.[0-9]+)?[,)]|\.font\(\.(caption|caption2|footnote)\)|\.system\(\.(caption|caption2|footnote)' $FILES | grep -vE '// *(单位|时间|图标)')
N=$(printf '%s' "$BAD" | grep -c . || true)
if [ "$N" -gt 0 ]; then
  echo "$BAD" | sed 's/^/  ✗ /'
  echo "fontlint: 0 通过, $N 失败（说明文字小于 12 pt）"; exit 1
fi
# 2.16 N6：页面文字一律用语义样式（DS.title / body / sub / cap / num / unit / label / eyebrow）。
# 仍直接写 `.system(size:` 的行必须在行尾登记用途：// 图标、// 数字、// 动态（按容器计算）、// 单位、// 时间、// 令牌（DS 自身定义）。
RAW=$(grep -nE '\.system\(size:' $FILES | grep -vE '// *(单位|时间|图标|数字|动态|令牌)')
M=$(printf '%s' "$RAW" | grep -c . || true)
if [ "$M" -gt 0 ]; then
  echo "$RAW" | sed 's/^/  ✗ /'
  echo "fontlint: 1 通过, $M 失败（页面文字未用语义样式，也没有登记例外用途）"; exit 1
fi
EXC=$(grep -cE '\.system\(size:' $FILES | awk -F: '{s+=$2} END {print s+0}')
echo "fontlint: 2 通过, 0 失败（说明文字均 ≥ 12 pt；页面文字用语义样式，登记的例外 $EXC 处）"

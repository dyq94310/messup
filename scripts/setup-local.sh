#!/usr/bin/env bash
# 本地联调：将 messup-private 软链为 private-config
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARENT="$(cd "$ROOT/.." && pwd)"
PRIVATE_DEFAULT="${PARENT}/messup-private"
PRIVATE="${1:-$PRIVATE_DEFAULT}"
LINK="${ROOT}/private-config"

if [ ! -d "$PRIVATE" ]; then
  echo "❌ 找不到私有仓目录: $PRIVATE"
  echo "用法: $0 [/path/to/messup-private]"
  echo "请先 clone:"
  echo "  git clone git@github.com:dyq94310/messup-private.git $PRIVATE_DEFAULT"
  exit 1
fi

if [ ! -d "$PRIVATE/singbox" ]; then
  echo "❌ $PRIVATE 下没有 singbox/ 目录，确认是 messup-private 仓库"
  exit 1
fi

if [ ! -f "$PRIVATE/inventory/inventory.ini" ]; then
  echo "❌ $PRIVATE 下没有 inventory/inventory.ini（主机清单应在私有仓）"
  exit 1
fi

ln -sfn "$PRIVATE" "$LINK"
echo "✅ 已链接: $LINK → $PRIVATE"
echo ""
echo "目录树:"
find -L "$LINK" -type f ! -path '*/.git/*' 2>/dev/null | sort | head -50
echo ""
echo "下一步:"
echo "  cd $ROOT"
echo "  ansible-playbook playbooks/site.yml"
echo "  # 或: ./scripts/deploy.sh"

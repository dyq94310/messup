#!/usr/bin/env bash
# 本地部署封装
# 用法:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh --tags singbox
#   ./scripts/deploy.sh --limit 172.245.220.230
#   ./scripts/deploy.sh --tags smartdns --limit rear-host
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -e private-config ]; then
  echo "⚠️  private-config 不存在，尝试自动 setup..."
  "$ROOT/scripts/setup-local.sh" || exit 1
fi

if [ ! -d private-config/singbox ]; then
  echo "❌ private-config/singbox 不可用，请检查软链: ls -la private-config"
  exit 1
fi

export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"

echo "==> ansible-playbook playbooks/site.yml $*"
exec ansible-playbook playbooks/site.yml \
  -e "private_config_temp=${ROOT}/private-config" \
  "$@"

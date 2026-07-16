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

# 可选：先做 raw 预检（不依赖目标机 Python）；SKIP_CONN_CHECK=1 跳过
if [ "${SKIP_CONN_CHECK:-0}" != "1" ]; then
  # 从参数中提取 --limit（若有）
  LIMIT_FOR_CHECK=""
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "--limit" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
      LIMIT_FOR_CHECK="${args[$((i + 1))]}"
    fi
  done
  LIMIT="${LIMIT_FOR_CHECK}" FAIL_IF_ALL_DOWN=1 \
    "$ROOT/scripts/check-connectivity.sh" || exit 1
fi

echo "==> ansible-playbook playbooks/site.yml $*"
set +e
ansible-playbook playbooks/site.yml \
  -e "private_config_temp=${ROOT}/private-config" \
  "$@"
rc=$?
set -e
# exit 3 = 仅不可达：有 ignore_unreachable 时少见；当作警告
if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
  exit 0
fi
exit "$rc"

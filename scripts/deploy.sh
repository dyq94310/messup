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

if [ ! -f private-config/inventory/inventory.ini ]; then
  echo "❌ private-config/inventory/inventory.ini 不可用（主机清单在私有仓）"
  exit 1
fi

export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
# bootstrap 密码阶段禁用 ControlMaster，避免复用失败的密钥会话
export ANSIBLE_SSH_ARGS="${ANSIBLE_SSH_ARGS:--o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"

# 1) 先 SSH bootstrap：密钥优先；失败且 inventory 有 bootstrap_password 则密码装钥
#    必须在连通性预检之前，否则新机会被误判不可达而跳过
NEED_PW=0
if grep -E '[[:space:]]bootstrap_password=' private-config/inventory/inventory.ini \
  | grep -vE '^[[:space:]]*#' >/dev/null 2>&1; then
  NEED_PW=1
fi

if [ "$NEED_PW" -eq 1 ] && ! command -v sshpass >/dev/null 2>&1; then
  echo "❌ inventory 含 bootstrap_password，但本机无 sshpass"
  echo "   请安装: sudo apt-get install -y sshpass"
  exit 1
fi

echo "==> ansible-playbook playbooks/00-bootstrap-ssh.yml $*"
set +e
ansible-playbook playbooks/00-bootstrap-ssh.yml \
  -e "private_config_temp=${ROOT}/private-config" \
  "$@"
bootstrap_rc=$?
set -e
if [ "$bootstrap_rc" -ne 0 ]; then
  if [ "$NEED_PW" -eq 1 ]; then
    echo "❌ SSH bootstrap 失败 (rc=${bootstrap_rc})，且存在 bootstrap_password，中止"
    exit "$bootstrap_rc"
  fi
  if [ "$bootstrap_rc" -ne 3 ]; then
    echo "⚠️  SSH bootstrap 部分失败 (rc=${bootstrap_rc})，继续预检/部署可达主机"
  fi
fi

# 2) raw 预检（不依赖目标机 Python）；SKIP_CONN_CHECK=1 跳过
if [ "${SKIP_CONN_CHECK:-0}" != "1" ]; then
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

# 3) 全量 site（内含幂等 SSH bootstrap + python + 业务）
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

#!/usr/bin/env bash
# SSH 连通性预检：使用 raw 模块，不依赖目标机 Python（适合裸 Alpine LXC）
# - 可达：打印 OK
# - 不可达：打印警告，不退出失败（除非全部不可达）
# 输出（供 CI 使用）:
#   GITHUB_OUTPUT: reachable_limit=host1:host2  或  all（全部可达时为空限制）
#   GITHUB_OUTPUT: unreachable_hosts=...
#   GITHUB_OUTPUT: reachable_count / unreachable_count
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INVENTORY="${INVENTORY:-private-config/inventory/inventory.ini}"
PRIVATE_KEY="${PRIVATE_KEY:-${ANSIBLE_PRIVATE_KEY:-$HOME/.ssh/id_ed25519_github}}"
GROUP="${GROUP:-lxc_nodes}"
LIMIT="${LIMIT:-}"
# 全部不可达时是否失败（默认是）
FAIL_IF_ALL_DOWN="${FAIL_IF_ALL_DOWN:-1}"

LIMIT_ARGS=()
if [ -n "${LIMIT}" ] && [ "${LIMIT}" != "<all>" ]; then
  LIMIT_ARGS=(--limit "${LIMIT}")
fi

KEY_ARGS=()
if [ -n "${PRIVATE_KEY}" ] && [ -f "${PRIVATE_KEY}" ]; then
  KEY_ARGS=(--private-key "${PRIVATE_KEY}")
fi

export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
# 缩短不可达主机等待时间
export ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-15}"
# 与 bootstrap 一致：IdentitiesOnly + 禁用 ControlMaster，避免串钥/复用失败会话
export ANSIBLE_SSH_ARGS="${ANSIBLE_SSH_ARGS:--o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "==> SSH 预检 (raw, 无需 Python): group=${GROUP} limit=${LIMIT:-all}"
set +e
# raw + 简单 shell，不调用 ping 模块（ping 需要目标机 Python）
ansible "${GROUP}" \
  -i "${INVENTORY}" \
  "${KEY_ARGS[@]}" \
  "${LIMIT_ARGS[@]}" \
  -m raw -a 'echo __SSH_OK__' \
  -o 2>&1 | tee "$TMP"
set -e

# 解析 ansible -o 输出
# 成功: 1.2.3.4 | CHANGED | rc=0 | (stdout) __SSH_OK__
# 不可达: 1.2.3.4 | UNREACHABLE! => {...}
host_field() { cut -d'|' -f1 | sed 's/[[:space:]]*$//;s/^[[:space:]]*//' | grep -v '^$' | sort -u; }

mapfile -t REACHABLE < <(grep -E '\| (CHANGED|SUCCESS)' "$TMP" | host_field || true)
mapfile -t UNREACHABLE < <(grep -E 'UNREACHABLE' "$TMP" | host_field || true)

# 有时 FAILED 也是连接/认证问题
mapfile -t FAILED < <(grep -E '\| FAILED' "$TMP" | host_field || true)

# 合并 failed 到 unreachable 提示（SSH/认证失败）
for h in "${FAILED[@]:-}"; do
  [ -z "$h" ] && continue
  skip=0
  for r in "${REACHABLE[@]:-}"; do
    [ "$h" = "$r" ] && skip=1 && break
  done
  if [ "$skip" -eq 0 ]; then
    UNREACHABLE+=("$h")
  fi
done
# 去重
if [ ${#UNREACHABLE[@]} -gt 0 ]; then
  mapfile -t UNREACHABLE < <(printf '%s\n' "${UNREACHABLE[@]}" | sort -u)
fi

RC=0
echo ""
echo "---------- 连通性摘要 ----------"
if [ ${#REACHABLE[@]} -gt 0 ]; then
  echo "✅ 可达 (${#REACHABLE[@]}): ${REACHABLE[*]}"
else
  echo "❌ 可达: (无)"
  RC=1
fi

if [ ${#UNREACHABLE[@]} -gt 0 ]; then
  echo "⚠️  不可达/失败 (${#UNREACHABLE[@]}): ${UNREACHABLE[*]}"
  echo "   → 将跳过上述节点，继续部署其他主机（不会因此中止流水线）"
  # CI 注解：警告而非 error
  for h in "${UNREACHABLE[@]}"; do
    echo "::warning::主机 ${h} SSH 不可达，已跳过部署。检查端口/authorized_keys/网络；新机可在 inventory 设 bootstrap_password 做首次装钥。"
  done
else
  echo "✅ 无不可达主机"
fi
echo "--------------------------------"

# 写 GitHub Actions outputs
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "reachable_count=${#REACHABLE[@]}"
    echo "unreachable_count=${#UNREACHABLE[@]}"
    echo "unreachable_hosts=${UNREACHABLE[*]:-}"
    if [ ${#REACHABLE[@]} -eq 0 ]; then
      echo "reachable_limit="
      echo "has_reachable=false"
    elif [ ${#UNREACHABLE[@]} -eq 0 ]; then
      # 全部可达：不额外限制（保留原 limit）
      echo "reachable_limit="
      echo "has_reachable=true"
    else
      # 仅部署可达主机：用冒号分隔（ansible --limit 语法）
      IFS=':'
      echo "reachable_limit=${REACHABLE[*]}"
      unset IFS
      echo "has_reachable=true"
    fi
  } >> "$GITHUB_OUTPUT"
fi

# Step summary
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### SSH 连通性 (raw, 无 Python)"
    echo "- 可达: **${#REACHABLE[@]}** — \`${REACHABLE[*]:-无}\`"
    echo "- 跳过: **${#UNREACHABLE[@]}** — \`${UNREACHABLE[*]:-无}\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$RC" -ne 0 ] && [ "$FAIL_IF_ALL_DOWN" = "1" ]; then
  echo "::error::所有目标主机均不可达，中止部署。"
  exit 1
fi

exit 0

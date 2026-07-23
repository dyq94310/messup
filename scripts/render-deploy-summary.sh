#!/usr/bin/env bash
# Render a human-readable per-host deployment matrix for GitHub Actions.
set -euo pipefail

INVENTORY="${INVENTORY:-private-config/inventory/inventory.ini}"
TAGS="${TAGS:-}"
LIMIT="${LIMIT:-}"
REACHABLE="${REACHABLE:-}"
UNREACHABLE="${UNREACHABLE:-}"
PLAYBOOK_RC="${PLAYBOOK_RC:-}"
MODE="${MODE:-}"
EVENT_NAME="${EVENT_NAME:-}"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"

if [ -z "$SUMMARY" ]; then
  echo "GITHUB_STEP_SUMMARY is required" >&2
  exit 1
fi

contains_word() {
  local list="$1" wanted="$2" item
  [ -z "$list" ] && return 1
  IFS=' ,:' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    [ "$item" = "$wanted" ] && return 0
  done
  return 1
}

csv_from_section() {
  local section="$1"
  awk -v wanted="$section" '
    $0 == "[" wanted "]" { active=1; next }
    /^\[/ { active=0 }
    active && NF && $1 !~ /^#/ { print $1 }
  ' "$INVENTORY"
}

managed_hosts=$(awk '
  /^\[(lxc_nodes|kvm_nodes)\]$/ { active=1; next }
  /^\[/ { active=0 }
  active && NF && $1 !~ /^#/ { print $1 }
' "$INVENTORY" | sort -u)

if [ -z "$managed_hosts" ]; then
  echo "No managed hosts found in $INVENTORY" >&2
  exit 1
fi

singbox_hosts=$(csv_from_section singbox_nodes)
smartdns_hosts=$(csv_from_section smartdns_nodes)
nft_hosts=$(csv_from_section nft_nodes)

# Empty limit means all hosts. Exact host limits are the normal generated form.
# For group/pattern limits, fall back to the complete inventory so the summary
# does not claim a narrower scope than it can safely resolve here.
target_hosts="$managed_hosts"
if [ -n "$LIMIT" ] && [ "$LIMIT" != "<all>" ]; then
  target_hosts=""
  IFS=':' read -r -a limit_items <<< "$LIMIT"
  unresolved=0
  for host in "${limit_items[@]}"; do
    if printf '%s\n' "$managed_hosts" | grep -Fxq "$host"; then
      target_hosts="${target_hosts}${host}\n"
    else
      unresolved=1
    fi
  done
  if [ "$unresolved" -eq 1 ] || [ -z "$target_hosts" ]; then
    target_hosts="$managed_hosts"
  else
    target_hosts=$(printf '%b' "$target_hosts" | sed '/^$/d' | sort -u)
  fi
fi

# Keep unreachable hosts in the matrix even when the connectivity helper
# provides only the reachable subset as its output.
if [ -n "$UNREACHABLE" ]; then
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    if printf '%s\n' "$managed_hosts" | grep -Fxq "$host" && ! printf '%s\n' "$target_hosts" | grep -Fxq "$host"; then
      target_hosts="${target_hosts}${host}\n"
    fi
  done < <(printf '%s\n' "$UNREACHABLE" | tr ' ,:' '\n' | sed '/^$/d')
  target_hosts=$(printf '%b' "$target_hosts" | sed '/^$/d' | sort -u)
fi

service_requested() {
  local service="$1"
  if [ -z "$TAGS" ] || [ "$TAGS" = "<all>" ] || contains_word "$TAGS" "$service"; then
    return 0
  fi
  return 1
}

host_status() {
  local host="$1"
  if contains_word "$UNREACHABLE" "$host"; then
    printf '不可达'
  elif [ -n "$REACHABLE" ] && ! contains_word "$REACHABLE" "$host"; then
    printf '未检查'
  else
    printf '执行'
  fi
}

service_status() {
  local host="$1" service="$2" members="$3"
  if ! service_requested "$service" || ! printf '%s\n' "$members" | grep -Fxq "$host"; then
    printf '跳过'
  elif contains_word "$UNREACHABLE" "$host"; then
    printf '不可达'
  else
    printf '执行'
  fi
}

result_text=""
case "$PLAYBOOK_RC" in
  0)
    if [ -n "$UNREACHABLE" ]; then
      result_text="完成（存在不可达主机）"
    else
      result_text="成功"
    fi
    ;;
  3) result_text="完成（存在不可达主机）" ;;
  "") result_text="未执行或结果未知" ;;
  *) result_text="失败（rc=$PLAYBOOK_RC）" ;;
esac

target_count=$(printf '%s\n' "$target_hosts" | sed '/^$/d' | wc -l | tr -d ' ')
if [ -n "$LIMIT" ] && [ "$LIMIT" != "<all>" ]; then
  deploy_mode="定向节点收敛"
else
  deploy_mode="全量部署"
fi

if [ -z "$TAGS" ] || [ "$TAGS" = "<all>" ]; then
  service_scope="全部服务"
else
  service_scope="$TAGS"
fi

{
  echo "## 部署摘要"
  echo ""
  echo "| 项目 | 内容 |"
  echo "|---|---|"
  echo "| 部署模式 | ${deploy_mode} |"
  echo "| 目标节点 | ${target_count} 台 |"
  echo "| 本次服务 | ${service_scope} |"
  echo "| 最终结果 | ${result_text} |"
  echo ""
  echo "## 节点操作明细"
  echo ""
  echo "| 节点 | SSH | Python | SmartDNS | sing-box | nft | 结果 |"
  echo "|---|---|---|---|---|---|---|"
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    ssh_state=$(host_status "$host")
    if [ "$ssh_state" = "不可达" ]; then
      row_result="不可达"
    elif [ "$PLAYBOOK_RC" != "" ] && [ "$PLAYBOOK_RC" != "0" ] && [ "$PLAYBOOK_RC" != "3" ]; then
      row_result="失败"
    elif [ "$ssh_state" = "未检查" ]; then
      row_result="未检查"
    else
      row_result="成功"
    fi
    printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' \
      "$host" "$ssh_state" \
      "$( [ "$ssh_state" = "不可达" ] && printf '不可达' || printf '执行' )" \
      "$(service_status "$host" smartdns "$smartdns_hosts")" \
      "$(service_status "$host" singbox "$singbox_hosts")" \
      "$(service_status "$host" nft "$nft_hosts")" \
      "$row_result"
  done <<< "$target_hosts"

  if [ -n "$UNREACHABLE" ]; then
    echo ""
    echo "## 连接异常"
    echo ""
    echo "以下节点 SSH 预检失败，相关服务未执行：\`${UNREACHABLE}\`。"
  fi

  echo ""
  echo "<details>"
  echo "<summary>技术诊断信息</summary>"
  echo ""
  echo "- 触发事件：\`${EVENT_NAME:-unknown}\`"
  echo "- Ansible tags：\`${TAGS:-all}\`"
  echo "- Ansible limit：\`${LIMIT:-all}\`"
  echo "- 部署模式：\`${MODE:-unknown}\`"
  echo "- 可达节点：\`${REACHABLE:-unknown}\`"
  echo "- 不可达节点：\`${UNREACHABLE:-none}\`"
  echo "- playbook rc：\`${PLAYBOOK_RC:-unknown}\`"
  echo ""
  echo "</details>"
} >> "$SUMMARY"

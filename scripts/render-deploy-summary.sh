#!/usr/bin/env bash
# Render a human-readable per-host deployment matrix for GitHub Actions.
# The first inventory field is always the display name; ansible_host remains
# an internal connection variable and is never intentionally rendered here.
#
# Matrix cells are planned scope (tags + inventory groups), not per-task success.
# Bark host lines use the compact per-host PLAY RECAP results collected by CI.
set -euo pipefail

INVENTORY="${INVENTORY:-private-config/inventory/}"
TAGS="${TAGS:-}"
LIMIT="${LIMIT:-}"
REACHABLE="${REACHABLE:-}"
UNREACHABLE="${UNREACHABLE:-}"
PLAYBOOK_RC="${PLAYBOOK_RC:-}"
MODE="${MODE:-}"
EVENT_NAME="${EVENT_NAME:-}"
DEPLOY_PLAN="${DEPLOY_PLAN:-}"
COMMIT_TITLE="${COMMIT_TITLE:-私有仓提交标题未知}"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"
BARK_SUMMARY_FILE="${BARK_SUMMARY_FILE:-}"
DEPLOY_STATUS_FILE="${DEPLOY_STATUS_FILE:-}"

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

inventory_json=$(ansible-inventory -i "$INVENTORY" --list)

csv_from_section() {
  local section="$1"
  jq -r --arg section "$section" '.[$section].hosts[]? // empty' <<< "$inventory_json"
}

# Inventory hostnames are the values Ansible prints in normal task output.
# Read the merged inventory so directory-based inventories and group children
# have the same behavior as the playbooks.
managed_hosts=$(jq -r '([.all_nodes.hosts[]?, .lxc_nodes.hosts[]?, .kvm_nodes.hosts[]?] | unique)[]' <<< "$inventory_json")

if [ -z "$managed_hosts" ]; then
  echo "No managed hosts found in $INVENTORY" >&2
  exit 1
fi

singbox_hosts=$(csv_from_section singbox_nodes)
smartdns_hosts=$(csv_from_section smartdns_nodes)
nft_hosts=$(csv_from_section nft_nodes)
probe_hosts=$(csv_from_section probe_nodes)

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
    printf '计划'
  fi
}

declare -A host_service_changed host_service_failed host_service_unreachable
declare -A host_service_seen host_service_list
if [ -n "$DEPLOY_STATUS_FILE" ] && [ -r "$DEPLOY_STATUS_FILE" ]; then
  while IFS=$'\t' read -r service host changed failed unreachable skipped; do
    [ -n "$service" ] && [ -n "$host" ] || continue
    host="${host%$'\r'}"
    changed="${changed:-0}"
    failed="${failed:-0}"
    unreachable="${unreachable:-0}"
    skipped="${skipped:-0}"
    key="${host}"$'\034'"${service}"
    if [ -z "${host_service_seen[$key]+set}" ]; then
      host_service_seen[$key]=1
      host_service_list["$host"]+="${host_service_list[$host]:+$'\n'}${service}"
      host_service_changed[$key]=0
      host_service_failed[$key]=0
      host_service_unreachable[$key]=0
    fi
    host_service_changed[$key]=$((host_service_changed[$key] + changed))
    host_service_failed[$key]=$((host_service_failed[$key] + failed))
    host_service_unreachable[$key]=$((host_service_unreachable[$key] + unreachable))
  done < "$DEPLOY_STATUS_FILE"
fi

host_result_line() {
  local host="$1"
  local service key details="" marker="✅" has_record=0 has_unreachable=0
  local changed failed unreachable

  if contains_word "$UNREACHABLE" "$host"; then
    printf '⚠️ %s · SSH 不可达' "$host"
    return
  fi

  while IFS= read -r service; do
    [ -n "$service" ] || continue
    key="${host}"$'\034'"${service}"
    [ -n "${host_service_seen[$key]+set}" ] || continue
    has_record=1
    changed="${host_service_changed[$key]}"
    failed="${host_service_failed[$key]}"
    unreachable="${host_service_unreachable[$key]}"
    if [ "$unreachable" -gt 0 ]; then
      has_unreachable=1
      continue
    fi
    if [ "$failed" -gt 0 ]; then
      marker="❌"
      details+="${details:+, }${service} · failed=${failed}"
    elif [ "$changed" -gt 0 ]; then
      details+="${details:+, }${service} · changed=${changed}"
    else
      details+="${details:+, }${service} · 无变更"
    fi
  done <<< "${host_service_list[$host]:-}"

  if [ "$has_unreachable" -eq 1 ]; then
    printf '⚠️ %s · SSH 不可达' "$host"
  elif [ "$has_record" -eq 0 ]; then
    if [ "$PLAYBOOK_RC" != "" ] && [ "$PLAYBOOK_RC" != "0" ] && [ "$PLAYBOOK_RC" != "3" ]; then
      printf '❌ %s · 未执行' "$host"
    else
      printf '⚪ %s · 未获取到结果' "$host"
    fi
  else
    printf '%s %s · %s' "$marker" "$host" "$details"
  fi
}

result_text=""
case "$PLAYBOOK_RC" in
  0)
    if [ -n "$UNREACHABLE" ]; then
      result_text="流水线完成（存在不可达主机）"
    else
      result_text="流水线成功"
    fi
    ;;
  3) result_text="流水线完成（存在不可达主机）" ;;
  "") result_text="未执行或结果未知" ;;
  *) result_text="流水线失败（rc=$PLAYBOOK_RC）" ;;
esac

case "$PLAYBOOK_RC" in
  0)
    if [ -n "$UNREACHABLE" ]; then
      bark_result_text="⚠️ 部署完成，但存在不可达主机"
    else
      bark_result_text="✅ 部署成功"
    fi
    ;;
  3) bark_result_text="⚠️ 部署完成，但存在不可达主机" ;;
  "") bark_result_text="⚪ 未执行或结果未知" ;;
  *) bark_result_text="❌ 部署失败" ;;
esac

target_count=$(printf '%s\n' "$target_hosts" | sed '/^$/d' | wc -l | tr -d ' ')
if [ -n "$LIMIT" ] && [ "$LIMIT" != "<all>" ]; then
  deploy_mode="定向节点收敛"
else
  deploy_mode="全量部署"
fi

if [ -n "$DEPLOY_PLAN" ] \
  && service_scope=$(jq -r 'reduce .targets[]?.tag as $tag ([]; if index($tag) then . else . + [$tag] end) | join(", ")' <<< "$DEPLOY_PLAN" 2>/dev/null) \
  && [ -n "$service_scope" ]; then
  :
elif [ -z "$TAGS" ] || [ "$TAGS" = "<all>" ]; then
  service_scope="全部服务"
else
  service_scope=$(printf '%s' "$TAGS" | sed 's/,/, /g')
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
  echo "> 服务列为**计划范围**（tags ∩  inventory 组），不是 per-task 成功。"
  echo "> 「结果」= SSH 预检 + 整次 playbook 退出码；nft 无 CAP 等 soft-skip 不会单独标红，有能力却 apply 失败会使流水线失败。"
  echo ""
  echo "## 节点操作明细"
  echo ""
  echo "| 节点 | SSH | Python | SmartDNS | sing-box | nft | probe | 结果 |"
  echo "|---|---|---|---|---|---|---|---|"
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    ssh_state=$(host_status "$host")
    if [ "$ssh_state" = "不可达" ]; then
      row_result="不可达"
    elif [ "$PLAYBOOK_RC" != "" ] && [ "$PLAYBOOK_RC" != "0" ] && [ "$PLAYBOOK_RC" != "3" ]; then
      row_result="流水线失败"
    elif [ "$ssh_state" = "未检查" ]; then
      row_result="未检查"
    else
      row_result="流水线成功"
    fi
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$host" "$ssh_state" \
      "$( [ "$ssh_state" = "不可达" ] && printf '不可达' || printf '计划' )" \
      "$(service_status "$host" smartdns "$smartdns_hosts")" \
      "$(service_status "$host" singbox "$singbox_hosts")" \
      "$(service_status "$host" nft "$nft_hosts")" \
      "$(service_status "$host" probe "$probe_hosts")" \
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

if [ -n "$BARK_SUMMARY_FILE" ]; then
  commit_title="${COMMIT_TITLE:-私有仓提交标题未知}"
  commit_title="${commit_title//$'\n'/ }"
  commit_title="${commit_title//$'\r'/ }"
  commit_title="${commit_title//$'\t'/ }"
  {
    echo "Ansible 部署"
    echo "状态: ${bark_result_text} · 部署内容: ${service_scope}"
    echo "私有仓提交: ${commit_title}"
    echo ""
    echo "主机结果:"
    while IFS= read -r host; do
      [ -z "$host" ] && continue
      printf '%s\n' "$(host_result_line "$host")"
    done <<< "$target_hosts"
  } > "$BARK_SUMMARY_FILE"
fi

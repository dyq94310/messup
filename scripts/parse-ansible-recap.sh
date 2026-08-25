#!/usr/bin/env bash
# Parse Ansible PLAY RECAP lines into compact, tab-separated host results.
# Output: service<TAB>host<TAB>changed<TAB>failed<TAB>unreachable<TAB>skipped
set -euo pipefail

LOG_FILE="${1:?Ansible output file is required}"
SERVICE="${2:-all}"

[ -r "$LOG_FILE" ] || exit 0

declare -A CHANGED FAILED UNREACHABLE SKIPPED

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

while IFS= read -r line; do
  # Ansible may emit ANSI color sequences even when recap is redirected through tee.
  line=$(printf '%s' "$line" | sed $'s/\033\\[[0-9;]*m//g')
  if [[ "$line" =~ ^[[:space:]]*([^:]+)[[:space:]]*:[[:space:]]+ok=([0-9]+)[[:space:]]+changed=([0-9]+)[[:space:]]+unreachable=([0-9]+)[[:space:]]+failed=([0-9]+)[[:space:]]+skipped=([0-9]+) ]]; then
    host=$(trim "${BASH_REMATCH[1]}")
    [ -n "$host" ] || continue
    CHANGED["$host"]=$((
      ${CHANGED["$host"]:-0} + BASH_REMATCH[3]
    ))
    FAILED["$host"]=$((
      ${FAILED["$host"]:-0} + BASH_REMATCH[5]
    ))
    UNREACHABLE["$host"]=$((
      ${UNREACHABLE["$host"]:-0} + BASH_REMATCH[4]
    ))
    SKIPPED["$host"]=$((
      ${SKIPPED["$host"]:-0} + BASH_REMATCH[6]
    ))
  fi
done < "$LOG_FILE"

for host in "${!CHANGED[@]}"; do
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$SERVICE" \
    "$host" \
    "${CHANGED[$host]}" \
    "${FAILED[$host]}" \
    "${UNREACHABLE[$host]}" \
    "${SKIPPED[$host]}"
done | sort -t $'\t' -k2,2 -k1,1

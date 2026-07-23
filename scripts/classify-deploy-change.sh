#!/usr/bin/env bash
# Classify public-repository changes before any private checkout or SSH setup.
set -euo pipefail

OLD_REF="${1:-HEAD~1}"
NEW_REF="${2:-HEAD}"
EVENT_NAME="${EVENT_NAME:-push}"
INPUT_TAGS="${INPUT_TAGS:-}"
INPUT_LIMIT="${INPUT_LIMIT:-}"
DISPATCH_TAGS="${DISPATCH_TAGS:-}"
DISPATCH_LIMIT="${DISPATCH_LIMIT:-}"

TAGS=""
LIMIT=""
MODE="skip"
DEPLOY_REQUIRED="false"
APPROVAL_REQUIRED="false"
REASON=""

if [ "$EVENT_NAME" = "repository_dispatch" ]; then
  TAGS="$DISPATCH_TAGS"
  LIMIT="$DISPATCH_LIMIT"
  MODE="private-config-update"
  DEPLOY_REQUIRED="true"
  REASON="private repository requested deployment"
elif [ "$EVENT_NAME" = "workflow_dispatch" ]; then
  TAGS="$INPUT_TAGS"
  LIMIT="$INPUT_LIMIT"
  MODE="manual"
  DEPLOY_REQUIRED="true"
  REASON="manual workflow dispatch"
else
  changed=$(git diff --name-only "$OLD_REF" "$NEW_REF" 2>/dev/null || true)
  if [ -z "$changed" ]; then
    REASON="no diff available"
  else
    need_sb=0
    need_sd=0
    need_nft=0
    need_approval=0
    reasons=()
    while IFS= read -r file; do
      [ -z "$file" ] && continue
      case "$file" in
        playbooks/01-deploy-singbox.yml|templates/singbox.openrc.j2|templates/singbox.service.j2)
          need_sb=1 ;;
        playbooks/02-deploy-smartdns.yml|templates/smartdns.openrc.j2|templates/smartdns.service.j2)
          need_sd=1 ;;
        playbooks/03-deploy-nft.yml|templates/messup-nft.openrc.j2|templates/messup-nft.env.j2|templates/messup-nft.service.j2)
          need_nft=1 ;;
        scripts/render-deploy-summary.sh)
          ;;
        README.md|*.md|**/*.md|LICENSE|.gitignore)
          ;;
        *)
          need_approval=1
          reasons+=("$file")
          ;;
      esac
    done <<< "$changed"

    if [ "$need_approval" = "1" ]; then
      MODE="approval-required"
      APPROVAL_REQUIRED="true"
      DEPLOY_REQUIRED="true"
      REASON="unclassified or infrastructure change: $(IFS=,; printf '%s' "${reasons[*]}")"
    elif [ "$need_sb" = "1" ] || [ "$need_sd" = "1" ] || [ "$need_nft" = "1" ]; then
      parts=()
      [ "$need_sb" = "1" ] && parts+=(singbox)
      [ "$need_sd" = "1" ] && parts+=(smartdns)
      [ "$need_nft" = "1" ] && parts+=(nft)
      TAGS=$(IFS=,; printf '%s' "${parts[*]}")
      MODE="service-wide"
      DEPLOY_REQUIRED="true"
      REASON="known business service change"
    else
      MODE="skip"
      REASON="documentation or deployment-summary-only change"
    fi
  fi
fi

printf 'tags=%s\nlimit=%s\nmode=%s\ndeploy_required=%s\napproval_required=%s\nreason=%s\n' \
  "$TAGS" "$LIMIT" "$MODE" "$DEPLOY_REQUIRED" "$APPROVAL_REQUIRED" "$REASON"

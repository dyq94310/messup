#!/bin/sh
set -eu

LOCK_DIR=/run/messup-apk.lock
LOCK_TIMEOUT=${MESSUP_APK_LOCK_TIMEOUT:-30}
KILL_GRACE=${MESSUP_APK_KILL_GRACE:-3}
COMMAND_TIMEOUT=${MESSUP_APK_COMMAND_TIMEOUT:-1800}
APK_DB_LOCK=${MESSUP_APK_DB_LOCK:-/lib/apk/db/lock}
MODE=${1:-}
shift || true

case "$MODE" in
  install|update)
    ;;
  *)
    printf '%s\n' "usage: $0 {install|update} [packages...]" >&2
    exit 2
    ;;
esac

now_s() {
  date +%s
}

is_self_pid() {
  [ "$1" = "$$" ] || [ "$1" = "1" ]
}

apk_lock_error() {
  case "$1" in
    *"Unable to lock database"*|*"Failed to open apk database"*|*"Resource temporarily unavailable"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_apk_lock_pids() {
  _pids=""
  for _dir in /proc/[0-9]*; do
    _pid=${_dir#/proc/}
    if is_self_pid "$_pid"; then
      continue
    fi
    [ -d "$_dir/fd" ] || continue
    for _fd in "$_dir"/fd/*; do
      _target=$(readlink "$_fd" 2>/dev/null) || continue
      if [ "$_target" = "$APK_DB_LOCK" ]; then
        case " $_pids " in
          *" $_pid "*) ;;
          *) _pids="${_pids} ${_pid}" ;;
        esac
        break
      fi
    done
  done
  if [ -r /proc/locks ] && [ -e "$APK_DB_LOCK" ]; then
    _inode=$(stat -c %i "$APK_DB_LOCK" 2>/dev/null || true)
    if [ -n "$_inode" ]; then
      while read -r _id _cls _type _mode _lpid _devino _; do
        case "$_devino" in
          *:"$_inode")
            if is_self_pid "$_lpid"; then
              continue
            fi
            case " $_pids " in
              *" $_lpid "*) ;;
              *) _pids="${_pids} ${_lpid}" ;;
            esac
            ;;
        esac
      done < /proc/locks
    fi
  fi
  printf '%s\n' "${_pids# }"
}

kill_pids() {
  _pids=$1
  [ -n "$_pids" ] || return 0
  printf '%s\n' "killing apk lock holders:${_pids}" >&2
  for _pid in $_pids; do
    kill -TERM "$_pid" 2>/dev/null || true
  done
  sleep "$KILL_GRACE"
  for _pid in $_pids; do
    if kill -0 "$_pid" 2>/dev/null; then
      kill -KILL "$_pid" 2>/dev/null || true
    fi
  done
}

kill_apk_lock_holders() {
  kill_pids "$(list_apk_lock_pids)"
}

steal_messup_lock() {
  _owner=""
  if [ -r "$LOCK_DIR/pid" ]; then
    _owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  fi
  if [ -n "$_owner" ] && ! is_self_pid "$_owner"; then
    kill_pids "$_owner"
  fi
  kill_apk_lock_holders
  rm -rf "$LOCK_DIR"
}

start=$(now_s)
stolen=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  owner=""
  if [ -r "$LOCK_DIR/pid" ]; then
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  fi
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    continue
  fi
  if [ "$(( $(now_s) - start ))" -ge "$LOCK_TIMEOUT" ]; then
    if [ "$stolen" -eq 1 ]; then
      printf '%s\n' "apk lock still held after killing holders" >&2
      exit 75
    fi
    steal_messup_lock
    stolen=1
    continue
  fi
  sleep 5
done

printf '%s\n' "$$" > "$LOCK_DIR/pid"
cleanup() {
  rm -rf "$LOCK_DIR"
}
trap cleanup EXIT HUP INT TERM

run_apk() {
  _rc=0
  case "$MODE" in
    install)
      timeout "$COMMAND_TIMEOUT" apk add --no-cache --update-cache "$@" || _rc=$?
      ;;
    update)
      timeout "$COMMAND_TIMEOUT" sh -c 'apk update && apk upgrade --no-cache' || _rc=$?
      ;;
  esac
  return "$_rc"
}

wait_start=$(now_s)
killed=0
while :; do
  apk_rc=0
  apk_output=$(run_apk "$@" 2>&1) || apk_rc=$?
  if [ -n "$apk_output" ]; then
    printf '%s\n' "$apk_output"
  fi
  if [ "$apk_rc" -eq 0 ]; then
    exit 0
  fi
  if ! apk_lock_error "$apk_output"; then
    exit "$apk_rc"
  fi
  if [ "$killed" -eq 1 ]; then
    printf '%s\n' "apk lock still held after killing holders" >&2
    exit 75
  fi
  if [ "$(( $(now_s) - wait_start ))" -ge "$LOCK_TIMEOUT" ]; then
    kill_apk_lock_holders
    killed=1
    continue
  fi
  sleep 5
done

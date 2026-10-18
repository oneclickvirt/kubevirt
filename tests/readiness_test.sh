#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2329 # Test doubles invoked by the extracted runtime helper.
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
source <(awk '$0=="wait_for_ssh() {" {p=1} p {print} p && /^}$/ {exit}' "$root/scripts/onevm.sh")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export TMPDIR="$fixture"
_step() { :; }; _info() { :; }; _error() { return 1; }
# shellcheck disable=SC2329 # Called by the extracted runtime helper.
get_host_ip() { echo 192.0.2.1; }
sleep() { SECONDS=$((SECONDS + $1)); }
attempt=0
# Only a successful authenticated guest command is ready; an open TCP socket
# never invokes this success path. Check that the password is only in env.
# shellcheck disable=SC2329 # Called by the extracted runtime helper.
timeout() {
    attempt=$((attempt + 1))
    [[ "$SSHPASS" == 'literal-sensitive-password' ]] || return 99
    [[ "$*" != *literal-sensitive-password* ]] || return 99
    [[ "$*" == *'ssh -n '* ]] || return 99
    [[ "$*" == *'cloud-init status --wait'* ]] || return 99
    [[ "$*" == *'PreferredAuthentications=password'* ]] || return 99
    (( attempt >= 2 ))
}
# shellcheck disable=SC2034 # Used by the extracted helper.
PASSWORD=literal-sensitive-password SSH_PORT=25000 SSH_READY_TIMEOUT=12
SECONDS=0
wait_for_ssh >/dev/null
[[ "$attempt" == 2 ]]
attempt=0
# shellcheck disable=SC2329 # Called by the extracted runtime helper.
timeout() { attempt=$((attempt + 1)); return 1; }
SECONDS=0
if wait_for_ssh >/dev/null 2>&1; then echo 'authentication failure was accepted' >&2; exit 1; fi
[[ "$SECONDS" -eq 12 && "$attempt" -eq 3 ]]
[[ -z "$(find "$fixture" -type f -print -quit)" ]]
# shellcheck disable=SC2329 # Called by the extracted runtime helper.
get_host_ip() { echo '<宿主机IP>'; }
if wait_for_ssh >/dev/null 2>&1; then echo 'unknown host was accepted' >&2; exit 1; fi
echo 'KubeVirt readiness: delayed authentication, bounded failure and secret-free arguments passed'

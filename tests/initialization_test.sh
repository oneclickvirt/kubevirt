#!/usr/bin/env bash
# Fault injection only: selected functions run against mock commands.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/kubevirtinstall.sh"
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer")
}
_green() { :; }
_yellow() { :; }
_red() { :; }
_blue() { :; }
_info() { :; }
_warn() { :; }
_step() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

load_function configure_storage
mock_classes='{"items":[]}'
mock_patch_fail=false mock_ready=true mock_patches=0
kubectl() {
    case "$*" in
        'get storageclass -o json') printf '%s\n' "$mock_classes" ;;
        'patch storageclass local-path '*)
            mock_patches=$((mock_patches + 1)); ! $mock_patch_fail ;;
        '-n kube-system rollout status deployment/local-path-provisioner --timeout=180s') $mock_ready ;;
        *) fail "Unexpected kubectl command: $*" ;;
    esac
}
if configure_storage; then fail 'missing required local-path must fail'; fi
mock_classes='{"items":[{"metadata":{"name":"local-path"},"provisioner":"rancher.io/local-path"}]}'
configure_storage || fail 'ready local-path should succeed'
[[ "$mock_patches" == 1 ]] || fail 'missing default class should be set'
mock_patch_fail=true
if configure_storage; then fail 'failed default annotation must propagate'; fi
mock_patch_fail=false mock_ready=false
if configure_storage; then fail 'unavailable provisioner must fail'; fi
mock_ready=true mock_patches=0
mock_classes=$(jq '.items += [{"metadata":{"name":"custom","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}},"provisioner":"example.com/custom"}]' <<< "$mock_classes")
configure_storage || fail 'existing custom default must be preserved alongside local-path'
[[ "$mock_patches" == 0 ]] || fail 'custom default class must not be overridden'
source_text=$(<"$installer")
grep -Fq 'use_local_or_download "${KV_BASE}/kubevirt-operator.yaml" "/tmp/kubevirt-operator.yaml" "KubeVirt Operator" "$KV_OPERATOR_LOCAL" || return 1' <<<"$source_text" ||
    fail 'KubeVirt operator download/copy failures must propagate'
grep -Fq 'use_local_or_download "${KV_BASE}/kubevirt-cr.yaml" "/tmp/kubevirt-cr.yaml" "KubeVirt CR" "$KV_CR_LOCAL" || return 1' <<<"$source_text" ||
    fail 'KubeVirt CR download/copy failures must propagate'
grep -Fq 'cp "$VIRTCTL_BINARY" /usr/local/bin/virtctl || return 1' <<<"$source_text" ||
    fail 'virtctl local copy failures must propagate'
printf 'KubeVirt installation fault-injection tests passed (5 scenarios)\n'

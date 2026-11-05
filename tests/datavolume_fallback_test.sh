#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for name in next_image_import_source wait_for_datavolume; do
    eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$repo_root/scripts/onevm.sh")"
done
_info() { :; }; _step() { :; }; _warn() { :; }
_error() { echo "$*" >&2; return 1; }
cleanup_failed_vm_resources() { echo 'unexpected VM cleanup' >&2; exit 1; }
sleep() { :; }
create_datavolume() { recreated=$((recreated + 1)); }
VM_NAME=test-vm; NS=test; YELLOW=''; NC=''
DUFS_MIRROR_BASE=https://www.spiritlhl.com
DUFS_IMPORT_PRIMARY_IDLE_TIMEOUT=5
kubectl() {
    if [[ "$*" == *status.phase* ]]; then
        if ((IMAGE_CANDIDATE_INDEX > 0)); then printf Succeeded
        elif [[ "$mode" == failed ]]; then printf Failed
        else printf ImportInProgress; fi
    elif [[ "$*" == *status.progress* ]]; then printf '0.0%%'
    fi
}
for mode in failed stalled; do
    IMAGE_URL_CANDIDATES=(https://www.spiritlhl.com/pve/kvm/debian/amd64/debian12.qcow2 https://cdn.invalid/image https://github.com/oneclickvirt/pve_kvm_images/releases/download/debian/debian12.qcow2 https://cloud.debian.org/image)
    IMAGE_CANDIDATE_INDEX=0; IMAGE_URL=${IMAGE_URL_CANDIDATES[0]}; recreated=0
    wait_for_datavolume >/dev/null
    [[ "$IMAGE_URL" == https://cdn.invalid/image && "$recreated" == 1 ]]
done
printf 'KubeVirt failed/stalled primary import fallback passed\n'

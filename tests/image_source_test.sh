#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for name in _find_in_pve_kvm_images _find_in_kvm_images; do
    eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$repo_root/scripts/onevm.sh")"
done
_info() { :; }
CDN_PREFIX=""
calls=()
accepted=""
_url_accessible() { calls+=("$1"); [[ "$1" == "$accepted" ]]; }
assert_eq() { [[ "$1" == "$2" ]] || { printf 'mismatch: %s != %s\n' "$1" "$2" >&2; exit 1; }; }
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu2404.qcow2"
_find_in_pve_kvm_images ubuntu24 ubuntu
assert_eq "$IMAGE_URL" "$accepted"; assert_eq "${calls[0]}" "$accepted"
CDN_PREFIX="https://cdn.invalid/"; calls=()
_find_in_pve_kvm_images ubuntu24 ubuntu
assert_eq "${#calls[@]}" 2; assert_eq "${calls[1]}" "$accepted"
accepted="https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/debian12.qcow2"
CDN_PREFIX=""; calls=(); _find_in_pve_kvm_images debian12 debian
assert_eq "$IMAGE_URL" "$accepted"
for entry in 'debian12:v2.0' 'debian9:v1.1' 'opensuse-leap-15:v1.0'; do
    ver=${entry%:*}; tag=${entry#*:}
    accepted="https://github.com/oneclickvirt/kvm_images/releases/download/$tag/$ver.qcow2"
    calls=(); _find_in_kvm_images "$ver"
    assert_eq "$IMAGE_URL" "$accepted"
done
calls=(); if _find_in_kvm_images ubuntu24; then exit 1; fi
assert_eq "${#calls[@]}" 0
accepted=unavailable; if _find_in_pve_kvm_images debian12 debian; then exit 1; fi
echo 'KubeVirt published image source and fallback tests passed'

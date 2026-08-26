#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
onevm="$repo_root/scripts/onevm.sh"
updater="$repo_root/scripts/update-port-rules.sh"
installer="$repo_root/kubevirtinstall.sh"

extract_function() {
    local file="$1" name="$2"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$file"
}

assert_equals() {
    local actual="$1" expected="$2" label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf '%s = %q, want %q\n' "$label" "$actual" "$expected" >&2
        exit 1
    fi
}

if ! grep -Fq 'accept_ra = 2' "$installer"; then
    printf 'KubeVirt IPv6 forwarding must preserve router advertisements on its uplink\n' >&2
    exit 1
fi

# shellcheck disable=SC1090 # The test intentionally loads the address selector.
source <(extract_function "$onevm" select_vm_ip_addresses)

VM_IP=""
VM_IP6="-"
select_vm_ip_addresses 'fd42:122::42' '10.42.0.42' 'fd42:122::42'
assert_equals "$VM_IP" '10.42.0.42' 'IPv4 selected from IPv6-first VMI list'
assert_equals "$VM_IP6" 'fd42:122::42' 'IPv6 selected from IPv6-first VMI list'

select_vm_ip_addresses 'fd42:122::43'
assert_equals "$VM_IP" '' 'IPv6-only VMI IPv4 field'
assert_equals "$VM_IP6" 'fd42:122::43' 'IPv6-only VMI IPv6 field'

# update-port-rules.sh must make the same family-aware choice after a VMI
# restart, otherwise a valid IPv6-first VMI becomes an invalid IPv4 DNAT rule.
# shellcheck disable=SC1090 # The test intentionally loads one updater function.
source <(extract_function "$updater" update_vm_rules)
# shellcheck disable=SC2034 # Read by the dynamically sourced updater function.
NS='kubevirt-vms'
validate_vm_name() { :; }
captured_record=''
# shellcheck disable=SC2329 # Invoked by the dynamically sourced updater function.
apply_vm_rule_record() {
    captured_record="$*"
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced updater function.
kubectl() {
    case "$*" in
        'get vm vm6 -n kubevirt-vms -o json')
            printf '%s\n' '{"metadata":{"name":"vm6","annotations":{"kubevirt.io/ssh-port":"25000","kubevirt.io/start-port":"0","kubevirt.io/end-port":"0"}}}'
            ;;
        'get vmi vm6 -n kubevirt-vms -o json')
            printf '%s\n' '{"status":{"interfaces":[{"ipAddress":"fd42:122::42","ipAddresses":["fd42:122::42","10.42.0.42"]}]}}'
            ;;
        *)
            printf 'unexpected kubectl invocation: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
update_vm_rules vm6
assert_equals "$captured_record" 'vm6 10.42.0.42 fd42:122::42 25000 0 0' 'restart rule address selection'

# shellcheck disable=SC1090 # The test intentionally loads the bulk updater.
source <(extract_function "$updater" update_all_vms)
_info() { :; }
_warn() { :; }
captured_record=''
apply_vm_rule_record() {
    captured_record="$*"
}
kubectl() {
    case "$*" in
        'get vm -n kubevirt-vms -o json')
            printf '%s\n' '{"items":[{"metadata":{"name":"vm6","annotations":{"kubevirt.io/ssh-port":"25000","kubevirt.io/start-port":"0","kubevirt.io/end-port":"0"}}}]}'
            ;;
        'get vmi -n kubevirt-vms -o json')
            printf '%s\n' '{"items":[{"metadata":{"name":"vm6"},"status":{"interfaces":[{"ipAddress":"fd42:122::42","ipAddresses":["fd42:122::42","10.42.0.42"]}]}}]}'
            ;;
        *)
            printf 'unexpected bulk kubectl invocation: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
update_all_vms
assert_equals "$captured_record" 'vm6 10.42.0.42 fd42:122::42 25000 0 0' 'bulk restart rule address selection'

# shellcheck disable=SC1091,SC1090 # firewall.sh is a function library loaded from a computed path.
source "$repo_root/scripts/firewall.sh"
if ! _fw_validate_record vm6 - 25000 0 0 'fd42:122::42'; then
    printf 'IPv6-only firewall record was rejected\n' >&2
    exit 1
fi
if _fw_validate_record vm6 'fd42:122::42' 25000 0 0 -; then
    printf 'IPv6 address in the IPv4 field was accepted without normalization\n' >&2
    exit 1
fi

KUBEVIRT_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$KUBEVIRT_TEST_DIR"' EXIT
KUBEVIRT_PORT_RULES="$KUBEVIRT_TEST_DIR/port-rules.conf"
KUBEVIRT_NFT_CALLS="$KUBEVIRT_TEST_DIR/nft-calls"
printf '%s\n' 'vmdual 10.42.0.42 25000 30000 30001 fd42:122::42' > "$KUBEVIRT_PORT_RULES"
printf '%s\n' 'vm6 - 25001 0 0 fd42:122::43' >> "$KUBEVIRT_PORT_RULES"
printf '%s\n' 'vmlegacy fd42:122::44 25002 0 0 -' >> "$KUBEVIRT_PORT_RULES"
nft() {
    printf '%s\n' "$*" >> "$KUBEVIRT_NFT_CALLS"
}
_nft_rebuild

if ! grep -Fq 'dnat ip to 10.42.0.42:22' "$KUBEVIRT_NFT_CALLS"; then
    printf 'dual-stack VMI is missing its IPv4 DNAT rule\n' >&2
    exit 1
fi
if ! grep -Fq 'dnat ip6 to [fd42:122::43]:22' "$KUBEVIRT_NFT_CALLS"; then
    printf 'IPv6-only VMI is missing its IPv6 DNAT rule\n' >&2
    exit 1
fi
if grep -Fq 'dnat ip to fd42:122::' "$KUBEVIRT_NFT_CALLS"; then
    printf 'IPv6 address was written into an IPv4 DNAT rule\n' >&2
    exit 1
fi
if ! grep -Fq 'dnat ip6 to [fd42:122::44]:22' "$KUBEVIRT_NFT_CALLS"; then
    printf 'legacy IPv6-first record was not repaired while rebuilding rules\n' >&2
    exit 1
fi

printf 'kubevirt IPv6 address selection tests passed\n'

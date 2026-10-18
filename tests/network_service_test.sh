#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329 # Extracted helpers use test fixtures and mocks.
set -euo pipefail
# shellcheck disable=SC1090,SC2329 # Extracted production helpers invoke these test doubles.
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
load_function() { source <(awk -v name="$1" '$0==name "() {" {p=1} p {print} p && /^}$/ {exit}' "$2"); }
_info() { :; }; _step() { :; }; _error() { return 1; }
load_function configure_k3s_network "$root/kubevirtinstall.sh"
ip() {
    case "$*" in
      '-j -6 route show default') echo "$fixture_route6" ;;
      '-j -6 addr show dev wan6 scope global') echo '[{"addr_info":[{"scope":"global","local":"2001:db8::2"}]}]' ;;
      '-j -4 route show default') echo '[{"dev":"wan4"}]' ;;
      '-j -4 addr show dev wan4 scope global') echo '[{"addr_info":[{"scope":"global","local":"192.0.2.2"}]}]' ;;
      *) echo "unexpected ip invocation: $*" >&2; return 1 ;;
    esac
}
fixture_route6='[]' K3S_IP_FAMILY=auto
configure_k3s_network
[[ ${#K3S_NETWORK_ARGS[@]} == 0 ]]
K3S_IP_FAMILY=dualstack
if configure_k3s_network; then echo 'missing IPv6 route accepted' >&2; exit 1; fi
fixture_route6='[{"dev":"wan6","metric":100}]'
configure_k3s_network
[[ "${K3S_NETWORK_ARGS[*]}" == *'--node-ip=192.0.2.2,2001:db8::2'* ]]
[[ "${K3S_NETWORK_ARGS[*]}" == *'--flannel-ipv6-masq'* ]]
K3S_IP_FAMILY=ipv4
configure_k3s_network
[[ ${#K3S_NETWORK_ARGS[@]} == 0 ]]
load_function vm_primary_mac "$root/scripts/onevm.sh"
VM_NAME='fixture-vm'
mac=$(vm_primary_mac)
[[ "$mac" =~ ^02(:[0-9a-f]{2}){5}$ ]]
[[ "$mac" == "$(vm_primary_mac)" ]]
# Legacy ENI uses the config key as the actual device name. No wildcard-only match.
network_block=$(sed -n '/network_data="version: 1/,/type: dhcp4/p' "$root/scripts/onevm.sh")
[[ "$network_block" == *'mac_address:'* && "$network_block" == *'name: eth0'* ]]
load_function setup_port_forward "$root/scripts/onevm.sh"
load_function fw_setup_vm_service "$root/scripts/firewall.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
NS=fixture VM_NAME=testvm SSH_PORT=25021 START_PORT=35201 END_PORT=35203
fail_apply=false
kubectl() {
  case "$*" in
    'get vm testvm -n fixture -o jsonpath={.metadata.uid}') echo fixture-uid ;;
    'apply -f -') cat > "$fixture/service.json"; ! $fail_apply ;;
    *) echo "unexpected kubectl: $*" >&2; return 1 ;;
  esac
}
fw_remove_vm() { [[ "$1" == testvm ]]; touch "$fixture/removed"; }
setup_port_forward
jq -e '.spec.selector["kubevirt.io/vm"] == "testvm" and .spec.ipFamilyPolicy == "PreferDualStack" and (.spec.ports|length)==7 and .metadata.ownerReferences[0].uid=="fixture-uid" and .spec.ports[0].nodePort==25021' "$fixture/service.json" >/dev/null
[[ -f "$fixture/removed" ]]
rm "$fixture/removed"
fail_apply=true
if setup_port_forward; then echo 'service failure ignored' >&2; exit 1; fi
[[ ! -f "$fixture/removed" ]]
echo 'KubeVirt network/Service tests: separate uplinks, route fallback, stable selector, TCP/UDP ports and apply failure passed'

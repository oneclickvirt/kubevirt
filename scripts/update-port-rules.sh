#!/bin/bash
# =====================================================================
# KubeVirt VM IP 变更后更新端口转发规则
# 当 VM 重启后 IP 可能变化，此脚本更新 iptables DNAT 规则
# 用法: ./update-port-rules.sh <vmname>
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"

# ===== 加载防火墙库 =====
FIREWALL_LIB="/usr/local/lib/kubevirt/firewall.sh"
if [ ! -f "$FIREWALL_LIB" ]; then
    _error "防火墙库未找到: $FIREWALL_LIB\n请先运行安装脚本"
fi
source "$FIREWALL_LIB"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi
}

ensure_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        return 0
    fi
    if command -v k3s >/dev/null 2>&1; then
        kubectl() { k3s kubectl "$@"; }
        return 0
    fi
    _error "未找到 kubectl/k3s，请先安装 KubeVirt 环境"
}

ensure_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        _error "未找到 jq，请先安装依赖或重新运行安装脚本"
    fi
}

validate_vm_name() {
    local vm_name="$1"
    if ! echo "$vm_name" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'; then
        _error "VM 名称只允许小写字母、数字和连字符，且不能以连字符开头或结尾：${vm_name}"
    fi
}

apply_vm_rule_record() {
    local vm_name="$1" new_ip="$2" new_ip6="${3:--}" ssh_port="$4" start_port="${5:-0}" end_port="${6:-0}"

    new_ip="${new_ip:--}"
    new_ip6="${new_ip6:--}"
    if { [ "$new_ip" = "-" ] || [ "$new_ip" = "null" ]; } && \
       { [ "$new_ip6" = "-" ] || [ "$new_ip6" = "null" ]; }; then
        _warn "无法获取虚拟机 $vm_name 的 IP，虚拟机可能未运行"
        return 1
    fi

    if [ -z "$ssh_port" ]; then
        _warn "虚拟机 $vm_name 没有 SSH 端口注解，跳过"
        return 1
    fi

    _info "更新 $vm_name 的端口转发规则（IPv4: $new_ip，IPv6: $new_ip6，后端：$(fw_backend_name)）..."

    if ! fw_add_vm "$vm_name" "$new_ip" "$ssh_port" "$start_port" "$end_port" "$new_ip6"; then
        _warn "端口转发规则更新失败：$vm_name"
        return 1
    fi

    _info "规则更新成功：$vm_name（IPv4: $new_ip，IPv6: $new_ip6，SSH: $ssh_port, 端口: ${start_port}-${end_port}）"
}

update_vm_rules() {
    local vm_name="$1"
    local vm_json vmi_json record

    validate_vm_name "$vm_name"

    if ! vm_json=$(kubectl get vm "$vm_name" -n "$NS" -o json 2>/dev/null); then
        _error "虚拟机 $vm_name 不存在"
    fi
    vmi_json=$(kubectl get vmi "$vm_name" -n "$NS" -o json 2>/dev/null || printf '{}\n')

    record=$(jq -n -r --argjson vm "$vm_json" --argjson vmi "$vmi_json" '
        def interface_addresses:
          [ .ipAddresses[]?, .ipAddress? ]
          | map(select(type == "string" and . != "" and . != "null"))
          | unique;
        def first_ipv4:
          [ interface_addresses[] | select(contains(":") | not) ][0] // "-";
        def first_ipv6:
          [ interface_addresses[] | select(contains(":")) ][0] // "-";
        [
          ($vm.metadata.name // ""),
          (($vmi.status.interfaces[0] // {}) | first_ipv4),
          (($vmi.status.interfaces[0] // {}) | first_ipv6),
          ($vm.metadata.annotations["kubevirt.io/ssh-port"] // ""),
          ($vm.metadata.annotations["kubevirt.io/start-port"] // "0"),
          ($vm.metadata.annotations["kubevirt.io/end-port"] // "0")
        ] | @tsv
    ')

    IFS=$'\t' read -r vm_name new_ip new_ip6 ssh_port start_port end_port <<< "$record"
    apply_vm_rule_record "$vm_name" "$new_ip" "$new_ip6" "$ssh_port" "$start_port" "$end_port"
}

# 更新所有 VM 规则
update_all_vms() {
    _info "更新所有运行中虚拟机的端口转发规则..."
    local vm_json vmi_json records vmi_count
    vm_json=$(kubectl get vm -n "$NS" -o json 2>/dev/null || printf '{"items":[]}\n')
    vmi_json=$(kubectl get vmi -n "$NS" -o json 2>/dev/null || printf '{"items":[]}\n')
    vmi_count=$(printf '%s' "$vmi_json" | jq '.items | length')

    if [ "$vmi_count" -eq 0 ]; then
        _warn "没有运行中的虚拟机实例"
        return
    fi

    records=$(printf '%s' "$vmi_json" | jq -r --argjson vms "$vm_json" '
        def interface_addresses:
          [ .ipAddresses[]?, .ipAddress? ]
          | map(select(type == "string" and . != "" and . != "null"))
          | unique;
        def first_ipv4:
          [ interface_addresses[] | select(contains(":") | not) ][0] // "-";
        def first_ipv6:
          [ interface_addresses[] | select(contains(":")) ][0] // "-";
        .items[]? as $vmi |
        ($vmi.metadata.name // "") as $name |
        ([ $vms.items[]? | select(.metadata.name == $name) ][0] // {}) as $vm |
        [
          $name,
          (($vmi.status.interfaces[0] // {}) | first_ipv4),
          (($vmi.status.interfaces[0] // {}) | first_ipv6),
          ($vm.metadata.annotations["kubevirt.io/ssh-port"] // ""),
          ($vm.metadata.annotations["kubevirt.io/start-port"] // "0"),
          ($vm.metadata.annotations["kubevirt.io/end-port"] // "0")
        ] | @tsv
    ')

    while IFS=$'\t' read -r vm_name new_ip new_ip6 ssh_port start_port end_port; do
        [ -z "$vm_name" ] && continue
        apply_vm_rule_record "$vm_name" "$new_ip" "$new_ip6" "$ssh_port" "$start_port" "$end_port" || true
    done <<< "$records"

    _info "所有规则更新完成"
}

main() {
    check_root
    ensure_kubectl
    ensure_jq

    if [ $# -eq 0 ]; then
        # 无参数：更新所有 VM
        update_all_vms
    else
        update_vm_rules "$1"
    fi
}

main "$@"

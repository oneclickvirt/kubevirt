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

update_vm_rules() {
    local vm_name="$1"

    if ! kubectl get vm "$vm_name" -n "$NS" >/dev/null 2>&1; then
        _error "虚拟机 $vm_name 不存在"
    fi

    # 获取新 IP
    local new_ip
    new_ip=$(kubectl get vmi "$vm_name" -n "$NS" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")

    if [ -z "$new_ip" ] || [ "$new_ip" = "null" ]; then
        _warn "无法获取虚拟机 $vm_name 的 IP，虚拟机可能未运行"
        return 1
    fi

    # 获取 IPv6 地址（如果有）
    local new_ip6="-"
    local all_ips
    all_ips=$(kubectl get vmi "$vm_name" -n "$NS" \
        -o jsonpath='{.status.interfaces[0].ipAddresses[*]}' 2>/dev/null || echo "")
    for ip in $all_ips; do
        if echo "$ip" | grep -q ':'; then
            new_ip6="$ip"
            break
        fi
    done

    # 获取端口信息（从注解）
    local ssh_port
    ssh_port=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/ssh-port}' 2>/dev/null || echo "")
    local start_port
    start_port=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/start-port}' 2>/dev/null || echo "0")
    local end_port
    end_port=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/end-port}' 2>/dev/null || echo "0")

    if [ -z "$ssh_port" ]; then
        _warn "虚拟机 $vm_name 没有 SSH 端口注解，跳过"
        return 1
    fi

    _info "更新 $vm_name 的端口转发规则（新IP: $new_ip，后端：$(fw_backend_name)）..."

    fw_add_vm "$vm_name" "$new_ip" "$ssh_port" "$start_port" "$end_port" "$new_ip6"

    _info "规则更新成功：$vm_name → $new_ip（SSH: $ssh_port, 端口: ${start_port}-${end_port}）"
}

# 更新所有 VM 规则
update_all_vms() {
    _info "更新所有运行中虚拟机的端口转发规则..."
    local vmi_list
    vmi_list=$(kubectl get vmi -n "$NS" --no-headers 2>/dev/null | awk '{print $1}' || true)

    if [ -z "$vmi_list" ]; then
        _warn "没有运行中的虚拟机实例"
        return
    fi

    while IFS= read -r vm; do
        update_vm_rules "$vm" || true
    done <<< "$vmi_list"

    _info "所有规则更新完成"
}

main() {
    check_root

    if [ $# -eq 0 ]; then
        # 无参数：更新所有 VM
        update_all_vms
    else
        update_vm_rules "$1"
    fi
}

main "$@"

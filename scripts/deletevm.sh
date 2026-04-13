#!/bin/bash
# =====================================================================
# KubeVirt 虚拟机删除脚本
# 用法: ./deletevm.sh <vmname> [rmlog:y/n]
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"

# ===== 加载防火墙库 =====
FIREWALL_LIB="/usr/local/lib/kubevirt/firewall.sh"
if [ -f "$FIREWALL_LIB" ]; then
    source "$FIREWALL_LIB"
fi

check_root() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi
}

show_usage() {
    echo "用法: $0 <虚拟机名称> [rmlog:y/n]"
    echo ""
    echo "参数："
    echo "  vmname    - 要删除的虚拟机名称"
    echo "  rmlog     - 是否从 vmlog 中删除记录（默认: y）"
    echo ""
    echo "示例："
    echo "  $0 vm1"
    echo "  $0 vm1 n    # 删除 VM 但保留日志记录"
    exit 1
}

# ===== 检查 VM 是否存在 =====
check_vm_exists() {
    if ! kubectl get vm "$VM_NAME" -n "$NS" >/dev/null 2>&1; then
        _error "虚拟机 '$VM_NAME' 不存在于命名空间 '$NS'"
    fi
    _info "找到虚拟机：$VM_NAME"
}

# ===== 停止虚拟机 =====
stop_vm() {
    _step "停止虚拟机 ${VM_NAME}..."

    local vmi_phase
    vmi_phase=$(kubectl get vmi "$VM_NAME" -n "$NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [ -n "$vmi_phase" ] && [ "$vmi_phase" = "Running" ]; then
        if command -v virtctl >/dev/null 2>&1; then
            virtctl stop "$VM_NAME" -n "$NS" 2>/dev/null || true
        else
            kubectl patch vm "$VM_NAME" -n "$NS" \
                --type merge \
                -p '{"spec":{"running":false}}' 2>/dev/null || true
        fi

        # 等待 VMI 停止
        local timeout=60
        local elapsed=0
        while kubectl get vmi "$VM_NAME" -n "$NS" >/dev/null 2>&1; do
            sleep 2
            elapsed=$((elapsed + 2))
            if [ "$elapsed" -ge "$timeout" ]; then
                _warn "等待 VM 停止超时，强制删除..."
                break
            fi
            echo -n "."
        done
        echo ""
    else
        _info "虚拟机未在运行状态，跳过停止步骤"
    fi
}

# ===== 删除 Kubernetes 资源 =====
delete_k8s_resources() {
    _step "删除 Kubernetes 资源..."

    # 删除 VirtualMachine
    if kubectl get vm "$VM_NAME" -n "$NS" >/dev/null 2>&1; then
        kubectl delete vm "$VM_NAME" -n "$NS" --timeout=60s
        _info "VirtualMachine 已删除"
    fi

    # 删除 DataVolume
    local DV_NAME="${VM_NAME}-dv"
    if kubectl get datavolume "$DV_NAME" -n "$NS" >/dev/null 2>&1; then
        kubectl delete datavolume "$DV_NAME" -n "$NS" --timeout=60s
        _info "DataVolume ${DV_NAME} 已删除"
    fi

    # 删除 PVC（DataVolume 删除后 PVC 通常也会删除，但以防万一）
    if kubectl get pvc "$DV_NAME" -n "$NS" >/dev/null 2>&1; then
        kubectl delete pvc "$DV_NAME" -n "$NS" --timeout=60s 2>/dev/null || true
        _info "PVC ${DV_NAME} 已删除"
    fi

    # 删除 cloud-init Secret
    local SECRET_NAME="${VM_NAME}-cloudinit"
    if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
        kubectl delete secret "$SECRET_NAME" -n "$NS"
        _info "cloud-init Secret 已删除"
    fi

    # 删除 Service（如果有）
    local SVC_NAME="${VM_NAME}-ssh"
    if kubectl get service "$SVC_NAME" -n "$NS" >/dev/null 2>&1; then
        kubectl delete service "$SVC_NAME" -n "$NS"
        _info "Service ${SVC_NAME} 已删除"
    fi
}

# ===== 清理防火墙规则 =====
cleanup_firewall_rules() {
    _step "清理端口转发规则..."

    if [ -f "$FIREWALL_LIB" ]; then
        fw_remove_vm "$VM_NAME"
    else
        _warn "防火墙库未找到，跳过规则清理"
    fi

    _info "端口转发规则已清理"
}

# ===== 从 vmlog 中删除记录 =====
remove_vmlog_entry() {
    if [ "${REMOVE_LOG:-y}" = "n" ]; then
        return
    fi

    if [ -f "vmlog" ]; then
        sed -i "/^${VM_NAME} /d" vmlog 2>/dev/null || true
        _info "vmlog 记录已删除"
    fi
}

# ===== 主流程 =====
main() {
    if [ $# -lt 1 ]; then
        show_usage
    fi

    VM_NAME="$1"
    REMOVE_LOG="${2:-y}"

    echo "======================================================"
    echo -e "${RED}  KubeVirt 虚拟机删除脚本${NC}"
    echo "======================================================"
    echo ""

    check_root
    check_vm_exists

    echo ""
    _warn "即将删除虚拟机 '${VM_NAME}' 及其所有数据（磁盘、配置、端口转发规则）"
    if [ "${FORCE_YES}" != "y" ]; then
        read -rp "确认删除？(y/n): " CONFIRM
        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            _info "已取消删除"
            exit 0
        fi
    fi

    stop_vm
    delete_k8s_resources
    cleanup_firewall_rules
    remove_vmlog_entry

    echo ""
    echo "======================================================"
    echo -e "${GREEN}  虚拟机 ${VM_NAME} 已完整删除${NC}"
    echo "======================================================"
}

main "$@"

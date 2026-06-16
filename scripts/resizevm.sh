#!/bin/bash
# =====================================================================
# KubeVirt 虚拟机资源调整脚本
# 用法: ./resizevm.sh <vmname> [cpu] [memory_gb] [disk_gb]
# https://github.com/oneclickvirt/kubevirt
# =====================================================================
#
# 环境变量：
#   CPU=<cores>          CPU 核数（命令行参数2优先）
#   MEMORY_GB=<gb>       内存 GB（命令行参数3优先）
#   DISK_GB=<gb>         磁盘 GB（命令行参数4优先，只允许扩容）
#   RESTART_VM=true      调整 CPU/内存后自动重启 VM
#   noninteractive=true  统一无交互标记；未设置 RESTART_VM 时不会自动重启
#
# =====================================================================

set -o pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"

_is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

_validate_uint_range() {
    local name="$1" value="$2" min="$3" max="$4"
    [ -z "$value" ] && return 0
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        _error "${name} 无效：${value}（必须在 ${min}-${max} 范围内）"
    fi
}

storage_to_gib() {
    local value="$1"
    local num

    case "$value" in
        *Gi) num="${value%Gi}"; [[ "$num" =~ ^[0-9]+$ ]] && echo "$num" ;;
        *G)  num="${value%G}";  [[ "$num" =~ ^[0-9]+$ ]] && echo "$num" ;;
        *Mi) num="${value%Mi}"; [[ "$num" =~ ^[0-9]+$ ]] && echo $(((num + 1023) / 1024)) ;;
        *M)  num="${value%M}";  [[ "$num" =~ ^[0-9]+$ ]] && echo $(((num + 1023) / 1024)) ;;
        *Ti) num="${value%Ti}"; [[ "$num" =~ ^[0-9]+$ ]] && echo $((num * 1024)) ;;
        *T)  num="${value%T}";  [[ "$num" =~ ^[0-9]+$ ]] && echo $((num * 1024)) ;;
        *)   echo "" ;;
    esac
}

show_usage() {
    echo "用法: $0 <vmname> [cpu] [memory_gb] [disk_gb]"
    echo ""
    echo "示例："
    echo "  $0 vm1 4 8"
    echo "  $0 vm1 '' '' 40"
    echo "  CPU=4 MEMORY_GB=8 DISK_GB=40 $0 vm1"
    exit 1
}

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

validate_name() {
    if ! echo "$VM_NAME" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'; then
        _error "VM 名称只允许小写字母、数字和连字符，且不能以连字符开头或结尾：${VM_NAME}"
    fi
}

parse_args() {
    if [ $# -lt 1 ]; then
        show_usage
    fi
    VM_NAME="$1"
    CPU="${2:-${CPU:-}}"
    MEMORY_GB="${3:-${MEMORY_GB:-}}"
    DISK_GB="${4:-${DISK_GB:-}}"

    validate_name
    _validate_uint_range "CPU 核数" "$CPU" 1 256
    _validate_uint_range "内存" "$MEMORY_GB" 1 1048576
    _validate_uint_range "磁盘" "$DISK_GB" 1 1048576

    if [ -z "$CPU" ] && [ -z "$MEMORY_GB" ] && [ -z "$DISK_GB" ]; then
        _error "未指定任何调整项，请提供 cpu、memory_gb 或 disk_gb"
    fi
}

check_vm_exists() {
    if ! kubectl get vm "$VM_NAME" -n "$NS" >/dev/null 2>&1; then
        _error "虚拟机不存在：${VM_NAME}"
    fi
}

patch_cpu_memory() {
    local changed=0
    if [ -n "$CPU" ]; then
        _step "调整 CPU：${CPU} 核"
        if ! kubectl patch vm "$VM_NAME" -n "$NS" --type merge \
            -p "{\"spec\":{\"template\":{\"spec\":{\"domain\":{\"cpu\":{\"cores\":${CPU}}}}}}}"; then
            _error "CPU 调整失败：${VM_NAME}"
        fi
        changed=1
    fi

    if [ -n "$MEMORY_GB" ]; then
        _step "调整内存：${MEMORY_GB}Gi"
        if ! kubectl patch vm "$VM_NAME" -n "$NS" --type merge \
            -p "{\"spec\":{\"template\":{\"spec\":{\"domain\":{\"memory\":{\"guest\":\"${MEMORY_GB}Gi\"}}}}}}"; then
            _error "内存调整失败：${VM_NAME}"
        fi
        changed=1
    fi

    [ "$changed" -eq 0 ] && return 0

    local phase
    phase=$(kubectl get vmi "$VM_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$phase" = "Running" ]; then
        _warn "CPU/内存模板已更新；运行中的 VM 通常需要重启后完全生效"
        if _is_truthy "${RESTART_VM:-}"; then
            restart_vm
        fi
    fi
}

patch_disk() {
    [ -n "$DISK_GB" ] || return 0

    local pvc_name="${VM_NAME}-dv"
    local current_size current_gb storage_class allow_expansion
    if ! kubectl get pvc "$pvc_name" -n "$NS" >/dev/null 2>&1; then
        _error "PVC 不存在：${pvc_name}"
    fi

    current_size=$(kubectl get pvc "$pvc_name" -n "$NS" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "")
    current_gb=$(storage_to_gib "$current_size")
    if [[ "$current_gb" =~ ^[0-9]+$ ]] && [ "$DISK_GB" -lt "$current_gb" ]; then
        _error "不支持缩小磁盘：当前 ${current_size}，目标 ${DISK_GB}Gi"
    elif [ -z "$current_gb" ]; then
        _warn "无法解析当前 PVC 容量 ${current_size}，将继续提交扩容请求"
    fi

    storage_class=$(kubectl get pvc "$pvc_name" -n "$NS" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
    if [ -n "$storage_class" ]; then
        allow_expansion=$(kubectl get storageclass "$storage_class" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null || echo "")
        if [ "$allow_expansion" != "true" ]; then
            _warn "StorageClass ${storage_class} 未声明 allowVolumeExpansion=true，PVC 扩容可能被拒绝"
        fi
    fi

    _step "扩容磁盘 PVC：${pvc_name} → ${DISK_GB}Gi"
    if ! kubectl patch pvc "$pvc_name" -n "$NS" --type merge \
        -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${DISK_GB}Gi\"}}}}"; then
        _error "PVC 扩容失败：${pvc_name}"
    fi
    kubectl annotate vm "$VM_NAME" -n "$NS" --overwrite \
        "kubevirt.io/disk-size=${DISK_GB}Gi" >/dev/null 2>&1 || true
    _warn "PVC 扩容依赖 StorageClass 支持；虚拟机内文件系统可能仍需手动 growfs/resize2fs/xfs_growfs"
}

restart_vm() {
    _step "重启虚拟机：${VM_NAME}"
    if command -v virtctl >/dev/null 2>&1; then
        if ! virtctl restart "$VM_NAME" -n "$NS"; then
            _error "virtctl 重启失败：${VM_NAME}"
        fi
    else
        if ! kubectl patch vm "$VM_NAME" -n "$NS" --type merge -p '{"spec":{"running":false}}'; then
            _error "停止 VM 失败：${VM_NAME}"
        fi
        local elapsed=0
        while kubectl get vmi "$VM_NAME" -n "$NS" >/dev/null 2>&1 && [ "$elapsed" -lt 120 ]; do
            sleep 3
            elapsed=$((elapsed + 3))
        done
        if kubectl get vmi "$VM_NAME" -n "$NS" >/dev/null 2>&1; then
            _error "等待 VM 停止超时：${VM_NAME}"
        fi
        if ! kubectl patch vm "$VM_NAME" -n "$NS" --type merge -p '{"spec":{"running":true}}'; then
            _error "启动 VM 失败：${VM_NAME}"
        fi
    fi
}

main() {
    parse_args "$@"
    check_root
    ensure_kubectl
    check_vm_exists
    patch_cpu_memory
    patch_disk

    echo ""
    echo "======================================================"
    echo -e "${GREEN}  虚拟机资源调整完成${NC}"
    echo "  名称:   ${VM_NAME}"
    [ -n "$CPU" ] && echo "  CPU:    ${CPU} 核"
    [ -n "$MEMORY_GB" ] && echo "  内存:   ${MEMORY_GB}Gi"
    [ -n "$DISK_GB" ] && echo "  磁盘:   ${DISK_GB}Gi"
    echo "======================================================"
}

main "$@"

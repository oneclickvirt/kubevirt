#!/bin/bash
# =====================================================================
# KubeVirt DataVolume 克隆快照脚本
# 用法: ./snapshotvm.sh <source-vm> [snapshot-name]
# https://github.com/oneclickvirt/kubevirt
# =====================================================================
#
# 环境变量：
#   noninteractive=true          跳过运行中 VM 克隆确认；默认会拒绝运行中 VM
#   ALLOW_RUNNING_SNAPSHOT=true  允许对运行中 VM 的 DataVolume 克隆（可能不一致）
#   WAIT_SNAPSHOT=true           等待克隆完成，默认 true
#   SNAPSHOT_TIMEOUT=1800        等待超时时间（秒）
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

_is_noninteractive() {
    _is_truthy "${noninteractive:-}" || _is_truthy "${NONINTERACTIVE:-}" || \
    _is_truthy "${AUTO_YES:-}" || _is_truthy "${FORCE_YES:-}"
}

show_usage() {
    echo "用法: $0 <source-vm> [snapshot-name]"
    echo ""
    echo "示例："
    echo "  $0 vm1"
    echo "  $0 vm1 vm1-snap-20260603"
    exit 1
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi
}

ensure_tools() {
    if ! command -v kubectl >/dev/null 2>&1; then
        if command -v k3s >/dev/null 2>&1; then
            kubectl() { k3s kubectl "$@"; }
        else
            _error "未找到 kubectl/k3s，请先安装 KubeVirt 环境"
        fi
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _error "未找到 jq，请先安装依赖或重新运行安装脚本"
    fi
}

validate_name() {
    local label="$1" value="$2"
    if ! echo "$value" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'; then
        _error "${label} 只允许小写字母、数字和连字符，且不能以连字符开头或结尾：${value}"
    fi
}

check_source_vm() {
    if ! kubectl get vm "$SOURCE_VM" -n "$NS" >/dev/null 2>&1; then
        _error "源虚拟机不存在：${SOURCE_VM}"
    fi
    if ! kubectl get datavolume "$SOURCE_DV" -n "$NS" >/dev/null 2>&1; then
        _error "源 DataVolume 不存在：${SOURCE_DV}"
    fi
    if ! kubectl get pvc "$SOURCE_DV" -n "$NS" >/dev/null 2>&1; then
        _error "源 PVC 不存在：${SOURCE_DV}"
    fi
    if kubectl get datavolume "$SNAPSHOT_NAME" -n "$NS" >/dev/null 2>&1; then
        _error "目标快照 DataVolume 已存在：${SNAPSHOT_NAME}"
    fi

    local dv_phase
    dv_phase=$(kubectl get datavolume "$SOURCE_DV" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$dv_phase" != "Succeeded" ]; then
        _error "源 DataVolume 尚未就绪：${SOURCE_DV} 当前状态 ${dv_phase:-Unknown}"
    fi
}

guard_running_vm() {
    local phase
    phase=$(kubectl get vmi "$SOURCE_VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$phase" != "Running" ] && return 0

    if _is_truthy "${ALLOW_RUNNING_SNAPSHOT:-}"; then
        _warn "源 VM 正在运行，将按 ALLOW_RUNNING_SNAPSHOT=true 继续；快照可能不是应用一致性快照"
        return 0
    fi

    if _is_noninteractive; then
        _error "源 VM 正在运行。请先停止 VM，或设置 ALLOW_RUNNING_SNAPSHOT=true 明确允许在线克隆"
    fi

    _warn "源 VM 正在运行，在线克隆可能产生不一致数据"
    read -rp "仍要继续？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        _info "已取消"
        exit 0
    fi
}

create_snapshot_datavolume() {
    local dv_json storage_class storage_size access_mode
    dv_json=$(kubectl get datavolume "$SOURCE_DV" -n "$NS" -o json)
    storage_class=$(printf '%s' "$dv_json" | jq -r '.spec.storage.storageClassName // .spec.pvc.storageClassName // "local-path"')
    storage_size=$(printf '%s' "$dv_json" | jq -r '.spec.storage.resources.requests.storage // .spec.pvc.resources.requests.storage // empty')
    access_mode=$(printf '%s' "$dv_json" | jq -r '.spec.storage.accessModes[0] // .spec.pvc.accessModes[0] // "ReadWriteOnce"')

    [ -n "$storage_size" ] || _error "无法读取源 DataVolume 容量：${SOURCE_DV}"

    _step "创建快照 DataVolume：${SNAPSHOT_NAME}"
    if ! cat <<EOF | kubectl apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${NS}
  labels:
    app: kubevirt-vm-snapshot
    kubevirt.io/source-vm: ${SOURCE_VM}
    kubevirt.io/source-dv: ${SOURCE_DV}
spec:
  source:
    pvc:
      namespace: ${NS}
      name: ${SOURCE_DV}
  storage:
    accessModes:
      - ${access_mode}
    resources:
      requests:
        storage: ${storage_size}
    storageClassName: ${storage_class}
EOF
    then
        _error "快照 DataVolume 创建失败：${SNAPSHOT_NAME}"
    fi
}

wait_snapshot() {
    _is_truthy "${WAIT_SNAPSHOT:-true}" || return 0

    local timeout="${SNAPSHOT_TIMEOUT:-1800}"
    local elapsed=0
    local phase progress
    _step "等待快照克隆完成（最多 ${timeout} 秒）..."
    while [ "$elapsed" -lt "$timeout" ]; do
        phase=$(kubectl get datavolume "$SNAPSHOT_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        progress=$(kubectl get datavolume "$SNAPSHOT_NAME" -n "$NS" -o jsonpath='{.status.progress}' 2>/dev/null || echo "")
        case "$phase" in
            Succeeded)
                _info "快照克隆完成：${SNAPSHOT_NAME}"
                return 0
                ;;
            Failed)
                kubectl describe datavolume "$SNAPSHOT_NAME" -n "$NS" 2>/dev/null || true
                _error "快照克隆失败：${SNAPSHOT_NAME}"
                ;;
        esac
        [ -n "$progress" ] && echo -ne "\r  进度: ${progress} (状态: ${phase})        "
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""
    _error "快照克隆超时：${SNAPSHOT_NAME}"
}

main() {
    if [ $# -lt 1 ]; then
        show_usage
    fi

    SOURCE_VM="$1"
    SNAPSHOT_NAME="${2:-${SOURCE_VM}-snapshot-$(date +%Y%m%d%H%M%S)}"
    SOURCE_DV="${SOURCE_VM}-dv"

    validate_name "源 VM 名称" "$SOURCE_VM"
    validate_name "快照名称" "$SNAPSHOT_NAME"
    check_root
    ensure_tools
    check_source_vm
    guard_running_vm
    create_snapshot_datavolume
    wait_snapshot

    echo ""
    echo "======================================================"
    echo -e "${GREEN}  快照 DataVolume 已创建${NC}"
    echo "  源 VM:       ${SOURCE_VM}"
    echo "  源 DV:       ${SOURCE_DV}"
    echo "  快照 DV:     ${SNAPSHOT_NAME}"
    echo "======================================================"
}

main "$@"

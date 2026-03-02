#!/bin/bash
# =====================================================================
# KubeVirt 一键卸载脚本
# 完整清理 K3s + KubeVirt + CDI 及所有虚拟机
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

# ===== 颜色输出 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

check_root() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi
}

# ===== 确认操作 =====
confirm_uninstall() {
    echo ""
    echo -e "${RED}======================================================"
    echo "  警告：此操作将完整卸载 KubeVirt 环境！"
    echo ""
    echo "  以下内容将被永久删除："
    echo "  - 所有虚拟机及其磁盘数据"
    echo "  - KubeVirt 和 CDI 所有组件"
    echo "  - K3s Kubernetes 集群"
    echo "  - 所有相关配置文件"
    echo "  - 所有 iptables 端口转发规则"
    echo -e "======================================================${NC}"
    echo ""

    read -rp "请输入 'yes' 确认卸载（其他输入取消）: " confirm
    if [ "$confirm" != "yes" ]; then
        _info "已取消卸载操作"
        exit 0
    fi
    echo ""
}

# ===== 停止所有虚拟机 =====
stop_all_vms() {
    _step "停止并删除所有虚拟机..."

    if ! command -v kubectl >/dev/null 2>&1 && ! command -v k3s >/dev/null 2>&1; then
        _warn "kubectl/k3s 未找到，跳过 VM 清理"
        return 0
    fi

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # 获取所有命名空间的 VM 列表
    local vm_list
    vm_list=$(kubectl get vm -A --no-headers 2>/dev/null | awk '{print $1 "/" $2}' || true)

    if [ -n "$vm_list" ]; then
        _info "发现以下虚拟机，正在删除..."
        echo "$vm_list"
        while IFS= read -r vm; do
            local ns="${vm%/*}"
            local name="${vm#*/}"
            _info "删除虚拟机：$name (namespace: $ns)"
            kubectl delete vm "$name" -n "$ns" --timeout=60s 2>/dev/null || true
        done <<< "$vm_list"
    else
        _info "未发现运行中的虚拟机"
    fi

    # 清理所有 VMI（虚拟机实例）
    kubectl delete vmi --all -A --timeout=120s 2>/dev/null || true

    # 清理 kubevirt-vms 命名空间中所有资源
    if kubectl get namespace kubevirt-vms >/dev/null 2>&1; then
        _info "清理 kubevirt-vms 命名空间..."
        kubectl delete namespace kubevirt-vms --timeout=120s 2>/dev/null || true
    fi

    _info "虚拟机清理完成"
}

# ===== 卸载 KubeVirt =====
uninstall_kubevirt() {
    _step "卸载 KubeVirt..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if ! kubectl get namespace kubevirt >/dev/null 2>&1; then
        _info "KubeVirt 未安装，跳过"
        return 0
    fi

    local KUBEVIRT_VERSION
    KUBEVIRT_VERSION=$(kubectl get kubevirt -n kubevirt kubevirt \
        -o jsonpath='{.status.observedKubeVirtVersion}' 2>/dev/null || echo "v1.2.1")

    _info "卸载 KubeVirt CR..."
    kubectl delete kubevirt kubevirt -n kubevirt --timeout=120s 2>/dev/null || true

    _info "等待 KubeVirt 资源清理..."
    sleep 10

    _info "卸载 KubeVirt Operator..."
    local KV_BASE="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"
    kubectl delete -f "${KV_BASE}/kubevirt-cr.yaml" 2>/dev/null || true
    kubectl delete -f "${KV_BASE}/kubevirt-operator.yaml" 2>/dev/null || true

    # 强制删除命名空间
    kubectl delete namespace kubevirt --timeout=120s 2>/dev/null || true
    # 清理可能残留的 finalizers
    kubectl patch namespace kubevirt \
        -p '{"metadata":{"finalizers":[]}}' \
        --type=merge 2>/dev/null || true

    _info "KubeVirt 卸载完成"
}

# ===== 卸载 CDI =====
uninstall_cdi() {
    _step "卸载 CDI..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if ! kubectl get namespace cdi >/dev/null 2>&1; then
        _info "CDI 未安装，跳过"
        return 0
    fi

    local CDI_VERSION
    CDI_VERSION=$(kubectl get cdi cdi -n cdi \
        -o jsonpath='{.status.observedVersion}' 2>/dev/null || echo "v1.59.0")

    _info "卸载 CDI CR..."
    kubectl delete cdi cdi -n cdi --timeout=120s 2>/dev/null || true

    sleep 5

    _info "卸载 CDI Operator..."
    local CDI_BASE="https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}"
    kubectl delete -f "${CDI_BASE}/cdi-cr.yaml" 2>/dev/null || true
    kubectl delete -f "${CDI_BASE}/cdi-operator.yaml" 2>/dev/null || true

    kubectl delete namespace cdi --timeout=120s 2>/dev/null || true
    kubectl patch namespace cdi \
        -p '{"metadata":{"finalizers":[]}}' \
        --type=merge 2>/dev/null || true

    _info "CDI 卸载完成"
}

# ===== 清理 iptables 规则 =====
cleanup_iptables() {
    _step "清理 iptables 端口转发规则..."

    # 清理 KubeVirt 相关的 DNAT 规则
    # 读取规则文件并逐条删除
    local RULES_FILE="/etc/kubevirt/iptables-rules"
    if [ -f "$RULES_FILE" ]; then
        _info "从规则文件清理 iptables..."
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            local delete_line="${line/-A/-D}"
            eval "iptables $delete_line" 2>/dev/null || true
        done < "$RULES_FILE"
        rm -f "$RULES_FILE"
    fi

    # 额外清理：删除所有包含 KUBEVIRT-VM 注释的规则
    iptables -t nat -S PREROUTING 2>/dev/null | grep "KUBEVIRT-VM\|kubevirt-vm" | while read -r rule; do
        local del_rule="${rule/-A/-D}"
        eval "iptables -t nat $del_rule" 2>/dev/null || true
    done

    _info "iptables 清理完成"
}

# ===== 停用并删除 systemd 服务 =====
cleanup_systemd() {
    _step "清理 systemd 服务..."

    local services=(
        "kubevirt-iptables"
    )

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/${svc}.service"
    done

    systemctl daemon-reload 2>/dev/null || true
    _info "systemd 服务清理完成"
}

# ===== 删除 virtctl =====
remove_virtctl() {
    _step "删除 virtctl..."
    rm -f /usr/local/bin/virtctl
    _info "virtctl 已删除"
}

# ===== 卸载 K3s =====
uninstall_k3s() {
    _step "卸载 K3s..."

    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        _info "执行 K3s 卸载脚本..."
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
    elif command -v k3s >/dev/null 2>&1; then
        _warn "K3s 卸载脚本未找到，尝试手动卸载..."
        systemctl stop k3s 2>/dev/null || true
        systemctl disable k3s 2>/dev/null || true
        rm -f /etc/systemd/system/k3s.service
        rm -rf /var/lib/rancher/k3s
        rm -f /usr/local/bin/k3s
        rm -f /usr/local/bin/kubectl
        systemctl daemon-reload
    else
        _info "K3s 未安装，跳过"
    fi

    _info "K3s 卸载完成"
}

# ===== 清理配置文件和数据目录 =====
cleanup_files() {
    _step "清理配置文件和数据..."

    # KubeVirt 相关配置
    rm -rf /etc/kubevirt
    rm -f /usr/local/bin/kubevirt-restore-iptables.sh
    rm -f /usr/local/bin/kubevirt-clear-iptables.sh

    # K3s 配置
    rm -f /etc/profile.d/k3s.sh
    rm -f /etc/sysctl.d/99-kubevirt-ipforward.conf

    # kubeconfig
    rm -rf /root/.kube 2>/dev/null || true
    rm -f /home/*/.kube/config 2>/dev/null || true

    # 日志文件（保留 vmlog 方便用户查看历史记录）
    _warn "vmlog 文件已保留（如需删除请手动操作）"

    _info "配置文件清理完成"
}

# ===== 恢复 sysctl =====
cleanup_sysctl() {
    _step "恢复系统参数..."
    # 注意：不重置 ip_forward，因为系统可能有其他服务依赖
    _info "系统参数清理完成"
}

# ===== 输出完成摘要 =====
print_summary() {
    echo ""
    echo "======================================================"
    echo -e "${GREEN}  KubeVirt 环境已完整卸载！${NC}"
    echo "======================================================"
    echo ""
    echo "已删除："
    echo "  ✓ 所有虚拟机及数据"
    echo "  ✓ KubeVirt 组件"
    echo "  ✓ CDI 组件"
    echo "  ✓ K3s Kubernetes 集群"
    echo "  ✓ virtctl 工具"
    echo "  ✓ iptables 端口转发规则"
    echo "  ✓ 相关配置文件"
    echo ""
    _warn "vmlog 文件未删除，如需清理请手动运行：rm -f vmlog"
    echo "======================================================"
}

# ===== 主流程 =====
main() {
    echo "======================================================"
    echo -e "${RED}  KubeVirt 一键卸载脚本${NC}"
    echo "  https://github.com/oneclickvirt/kubevirt"
    echo "======================================================"
    echo ""

    check_root
    confirm_uninstall
    stop_all_vms
    uninstall_kubevirt
    uninstall_cdi
    cleanup_iptables
    cleanup_systemd
    remove_virtctl
    uninstall_k3s
    cleanup_files
    cleanup_sysctl
    print_summary
}

main "$@"

#!/bin/bash
# =====================================================================
# KubeVirt 虚拟机列表查询脚本
# 用法: ./listvms.sh [vmname] [-v|--verbose]
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"

_header() { echo -e "${BLUE}$*${NC}"; }
_info()   { echo -e "${GREEN}$*${NC}"; }
_warn()   { echo -e "${YELLOW}$*${NC}"; }

show_usage() {
    echo "用法: $0 [vmname] [-v|--verbose]"
    echo ""
    echo "选项："
    echo "  vmname      - 查看指定虚拟机详细信息"
    echo "  -v/--verbose - 显示详细信息"
    echo ""
    echo "示例："
    echo "  $0            # 列出所有 VM"
    echo "  $0 vm1        # 查看 vm1 详细信息"
    echo "  $0 -v         # 详细模式列出所有 VM"
}

check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1 && ! command -v k3s >/dev/null 2>&1; then
        echo "错误：未找到 kubectl/k3s，请先安装 KubeVirt 环境"
        exit 1
    fi
    if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
        echo "命名空间 $NS 不存在，请先安装 KubeVirt 环境"
        exit 1
    fi
}

# ===== 获取宿主机 IP =====
get_host_ip() {
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' \
        || hostname -I | awk '{print $1}' \
        || echo "<宿主机IP>")
}

# ===== 列出所有虚拟机 =====
list_all_vms() {
    local verbose="${1:-}"

    #— 获取 VM 列表
    local vm_list
    vm_list=$(kubectl get vm -n "$NS" --no-headers 2>/dev/null)

    if [ -z "$vm_list" ]; then
        echo ""
        _warn "当前没有虚拟机。"
        echo ""
        echo "使用以下命令创建虚拟机："
        echo "  curl -sSL -o onevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh"
        echo "  chmod +x onevm.sh"
        echo "  ./onevm.sh vm1 2 2 20 MyPass 25000 34975 35000 debian"
        return
    fi

    get_host_ip

    echo ""
    _header "======================================================"
    _header "  KubeVirt 虚拟机列表"
    _header "  宿主机 IP：${HOST_IP}"
    _header "======================================================"
    echo ""
    printf "%-15s %-10s %-12s %-8s %-10s %-12s\n" \
        "名称" "状态" "VMI状态" "CPU" "内存" "SSH端口"
    echo "-----------------------------------------------------------------------"

    while IFS= read -r line; do
        local vm_name
        vm_name=$(echo "$line" | awk '{print $1}')
        local vm_ready
        vm_ready=$(echo "$line" | awk '{print $2}')
        local vm_status
        vm_status=$(echo "$line" | awk '{print $3}')

        # 获取 VMI 状态
        local vmi_phase
        vmi_phase=$(kubectl get vmi "$vm_name" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Stopped")

        # 获取资源信息（从注解）
        local ssh_port
        ssh_port=$(kubectl get vm "$vm_name" -n "$NS" \
            -o jsonpath='{.metadata.annotations.kubevirt\.io/ssh-port}' 2>/dev/null || echo "?")
        local cpu_cores
        cpu_cores=$(kubectl get vm "$vm_name" -n "$NS" \
            -o jsonpath='{.spec.template.spec.domain.cpu.cores}' 2>/dev/null || echo "?")
        local memory
        memory=$(kubectl get vm "$vm_name" -n "$NS" \
            -o jsonpath='{.spec.template.spec.domain.memory.guest}' 2>/dev/null || echo "?")

        # 状态颜色
        local status_str
        case "$vmi_phase" in
            Running)  status_str="${GREEN}Running${NC}" ;;
            Stopped)  status_str="${YELLOW}Stopped${NC}" ;;
            Pending|Scheduling|Scheduled) status_str="${CYAN}Starting${NC}" ;;
            Failed)   status_str="${RED}Failed${NC}" ;;
            *)        status_str="${NC}${vmi_phase}${NC}" ;;
        esac

        printf "%-15s %-10s " "$vm_name" "$(echo "$vm_ready" | tr -d '\n')"
        echo -e "${status_str}$(printf '%-6s' '') ${cpu_cores}核     ${memory}       ${ssh_port}"

        if [ -n "$verbose" ]; then
            # 详细信息
            local vm_ip
            vm_ip=$(kubectl get vmi "$vm_name" -n "$NS" \
                -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
            local start_port
            start_port=$(kubectl get vm "$vm_name" -n "$NS" \
                -o jsonpath='{.metadata.annotations.kubevirt\.io/start-port}' 2>/dev/null || echo "?")
            local end_port
            end_port=$(kubectl get vm "$vm_name" -n "$NS" \
                -o jsonpath='{.metadata.annotations.kubevirt\.io/end-port}' 2>/dev/null || echo "?")
            local system
            system=$(kubectl get vm "$vm_name" -n "$NS" \
                -o jsonpath='{.metadata.labels.vm-system}' 2>/dev/null || echo "?")
            local disk
            disk=$(kubectl get datavolume "${vm_name}-dv" -n "$NS" \
                -o jsonpath='{.spec.storage.resources.requests.storage}' 2>/dev/null || echo "?")

            echo "  ├─ 内网 IP:  ${vm_ip}"
            echo "  ├─ 系统:     ${system}"
            echo "  ├─ 磁盘:     ${disk}"
            echo "  ├─ 端口范围: ${start_port}-${end_port}"
            if [ "$vmi_phase" = "Running" ] && [ "$ssh_port" != "?" ] && [ "$ssh_port" != "0" ]; then
                echo "  └─ SSH 连接: ssh root@${HOST_IP} -p ${ssh_port}"
            fi
            echo ""
        fi

    done <<< "$vm_list"

    echo ""
    echo "共 $(echo "$vm_list" | wc -l) 台虚拟机"

    # 显示 vmlog 摘要（如果存在）
    if [ -f "vmlog" ] && [ -s "vmlog" ]; then
        echo ""
        _header "─── 连接信息摘要（vmlog）───"
        cat vmlog
    fi
    echo ""
}

# ===== 查看单个 VM 详情 =====
show_vm_detail() {
    local vm_name="$1"

    if ! kubectl get vm "$vm_name" -n "$NS" >/dev/null 2>&1; then
        echo "错误：虚拟机 '$vm_name' 不存在"
        exit 1
    fi

    get_host_ip

    echo ""
    _header "======================================================"
    _header "  虚拟机详情：${vm_name}"
    _header "======================================================"
    echo ""

    # 基础信息
    local vm_status
    vm_status=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.status.printableStatus}' 2>/dev/null)
    local vmi_phase
    vmi_phase=$(kubectl get vmi "$vm_name" -n "$NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Not Running")
    local vm_ip
    vm_ip=$(kubectl get vmi "$vm_name" -n "$NS" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
    local cpu_cores
    cpu_cores=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.spec.template.spec.domain.cpu.cores}' 2>/dev/null || echo "?")
    local memory
    memory=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.spec.template.spec.domain.memory.guest}' 2>/dev/null || echo "?")
    local ssh_port
    ssh_port=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/ssh-port}' 2>/dev/null || echo "?")
    local start_port
    start_port=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/start-port}' 2>/dev/null || echo "?")
    local end_port
    end_port=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/end-port}' 2>/dev/null || echo "?")
    local password
    password=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.annotations.kubevirt\.io/password}' 2>/dev/null || echo "?")
    local system
    system=$(kubectl get vm "$vm_name" -n "$NS" \
        -o jsonpath='{.metadata.labels.vm-system}' 2>/dev/null || echo "?")

    # 磁盘信息
    local dv_phase
    dv_phase=$(kubectl get datavolume "${vm_name}-dv" -n "$NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "N/A")
    local dv_progress
    dv_progress=$(kubectl get datavolume "${vm_name}-dv" -n "$NS" \
        -o jsonpath='{.status.progress}' 2>/dev/null || echo "N/A")
    local disk_size
    disk_size=$(kubectl get datavolume "${vm_name}-dv" -n "$NS" \
        -o jsonpath='{.spec.storage.resources.requests.storage}' 2>/dev/null || echo "?")

    echo "  名称:         ${vm_name}"
    echo "  VM 状态:      ${vm_status}"
    echo "  VMI 阶段:     ${vmi_phase}"
    echo "  内网 IP:      ${vm_ip}"
    echo ""
    echo "  资源配置："
    echo "    CPU:        ${cpu_cores} 核"
    echo "    内存:       ${memory}"
    echo "    磁盘:       ${disk_size} (导入状态: ${dv_phase} ${dv_progress})"
    echo "    系统:       ${system}"
    echo ""
    echo "  网络配置："
    echo "    SSH 端口:   ${HOST_IP}:${ssh_port}"
    echo "    额外端口:   ${start_port}-${end_port}"
    echo "    SSH 命令:   ssh root@${HOST_IP} -p ${ssh_port}"
    echo "    密码:       ${password}"
    echo ""
    echo "  管理命令："
    echo "    virtctl start ${vm_name} -n ${NS}"
    echo "    virtctl stop ${vm_name} -n ${NS}"
    echo "    virtctl restart ${vm_name} -n ${NS}"
    echo "    virtctl console ${vm_name} -n ${NS}  # Ctrl+] 退出"
    echo ""

    # 显示 Pod 信息
    echo "  运行的 Pod："
    kubectl get pod -n "$NS" -l "kubevirt.io/vm=${vm_name}" 2>/dev/null || echo "    无运行中的 Pod"
    echo ""

    # 显示事件
    echo "  最近事件（VM）："
    kubectl get events -n "$NS" \
        --field-selector "involvedObject.name=${vm_name}" \
        --sort-by=lastTimestamp 2>/dev/null | tail -5
    echo ""
}

# ===== 环境状态概览 =====
show_env_status() {
    echo ""
    _header "─── KubeVirt 环境状态 ───"

    # K3s
    local k3s_status
    if systemctl is-active --quiet k3s 2>/dev/null; then
        k3s_status="${GREEN}运行中${NC}"
    else
        k3s_status="${YELLOW}未运行${NC}"
    fi
    echo -e "  K3s:      ${k3s_status}"

    # KubeVirt
    local kv_status
    kv_status=$(kubectl get kubevirt -n kubevirt kubevirt \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "未安装")
    if [ "$kv_status" = "Deployed" ]; then
        kv_status="${GREEN}已部署${NC}"
    else
        kv_status="${YELLOW}${kv_status}${NC}"
    fi
    echo -e "  KubeVirt: ${kv_status}"

    # CDI
    local cdi_status
    cdi_status=$(kubectl get cdi -n cdi cdi \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "未安装")
    if [ "$cdi_status" = "Deployed" ]; then
        cdi_status="${GREEN}已部署${NC}"
    else
        cdi_status="${YELLOW}${cdi_status}${NC}"
    fi
    echo -e "  CDI:      ${cdi_status}"
    echo ""
}

# ===== 主流程 =====
main() {
    local verbose=""
    local target_vm=""

    for arg in "$@"; do
        case "$arg" in
            -v|--verbose) verbose=1 ;;
            -h|--help) show_usage; exit 0 ;;
            *) target_vm="$arg" ;;
        esac
    done

    check_kubectl
    show_env_status

    if [ -n "$target_vm" ]; then
        show_vm_detail "$target_vm"
    else
        list_all_vms "$verbose"
    fi
}

main "$@"

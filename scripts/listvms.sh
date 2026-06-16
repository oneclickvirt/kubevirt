#!/bin/bash
# =====================================================================
# KubeVirt 虚拟机列表查询脚本
# 用法: ./listvms.sh [vmname] [-v|--verbose]
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"

_header() { echo -e "${BLUE}$*${NC}"; }
_info()   { echo -e "${GREEN}$*${NC}"; }
_warn()   { echo -e "${YELLOW}$*${NC}"; }

_is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

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
    if ! command -v kubectl >/dev/null 2>&1; then
        if command -v k3s >/dev/null 2>&1; then
            kubectl() { k3s kubectl "$@"; }
        else
            echo "错误：未找到 kubectl/k3s，请先安装 KubeVirt 环境"
            exit 1
        fi
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "错误：未找到 jq，请先安装依赖或重新运行安装脚本"
        exit 1
    fi
    if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
        echo "命名空间 $NS 不存在，请先安装 KubeVirt 环境"
        exit 1
    fi
}

get_json_or_empty_list() {
    local resource="$1"
    kubectl get "$resource" -n "$NS" -o json 2>/dev/null || printf '{"items":[]}\n'
}

get_json_or_empty_object() {
    kubectl "$@" -o json 2>/dev/null || printf '{}\n'
}

# ===== 获取宿主机 IP =====
get_host_ip() {
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    HOST_IP="${HOST_IP:-<宿主机IP>}"
}

# ===== 列出所有虚拟机 =====
list_all_vms() {
    local verbose="${1:-}"
    local vm_json vmi_json dv_json pvc_json vm_count

    vm_json=$(get_json_or_empty_list vm)
    vm_count=$(printf '%s' "$vm_json" | jq '.items | length')

    if [ "$vm_count" -eq 0 ]; then
        echo ""
        _warn "当前没有虚拟机。"
        echo ""
        echo "使用以下命令创建虚拟机："
        echo "  curl -sSL -o onevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh"
        echo "  chmod +x onevm.sh"
        echo "  ./onevm.sh vm1 2 2 20 MyPass 25000 34975 35000 debian"
        return
    fi

    vmi_json=$(get_json_or_empty_list vmi)
    dv_json=$(get_json_or_empty_list datavolume)
    pvc_json=$(get_json_or_empty_list pvc)

    get_host_ip

    echo ""
    _header "======================================================"
    _header "  KubeVirt 虚拟机列表"
    _header "  宿主机 IP：${HOST_IP}"
    _header "======================================================"
    echo ""
    printf "%-15s %-10s %-12s %-8s %-10s %-12s\n" \
        "名称" "Ready" "VMI状态" "CPU" "内存" "SSH端口"
    echo "-----------------------------------------------------------------------"

    while IFS=$'\t' read -r vm_name vm_ready vm_status vmi_phase ssh_port cpu_cores memory vm_ip start_port end_port system disk; do
        [ -z "$vm_name" ] && continue

        local status_str
        case "$vmi_phase" in
            Running)  status_str="${GREEN}Running${NC}" ;;
            Stopped)  status_str="${YELLOW}Stopped${NC}" ;;
            Pending|Scheduling|Scheduled) status_str="${CYAN}Starting${NC}" ;;
            Failed)   status_str="${RED}Failed${NC}" ;;
            *)        status_str="${NC}${vmi_phase}${NC}" ;;
        esac

        printf "%-15s %-10s " "$vm_name" "$vm_ready"
        echo -e "${status_str}$(printf '%-6s' '') ${cpu_cores}核     ${memory}       ${ssh_port}"

        if [ -n "$verbose" ]; then
            echo "  ├─ 内网 IP:  ${vm_ip}"
            echo "  ├─ VM 状态:  ${vm_status}"
            echo "  ├─ 系统:     ${system}"
            echo "  ├─ 磁盘:     ${disk}"
            echo "  ├─ 端口范围: ${start_port}-${end_port}"
            if [ "$vmi_phase" = "Running" ] && [ "$ssh_port" != "?" ] && [ "$ssh_port" != "0" ]; then
                echo "  └─ SSH 连接: ssh root@${HOST_IP} -p ${ssh_port}"
            fi
            echo ""
        fi
    done < <(
        printf '%s' "$vm_json" | jq -r --argjson vmis "$vmi_json" --argjson dvs "$dv_json" --argjson pvcs "$pvc_json" '
            .items[] as $vm |
            ($vm.metadata.name // "") as $name |
            ([ $vmis.items[]? | select(.metadata.name == $name) ][0] // {}) as $vmi |
            ([ $dvs.items[]? | select(.metadata.name == ($name + "-dv")) ][0] // {}) as $dv |
            ([ $pvcs.items[]? | select(.metadata.name == ($name + "-dv")) ][0] // {}) as $pvc |
            [
              $name,
              ($vm.status.ready // false | tostring),
              ($vm.status.printableStatus // "-"),
              ($vmi.status.phase // "Stopped"),
              ($vm.metadata.annotations["kubevirt.io/ssh-port"] // "?"),
              ($vm.spec.template.spec.domain.cpu.cores // "?" | tostring),
              ($vm.spec.template.spec.domain.memory.guest // "?"),
              ($vmi.status.interfaces[0].ipAddress // "N/A"),
              ($vm.metadata.annotations["kubevirt.io/start-port"] // "?"),
              ($vm.metadata.annotations["kubevirt.io/end-port"] // "?"),
              ($vm.metadata.labels["vm-system"] // "?"),
              (
                $pvc.spec.resources.requests.storage //
                $pvc.status.capacity.storage //
                $vm.metadata.annotations["kubevirt.io/disk-size"] //
                $dv.spec.storage.resources.requests.storage //
                "?"
              )
            ] | @tsv
        '
    )

    echo ""
    echo "共 ${vm_count} 台虚拟机"

    # 显示 vmlog 摘要（如果存在）
    if [ -f "vmlog" ] && [ -s "vmlog" ]; then
        echo ""
        _header "─── 连接信息摘要（vmlog）───"
        if _is_truthy "${SHOW_PASSWORD:-}"; then
            cat vmlog
        else
            sed -E 's/(密码: )[^[:space:]]+/\1******/g' vmlog
            echo "（设置 SHOW_PASSWORD=true 显示 vmlog 中的明文密码）"
        fi
    fi
    echo ""
}

# ===== 查看单个 VM 详情 =====
show_vm_detail() {
    local vm_name="$1"
    local vm_json vmi_json dv_json pvc_json detail_line

    if ! vm_json=$(kubectl get vm "$vm_name" -n "$NS" -o json 2>/dev/null); then
        echo "错误：虚拟机 '$vm_name' 不存在"
        exit 1
    fi
    vmi_json=$(get_json_or_empty_object get vmi "$vm_name" -n "$NS")
    dv_json=$(get_json_or_empty_object get datavolume "${vm_name}-dv" -n "$NS")
    pvc_json=$(get_json_or_empty_object get pvc "${vm_name}-dv" -n "$NS")

    get_host_ip

    echo ""
    _header "======================================================"
    _header "  虚拟机详情：${vm_name}"
    _header "======================================================"
    echo ""

    local vm_status vmi_phase vm_ip cpu_cores memory ssh_port start_port end_port password password_stored system dv_phase dv_progress disk_size
    detail_line=$(printf '%s' "$vm_json" | jq -r --argjson vmi "$vmi_json" --argjson dv "$dv_json" --argjson pvc "$pvc_json" '
        [
          (.status.printableStatus // "-"),
          ($vmi.status.phase // "Not Running"),
          ($vmi.status.interfaces[0].ipAddress // "N/A"),
          (.spec.template.spec.domain.cpu.cores // "?" | tostring),
          (.spec.template.spec.domain.memory.guest // "?"),
          (.metadata.annotations["kubevirt.io/ssh-port"] // "?"),
          (.metadata.annotations["kubevirt.io/start-port"] // "?"),
          (.metadata.annotations["kubevirt.io/end-port"] // "?"),
          (.metadata.annotations["kubevirt.io/password"] // "?"),
          (.metadata.annotations["kubevirt.io/password-stored"] // "true"),
          (.metadata.labels["vm-system"] // "?"),
          ($dv.status.phase // "N/A"),
          ($dv.status.progress // "N/A"),
          (
            $pvc.spec.resources.requests.storage //
            $pvc.status.capacity.storage //
            .metadata.annotations["kubevirt.io/disk-size"] //
            $dv.spec.storage.resources.requests.storage //
            "?"
          )
        ] | @tsv
    ')
    IFS=$'\t' read -r vm_status vmi_phase vm_ip cpu_cores memory ssh_port start_port end_port password password_stored system dv_phase dv_progress disk_size <<< "$detail_line"

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
    if [ "$password" = "?" ] && [ "$password_stored" = "false" ]; then
        password="未存储（创建时未启用 STORE_PASSWORD_ANNOTATION）"
    elif [ "$password" != "?" ] && ! _is_truthy "${SHOW_PASSWORD:-}"; then
        password="******（设置 SHOW_PASSWORD=true 显示）"
    fi
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

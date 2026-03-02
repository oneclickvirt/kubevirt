#!/bin/bash
# =====================================================================
# KubeVirt 批量虚拟机开设脚本（交互式）
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

check_root() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi
}

check_onevm_script() {
    # 优先使用当前目录的 onevm.sh，否则下载
    if [ -f "$(dirname "$0")/onevm.sh" ]; then
        ONEVM_SCRIPT="$(dirname "$0")/onevm.sh"
    elif [ -f "./onevm.sh" ]; then
        ONEVM_SCRIPT="./onevm.sh"
    else
        _info "正在下载 onevm.sh..."
        curl -sSL -o /tmp/onevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh
        chmod +x /tmp/onevm.sh
        ONEVM_SCRIPT="/tmp/onevm.sh"
    fi
    _info "使用脚本：$ONEVM_SCRIPT"
}

# ===== 交互式参数收集 =====
collect_params() {
    echo ""
    echo "======================================================"
    echo -e "${GREEN}  KubeVirt 批量虚拟机开设${NC}"
    echo "======================================================"
    echo ""

    # 数量
    read -rp "请输入虚拟机数量 [默认: 1]: " VM_COUNT
    VM_COUNT="${VM_COUNT:-1}"
    if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [ "$VM_COUNT" -lt 1 ]; then
        _error "数量无效：$VM_COUNT"
    fi

    # 名称前缀和起始编号
    read -rp "请输入虚拟机名称前缀 [默认: vm]: " VM_PREFIX
    VM_PREFIX="${VM_PREFIX:-vm}"
    if ! echo "$VM_PREFIX" | grep -qE '^[a-z][a-z0-9-]*$'; then
        _error "名称前缀无效，只允许小写字母、数字和连字符，且必须以字母开头"
    fi

    read -rp "请输入起始编号 [默认: 1]: " START_NUM
    START_NUM="${START_NUM:-1}"

    # CPU
    read -rp "请输入每台虚拟机 CPU 核数 [默认: 1]: " CPU
    CPU="${CPU:-1}"

    # 内存
    read -rp "请输入每台虚拟机内存（GB）[默认: 1]: " MEMORY_GB
    MEMORY_GB="${MEMORY_GB:-1}"

    # 磁盘
    read -rp "请输入每台虚拟机磁盘大小（GB）[默认: 10]: " DISK_GB
    DISK_GB="${DISK_GB:-10}"

    # 密码
    read -rp "请输入 root 密码 [默认: 随机生成]: " PASSWORD
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(tr -dc 'A-Za-z0-9!@#$' </dev/urandom | head -c 16 2>/dev/null || \
                   cat /dev/urandom | tr -dc 'A-Za-z0-9' | fold -w 12 | head -n 1)
        _info "生成随机密码：${PASSWORD}"
    fi

    # SSH 起始端口
    read -rp "请输入 SSH 起始端口 [默认: 25000]: " SSH_START_PORT
    SSH_START_PORT="${SSH_START_PORT:-25000}"

    # 额外端口范围（每台 VM 的端口数）
    read -rp "请输入每台 VM 的额外端口范围大小（0=不分配）[默认: 26]: " PORT_RANGE_SIZE
    PORT_RANGE_SIZE="${PORT_RANGE_SIZE:-26}"

    # 起始额外端口
    if [ "$PORT_RANGE_SIZE" -gt 0 ]; then
        read -rp "请输入额外端口起始值 [默认: 35000]: " EXTRA_PORT_START
        EXTRA_PORT_START="${EXTRA_PORT_START:-35000}"
    fi

    # 操作系统
    echo ""
    echo "可选操作系统："
    echo "  1) ubuntu       - Ubuntu 22.04 LTS"
    echo "  2) debian       - Debian 12"
    echo "  3) debian11     - Debian 11"
    echo "  4) almalinux    - AlmaLinux 9"
    echo "  5) rockylinux   - RockyLinux 9"
    echo "  6) centos       - CentOS 7"
    echo "  7) centos8-stream - CentOS Stream 8"
    echo "  8) centos-stream  - CentOS Stream 9"
    echo "  9) opensuse     - openSUSE Leap 15.5"
    echo ""
    echo "  镜像优先从 oneclickvirt/pve_kvm_images 和 oneclickvirt/kvm_images 获取"
    read -rp "请选择系统编号或输入系统名称 [默认: 1/ubuntu]: " SYSTEM_INPUT
    SYSTEM_INPUT="${SYSTEM_INPUT:-1}"

    case "$SYSTEM_INPUT" in
        1|ubuntu)        SYSTEM="ubuntu" ;;
        2|debian)        SYSTEM="debian" ;;
        3|debian11)      SYSTEM="debian11" ;;
        4|almalinux)     SYSTEM="almalinux" ;;
        5|rockylinux)    SYSTEM="rockylinux" ;;
        6|centos)        SYSTEM="centos" ;;
        7|centos8-stream|centos8) SYSTEM="centos8-stream" ;;
        8|centos-stream|centos9)  SYSTEM="centos-stream" ;;
        9|opensuse)      SYSTEM="opensuse" ;;
        *) _error "无效的系统选择：$SYSTEM_INPUT" ;;
    esac

    # 确认
    echo ""
    echo "======================================================"
    echo "  批量创建配置预览："
    echo "  数量:         ${VM_COUNT} 台"
    echo "  名称范围:     ${VM_PREFIX}${START_NUM} ~ ${VM_PREFIX}$((START_NUM + VM_COUNT - 1))"
    echo "  CPU:          ${CPU} 核 / 台"
    echo "  内存:         ${MEMORY_GB} GB / 台"
    echo "  磁盘:         ${DISK_GB} GB / 台"
    echo "  系统:         ${SYSTEM}"
    echo "  密码:         ${PASSWORD}"
    echo "  SSH 端口范围: ${SSH_START_PORT} ~ $((SSH_START_PORT + VM_COUNT - 1))"
    if [ "$PORT_RANGE_SIZE" -gt 0 ]; then
        echo "  额外端口:     ${EXTRA_PORT_START} ~ $((EXTRA_PORT_START + VM_COUNT * PORT_RANGE_SIZE - 1))"
    fi
    echo "======================================================"
    echo ""
    read -rp "确认创建？(y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        _info "已取消"
        exit 0
    fi
}

# ===== 检查磁盘空间 =====
check_disk_space() {
    local required_gb=$((DISK_GB * VM_COUNT + 5))
    local available_gb
    available_gb=$(df / | tail -1 | awk '{print int($4/1024/1024)}')

    if [ "$available_gb" -lt "$required_gb" ]; then
        _warn "可用磁盘空间 ${available_gb}GB 可能不足（需要约 ${required_gb}GB）"
        read -rp "是否继续？(y/n): " cont
        if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
            exit 0
        fi
    fi
}

# ===== 批量创建 =====
batch_create() {
    local success=0
    local failed=0
    local failed_list=""

    for i in $(seq 0 $((VM_COUNT - 1))); do
        local num=$((START_NUM + i))
        local vm_name="${VM_PREFIX}${num}"
        local ssh_port=$((SSH_START_PORT + i))
        local extra_start=0
        local extra_end=0

        if [ "$PORT_RANGE_SIZE" -gt 0 ]; then
            extra_start=$((EXTRA_PORT_START + i * PORT_RANGE_SIZE))
            extra_end=$((extra_start + PORT_RANGE_SIZE - 1))
        fi

        echo ""
        echo "======================================================"
        _step "创建虚拟机 ${vm_name} (${i+1}/${VM_COUNT})..."
        echo "======================================================"

        if bash "$ONEVM_SCRIPT" \
            "$vm_name" \
            "$CPU" \
            "$MEMORY_GB" \
            "$DISK_GB" \
            "$PASSWORD" \
            "$ssh_port" \
            "$extra_start" \
            "$extra_end" \
            "$SYSTEM"; then
            success=$((success + 1))
            _info "虚拟机 ${vm_name} 创建成功"
        else
            failed=$((failed + 1))
            failed_list="${failed_list} ${vm_name}"
            _warn "虚拟机 ${vm_name} 创建失败，继续创建下一台..."
        fi

        # 多台时稍等，避免资源竞争
        if [ "$VM_COUNT" -gt 1 ] && [ "$i" -lt $((VM_COUNT - 1)) ]; then
            _info "等待 5 秒后创建下一台..."
            sleep 5
        fi
    done

    # 输出汇总
    echo ""
    echo "======================================================"
    echo -e "${GREEN}  批量创建完成！${NC}"
    echo "  成功: ${success} 台"
    echo "  失败: ${failed} 台"
    if [ -n "$failed_list" ]; then
        echo "  失败列表:${failed_list}"
    fi
    echo ""
    echo "  所有连接信息已保存到 vmlog 文件"
    echo ""
    if [ -f "vmlog" ]; then
        echo "  连接摘要："
        cat vmlog | grep -E "^${VM_PREFIX}"
    fi
    echo "======================================================"
}

# ===== 主流程 =====
main() {
    check_root
    check_onevm_script
    collect_params
    check_disk_space
    batch_create
}

main "$@"

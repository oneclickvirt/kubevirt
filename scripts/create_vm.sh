#!/bin/bash
# =====================================================================
# KubeVirt 批量虚拟机开设脚本（支持交互式与环境变量驱动）
# https://github.com/oneclickvirt/kubevirt
# =====================================================================
#
# 支持通过环境变量实现完全无交互批量创建：
#
#   VM_COUNT          虚拟机数量              默认: 1
#   VM_PREFIX         虚拟机名称前缀          默认: vm
#   START_NUM         起始编号               默认: 1
#   CPU               每台 CPU 核数           默认: 1
#   MEMORY_GB         每台内存（GB）           默认: 1
#   DISK_GB           每台磁盘（GB）           默认: 10
#   PASSWORD          root 密码              默认: 随机生成
#   SSH_START_PORT    SSH 起始端口            默认: 25000
#   PORT_RANGE_SIZE   每台额外端口数量         默认: 26
#   EXTRA_PORT_START  额外端口起始值           默认: 35000
#   SYSTEM            操作系统               默认: ubuntu
#   noninteractive=true  跳过所有确认提示，未提供的参数使用默认值
#   AUTO_YES=y           兼容旧版写法，同 noninteractive=true
#   STORE_PASSWORD_ANNOTATION=true  传递给 onevm.sh，将明文密码写入 VM 注解
#   KEEP_FAILED_RESOURCES=true      传递给 onevm.sh，失败时保留现场资源
#
# 示例：
#   VM_COUNT=3 CPU=2 MEMORY_GB=2 DISK_GB=20 PASSWORD=MyPass123 \
#   SSH_START_PORT=25000 PORT_RANGE_SIZE=26 EXTRA_PORT_START=35000 \
#   SYSTEM=debian noninteractive=true bash create_vm.sh
#
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
        if ! curl -fsSL -o /tmp/onevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh; then
            _error "下载 onevm.sh 失败，请检查网络连接"
        fi
        chmod +x /tmp/onevm.sh
        ONEVM_SCRIPT="/tmp/onevm.sh"
    fi
    _info "使用脚本：$ONEVM_SCRIPT"
}

# ===== 无交互模式判断 =====
_is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

_is_noninteractive() {
    _is_truthy "${noninteractive:-}" || \
    _is_truthy "${NONINTERACTIVE:-}" || \
    _is_truthy "${AUTO_YES:-}" || \
    _is_truthy "${FORCE_YES:-}" || \
    ( [ -n "${VM_COUNT+x}" ] && [ -n "${VM_PREFIX+x}" ] && \
      [ -n "${CPU+x}" ] && [ -n "${MEMORY_GB+x}" ] && \
      [ -n "${DISK_GB+x}" ] && [ -n "${PASSWORD+x}" ] && \
      [ -n "${SSH_START_PORT+x}" ] && [ -n "${SYSTEM+x}" ] )
}

_print_vmlog_summary() {
    if [ ! -f "vmlog" ]; then
        return 0
    fi

    if _is_truthy "${SHOW_PASSWORD:-}"; then
        grep -E "^${VM_PREFIX}" vmlog || true
    else
        grep -E "^${VM_PREFIX}" vmlog | sed -E 's/(密码: )[^[:space:]]+/\1******/g' || true
        echo "  （设置 SHOW_PASSWORD=true 显示 vmlog 中的明文密码）"
    fi
}

_validate_uint_range() {
    local name="$1" value="$2" min="$3" max="$4"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        _error "${name} 无效：${value}（必须在 ${min}-${max} 范围内）"
    fi
}

_ranges_overlap() {
    local start_a="$1" end_a="$2" start_b="$3" end_b="$4"
    [ "$start_a" -le "$end_b" ] && [ "$start_b" -le "$end_a" ]
}

validate_params() {
    _validate_uint_range "虚拟机数量" "$VM_COUNT" 1 9999
    _validate_uint_range "起始编号" "$START_NUM" 0 999999
    _validate_uint_range "CPU 核数" "$CPU" 1 256
    _validate_uint_range "内存" "$MEMORY_GB" 1 1048576
    _validate_uint_range "磁盘" "$DISK_GB" 1 1048576
    _validate_uint_range "SSH 起始端口" "$SSH_START_PORT" 1 65535
    _validate_uint_range "额外端口范围大小" "$PORT_RANGE_SIZE" 0 65535

    local ssh_end=$((SSH_START_PORT + VM_COUNT - 1))
    if [ "$ssh_end" -gt 65535 ]; then
        _error "SSH 端口范围越界：${SSH_START_PORT}-${ssh_end}"
    fi

    if [ "$PORT_RANGE_SIZE" -gt 0 ]; then
        _validate_uint_range "额外端口起始值" "$EXTRA_PORT_START" 1 65535
        local extra_end=$((EXTRA_PORT_START + VM_COUNT * PORT_RANGE_SIZE - 1))
        if [ "$extra_end" -gt 65535 ]; then
            _error "额外端口范围越界：${EXTRA_PORT_START}-${extra_end}"
        fi
        if _ranges_overlap "$SSH_START_PORT" "$ssh_end" "$EXTRA_PORT_START" "$extra_end"; then
            _error "SSH 端口范围 ${SSH_START_PORT}-${ssh_end} 与额外端口范围 ${EXTRA_PORT_START}-${extra_end} 重叠"
        fi
    else
        EXTRA_PORT_START="${EXTRA_PORT_START:-0}"
    fi
}

# ===== 交互式参数收集（若环境变量已设置则使用环境变量，跳过 read）=====
collect_params() {
    # 无交互模式下无需打印菜单
    if ! _is_noninteractive; then
        echo ""
        echo "======================================================"
        echo -e "${GREEN}  KubeVirt 批量虚拟机开设${NC}"
        echo "======================================================"
        echo ""
    fi

    # ----- 数量 -----
    if [ -z "${VM_COUNT+x}" ] && ! _is_noninteractive; then
        read -rp "请输入虚拟机数量 [默认: 1]: " VM_COUNT
    fi
    VM_COUNT="${VM_COUNT:-1}"
    if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [ "$VM_COUNT" -lt 1 ]; then
        _error "数量无效：$VM_COUNT"
    fi

    # ----- 名称前缀 -----
    if [ -z "${VM_PREFIX+x}" ] && ! _is_noninteractive; then
        read -rp "请输入虚拟机名称前缀 [默认: vm]: " VM_PREFIX
    fi
    VM_PREFIX="${VM_PREFIX:-vm}"
    if ! echo "$VM_PREFIX" | grep -qE '^[a-z][a-z0-9-]*$'; then
        _error "名称前缀无效，只允许小写字母、数字和连字符，且必须以字母开头"
    fi

    # ----- 起始编号 -----
    if [ -z "${START_NUM+x}" ] && ! _is_noninteractive; then
        read -rp "请输入起始编号 [默认: 1]: " START_NUM
    fi
    START_NUM="${START_NUM:-1}"

    # ----- CPU -----
    if [ -z "${CPU+x}" ] && ! _is_noninteractive; then
        read -rp "请输入每台虚拟机 CPU 核数 [默认: 1]: " CPU
    fi
    CPU="${CPU:-1}"

    # ----- 内存 -----
    if [ -z "${MEMORY_GB+x}" ] && ! _is_noninteractive; then
        read -rp "请输入每台虚拟机内存（GB）[默认: 1]: " MEMORY_GB
    fi
    MEMORY_GB="${MEMORY_GB:-1}"

    # ----- 磁盘 -----
    if [ -z "${DISK_GB+x}" ] && ! _is_noninteractive; then
        read -rp "请输入每台虚拟机磁盘大小（GB）[默认: 10]: " DISK_GB
    fi
    DISK_GB="${DISK_GB:-10}"

    # ----- 密码 -----
    if [ -z "${PASSWORD+x}" ] && ! _is_noninteractive; then
        read -rp "请输入 root 密码 [默认: 随机生成]: " PASSWORD
    fi
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(tr -dc 'A-Za-z0-9!@#$' </dev/urandom | head -c 16 2>/dev/null || \
                   cat /dev/urandom | tr -dc 'A-Za-z0-9' | fold -w 12 | head -n 1)
        _info "生成随机密码：${PASSWORD}"
    fi

    # ----- SSH 起始端口 -----
    if [ -z "${SSH_START_PORT+x}" ] && ! _is_noninteractive; then
        read -rp "请输入 SSH 起始端口 [默认: 25000]: " SSH_START_PORT
    fi
    SSH_START_PORT="${SSH_START_PORT:-25000}"

    # ----- 额外端口范围大小 -----
    if [ -z "${PORT_RANGE_SIZE+x}" ] && ! _is_noninteractive; then
        read -rp "请输入每台 VM 的额外端口范围大小（0=不分配）[默认: 26]: " PORT_RANGE_SIZE
    fi
    PORT_RANGE_SIZE="${PORT_RANGE_SIZE:-26}"
    _validate_uint_range "额外端口范围大小" "$PORT_RANGE_SIZE" 0 65535

    # ----- 额外端口起始值 -----
    if [ "$PORT_RANGE_SIZE" -gt 0 ]; then
        if [ -z "${EXTRA_PORT_START+x}" ] && ! _is_noninteractive; then
            read -rp "请输入额外端口起始值 [默认: 35000]: " EXTRA_PORT_START
        fi
        EXTRA_PORT_START="${EXTRA_PORT_START:-35000}"
    fi

    # ----- 操作系统 -----
    if [ -z "${SYSTEM+x}" ] && ! _is_noninteractive; then
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
        echo "  10) ubuntu24    - Ubuntu 24.04 LTS"
        echo ""
        echo "  镜像优先从 oneclickvirt/pve_kvm_images 和 oneclickvirt/kvm_images 获取"
        read -rp "请选择系统编号或输入系统名称 [默认: 1/ubuntu]: " SYSTEM_INPUT
        SYSTEM_INPUT="${SYSTEM_INPUT:-1}"
    else
        SYSTEM_INPUT="${SYSTEM:-ubuntu}"
    fi

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
        10|ubuntu24|ubuntu2404) SYSTEM="ubuntu24" ;;
        *) _error "无效的系统选择：$SYSTEM_INPUT" ;;
    esac

    validate_params

    # ----- 配置预览 -----
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
    if [ "${PORT_RANGE_SIZE:-0}" -gt 0 ]; then
        echo "  额外端口:     ${EXTRA_PORT_START} ~ $((EXTRA_PORT_START + VM_COUNT * PORT_RANGE_SIZE - 1))"
    fi
    echo "======================================================"
    echo ""

    # ----- 最终确认 -----
    if ! _is_noninteractive; then
        read -rp "确认创建？(y/n): " CONFIRM
        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            _info "已取消"
            exit 0
        fi
    fi
}

# ===== 检查磁盘空间 =====
check_disk_space() {
    local required_gb=$((DISK_GB * VM_COUNT + 5))
    local available_gb
    available_gb=$(df / | tail -1 | awk '{print int($4/1024/1024)}')

    if [ "$available_gb" -lt "$required_gb" ]; then
        _warn "可用磁盘空间 ${available_gb}GB 可能不足（需要约 ${required_gb}GB）"
        if ! _is_noninteractive; then
            read -rp "是否继续？(y/n): " cont
            if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
                exit 0
            fi
        else
            _warn "noninteractive=true，忽略磁盘空间警告，继续执行..."
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

        if env \
            noninteractive="${noninteractive:-true}" \
            STORE_PASSWORD_ANNOTATION="${STORE_PASSWORD_ANNOTATION:-}" \
            KEEP_FAILED_RESOURCES="${KEEP_FAILED_RESOURCES:-}" \
            bash "$ONEVM_SCRIPT" \
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
    if [ "$success" -gt 0 ]; then
        echo "  成功创建的连接信息已保存到 vmlog 文件"
    else
        echo "  未成功创建虚拟机，未写入新的连接信息"
    fi
    echo ""
    if [ -f "vmlog" ]; then
        echo "  连接摘要："
        _print_vmlog_summary
    fi
    echo "======================================================"

    [ "$failed" -eq 0 ]
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

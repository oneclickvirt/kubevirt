#!/bin/bash
# =====================================================================
# KubeVirt 单个虚拟机开设脚本
# 用法: ./onevm.sh <name> <cpu> <memory_gb> <disk_gb> <password> <sshport> <startport> <endport> [system]
# https://github.com/oneclickvirt/kubevirt
# =====================================================================
#
# 也可通过环境变量提供参数（命令行参数优先）：
#
#   noninteractive=true  统一无交互标记（本脚本本身不读取交互输入）
#   VM_NAME      虚拟机名称      （必须或位置参数1）
#   CPU          CPU 核数        默认: 1
#   MEMORY_GB    内存（GB）       默认: 1
#   DISK_GB      磁盘（GB）       默认: 10
#   PASSWORD     root 密码       默认: 123456
#   SSH_PORT     SSH 宿主机端口   默认: 25000
#   START_PORT   额外端口起始     默认: 34975
#   END_PORT     额外端口结束     默认: 35000
#   SYSTEM       操作系统        默认: ubuntu
#   STORE_PASSWORD_ANNOTATION=true  将明文密码写入 VM 注解（默认不写入）
#
# 示例：
#   ./onevm.sh vm1 2 2 20 MyPass 25000 34975 35000 debian
#   VM_NAME=vm1 CPU=2 MEMORY_GB=2 DISK_GB=20 PASSWORD=MyPass \
#   SSH_PORT=25000 START_PORT=34975 END_PORT=35000 SYSTEM=debian \
#   bash onevm.sh
#
# =====================================================================

set -o pipefail

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

_validate_uint_range() {
    local name="$1" value="$2" min="$3" max="$4"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        _error "${name} 无效：${value}（必须在 ${min}-${max} 范围内）"
    fi
}

_is_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

_port_in_range() {
    local port="$1" start="$2" end="$3"
    [ "$start" != "0" ] && [ "$end" != "0" ] && [ "$port" -ge "$start" ] && [ "$port" -le "$end" ]
}

_ranges_overlap() {
    local start_a="$1" end_a="$2" start_b="$3" end_b="$4"
    [ "$start_a" != "0" ] && [ "$end_a" != "0" ] && \
    [ "$start_b" != "0" ] && [ "$end_b" != "0" ] && \
    [ "$start_a" -le "$end_b" ] && [ "$start_b" -le "$end_a" ]
}

# ===== 环境变量 =====
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"

# ===== 加载防火墙库 =====
FIREWALL_LIB="/usr/local/lib/kubevirt/firewall.sh"
if [ ! -f "$FIREWALL_LIB" ]; then
    _error "防火墙库未找到: $FIREWALL_LIB\n请先运行安装脚本"
fi
source "$FIREWALL_LIB"

# ===== 参数解析（命令行参数优先，否则回退到同名环境变量）=====
parse_args() {
    VM_NAME="${1:-${VM_NAME:-test}}"
    CPU="${2:-${CPU:-1}}"
    MEMORY_GB="${3:-${MEMORY_GB:-1}}"
    DISK_GB="${4:-${DISK_GB:-10}}"
    PASSWORD="${5:-${PASSWORD:-123456}}"
    SSH_PORT="${6:-${SSH_PORT:-25000}}"
    START_PORT="${7:-${START_PORT:-34975}}"
    END_PORT="${8:-${END_PORT:-35000}}"
    SYSTEM="${9:-${SYSTEM:-ubuntu}}"

    # 转换为小写
    SYSTEM=$(echo "$SYSTEM" | tr '[:upper:]' '[:lower:]')

    # 验证 VM 名称（只允许小写字母、数字、连字符）
    if ! echo "$VM_NAME" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'; then
        _error "VM 名称只允许小写字母、数字和连字符，且不能以连字符开头或结尾：$VM_NAME"
    fi

    _validate_uint_range "CPU 核数" "$CPU" 1 256
    _validate_uint_range "内存" "$MEMORY_GB" 1 1048576
    _validate_uint_range "磁盘" "$DISK_GB" 1 1048576
    _validate_uint_range "SSH 端口" "$SSH_PORT" 1 65535

    # 允许 startport/endport 为 0（表示不分配额外端口）
    if [ "$START_PORT" != "0" ] || [ "$END_PORT" != "0" ]; then
        if { [ "$START_PORT" = "0" ] && [ "$END_PORT" != "0" ]; } || \
           { [ "$START_PORT" != "0" ] && [ "$END_PORT" = "0" ]; }; then
            _error "起始端口和结束端口必须同时为 0 或同时非零"
        fi
        for port in "$START_PORT" "$END_PORT"; do
            _validate_uint_range "端口" "$port" 0 65535
        done
    fi

    if [ "$START_PORT" -gt "$END_PORT" ]; then
        _error "起始端口 ($START_PORT) 不能大于结束端口 ($END_PORT)"
    fi
    if _port_in_range "$SSH_PORT" "$START_PORT" "$END_PORT"; then
        _error "SSH 端口 ${SSH_PORT} 不能落在额外端口范围 ${START_PORT}-${END_PORT} 内"
    fi

    _info "虚拟机配置："
    echo "  名称:     $VM_NAME"
    echo "  CPU:      ${CPU} 核"
    echo "  内存:     ${MEMORY_GB} GB"
    echo "  磁盘:     ${DISK_GB} GB"
    echo "  系统:     $SYSTEM"
    echo "  SSH 端口: $SSH_PORT"
    echo "  端口范围: ${START_PORT}-${END_PORT}"
    echo ""
}

# ===== 检查前置条件 =====
check_prerequisites() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi

    if ! command -v kubectl >/dev/null 2>&1 && ! command -v k3s >/dev/null 2>&1; then
        _error "未找到 kubectl/k3s，请先运行安装脚本"
    fi

    # 确保 kubectl 可用
    if ! command -v kubectl >/dev/null 2>&1; then
        kubectl() { k3s kubectl "$@"; }
    fi

    if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
        _warn "命名空间 $NS 不存在，正在创建..."
        kubectl create namespace "$NS"
    fi

    # 检查 VM 是否已存在
    if kubectl get vm "$VM_NAME" -n "$NS" >/dev/null 2>&1; then
        _error "虚拟机 '$VM_NAME' 已存在，请先删除或使用其他名称"
    fi

    # 检查 SSH 端口是否已被占用
    if ss -tlnp "sport = :${SSH_PORT}" 2>/dev/null | grep -q LISTEN; then
        _warn "端口 $SSH_PORT 在宿主机上已被占用，可能导致冲突"
    fi

    check_port_conflicts

    # 检测 KVM / 模拟模式
    _detect_emulation_mode
}

_check_port_record() {
    local source="$1" existing_name="$2" existing_ssh="$3" existing_start="${4:-0}" existing_end="${5:-0}"

    [ -z "$existing_name" ] && return 0
    [ "$existing_name" = "$VM_NAME" ] && return 0
    existing_ssh="${existing_ssh:-0}"
    existing_start="${existing_start:-0}"
    existing_end="${existing_end:-0}"
    [[ "$existing_ssh" =~ ^[0-9]+$ ]] || existing_ssh=0
    [[ "$existing_start" =~ ^[0-9]+$ ]] || existing_start=0
    [[ "$existing_end" =~ ^[0-9]+$ ]] || existing_end=0

    if [ "$existing_ssh" -gt 0 ] && [ "$SSH_PORT" -eq "$existing_ssh" ]; then
        _error "SSH 端口 ${SSH_PORT} 已被虚拟机 ${existing_name} 使用（来源：${source}）"
    fi
    if _port_in_range "$SSH_PORT" "$existing_start" "$existing_end"; then
        _error "SSH 端口 ${SSH_PORT} 与虚拟机 ${existing_name} 的额外端口范围 ${existing_start}-${existing_end} 冲突（来源：${source}）"
    fi
    if [ "$existing_ssh" -gt 0 ] && _port_in_range "$existing_ssh" "$START_PORT" "$END_PORT"; then
        _error "额外端口范围 ${START_PORT}-${END_PORT} 包含虚拟机 ${existing_name} 的 SSH 端口 ${existing_ssh}（来源：${source}）"
    fi
    if _ranges_overlap "$START_PORT" "$END_PORT" "$existing_start" "$existing_end"; then
        _error "额外端口范围 ${START_PORT}-${END_PORT} 与虚拟机 ${existing_name} 的端口范围 ${existing_start}-${existing_end} 重叠（来源：${source}）"
    fi
}

check_port_conflicts() {
    _step "检查端口映射冲突..."

    if [ -f "${KUBEVIRT_PORT_RULES:-}" ]; then
        while IFS=' ' read -r existing_name _vm_ip existing_ssh existing_start existing_end _vm_ip6; do
            [[ "$existing_name" =~ ^# || -z "$existing_name" ]] && continue
            _check_port_record "port-rules.conf" "$existing_name" "$existing_ssh" "$existing_start" "$existing_end"
        done < "$KUBEVIRT_PORT_RULES"
    fi

    if command -v jq >/dev/null 2>&1; then
        local records
        records=$(kubectl get vm -n "$NS" -o json 2>/dev/null | jq -r '
            .items[]? |
            [
              .metadata.name,
              (.metadata.annotations["kubevirt.io/ssh-port"] // "0"),
              (.metadata.annotations["kubevirt.io/start-port"] // "0"),
              (.metadata.annotations["kubevirt.io/end-port"] // "0")
            ] | @tsv
        ' 2>/dev/null || true)

        while IFS=$'\t' read -r existing_name existing_ssh existing_start existing_end; do
            [ -z "$existing_name" ] && continue
            _check_port_record "VM 注解" "$existing_name" "$existing_ssh" "$existing_start" "$existing_end"
        done <<< "$records"
    else
        _warn "未找到 jq，跳过基于 VM 注解的端口冲突补充检查"
    fi

    _info "端口映射冲突检查通过"
}

get_host_ip() {
    local host_ip
    host_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    if [ -z "$host_ip" ]; then
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$host_ip" ]; then
        host_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)
    fi
    printf '%s\n' "${host_ip:-<宿主机IP>}"
}

# ===== 检测 KVM 硬件虚拟化或 QEMU TCG 模拟 =====
_detect_emulation_mode() {
    USE_EMULATION=0
    local kv_emulation
    kv_emulation=$(kubectl get kubevirt kubevirt -n kubevirt \
        -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}' 2>/dev/null || echo "")
    if [ "$kv_emulation" = "true" ]; then
        USE_EMULATION=1
        _warn "KubeVirt 处于 QEMU TCG 软件模拟模式（无 KVM），性能较低"
    elif [ ! -e /dev/kvm ]; then
        USE_EMULATION=1
        _warn "/dev/kvm 不存在，当前可能使用 QEMU TCG 模拟"
    else
        _info "KVM 硬件虚拟化可用"
    fi
}

# ===== CDN 列表（参考 oneclickvirt/pve 项目） =====
CDN_PREFIX=""
_CDN_LIST=(
    "https://cdn0.spiritlhl.top/"
    "http://cdn1.spiritlhl.net/"
    "http://cdn2.spiritlhl.net/"
    "http://cdn3.spiritlhl.net/"
    "http://cdn4.spiritlhl.net/"
)

# 测试 CDN 可用性，设置 CDN_PREFIX
check_cdn() {
    local test_raw="https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    for cdn in "${_CDN_LIST[@]}"; do
        if curl -4 -sL -k "${cdn}${test_raw}" --max-time 6 2>/dev/null | grep -q "success"; then
            CDN_PREFIX="$cdn"
            _info "CDN 加速可用：$cdn"
            return 0
        fi
    done
    CDN_PREFIX=""
    _warn "CDN 加速不可用，将直连 GitHub"
    return 1
}

# 检查 URL 是否可访问（HEAD 请求）
_url_accessible() {
    local url="$1"
    curl -sfI --max-time 12 --retry 1 "$url" >/dev/null 2>&1
}

# ===== 获取 oneclickvirt 组织镜像版本标识映射 =====
# 参数: $1=标准化后的系统名，返回对应的 org 镜像版本字符串
get_org_image_ver() {
    local sys="$1"
    case "$sys" in
        ubuntu)         echo "ubuntu22" ;;
        ubuntu24)       echo "ubuntu24" ;;
        debian)         echo "debian12" ;;
        debian11)       echo "debian11" ;;
        almalinux)      echo "almalinux9" ;;
        rockylinux)     echo "rockylinux9" ;;
        centos)         echo "centos7" ;;
        centos8-stream) echo "centos8-stream" ;;
        centos9-stream) echo "" ;;
        opensuse)       echo "opensuse-leap-15" ;;
        *)              echo "" ;;
    esac
}

# 尝试从 oneclickvirt/pve_kvm_images 获取镜像 URL（最高优先级）
# 直接按已知 URL 模式尝试，不依赖 GitHub API
# 参数: $1=版本标识（如 debian12），$2=系统分类（如 debian），结果写入 IMAGE_URL
_find_in_pve_kvm_images() {
    local ver="$1"
    local sys="$2"

    _info "尝试 oneclickvirt/pve_kvm_images for ${ver}..."
    local candidate_urls=(
        "https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${ver}.qcow2"
        "https://github.com/oneclickvirt/pve_kvm_images/releases/download/${sys}/${ver}.qcow2"
    )

    for base_url in "${candidate_urls[@]}"; do
        _info "  尝试: ${base_url}"
        local try_url="${CDN_PREFIX}${base_url}"
        if _url_accessible "$try_url"; then
            IMAGE_URL="$try_url"
            _info "pve_kvm_images 中找到镜像 (CDN)：${base_url##*/}"
            return 0
        fi
        if _url_accessible "$base_url"; then
            IMAGE_URL="$base_url"
            _info "pve_kvm_images 中找到镜像 (直连)：${base_url##*/}"
            return 0
        fi
    done
    return 1
}

# 尝试从 oneclickvirt/kvm_images 获取镜像 URL（第二优先级）
# release tag 与文件名均为版本标识，如 debian12/debian12.qcow2
# 参数: $1=版本标识（如 debian12），结果写入 IMAGE_URL
_find_in_kvm_images() {
    local ver="$1"

    _info "尝试 oneclickvirt/kvm_images for ${ver}..."
    local base_url="https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${ver}.qcow2"
    local try_url="${CDN_PREFIX}${base_url}"

    if _url_accessible "$try_url"; then
        IMAGE_URL="$try_url"
        _info "kvm_images 中找到镜像 (CDN)：${ver}.qcow2"
        return 0
    fi
    if _url_accessible "$base_url"; then
        IMAGE_URL="$base_url"
        _info "kvm_images 中找到镜像 (直连)：${ver}.qcow2"
        return 0
    fi
    return 1
}

# ===== 获取云镜像 URL =====
# 优先顺序：oneclickvirt/pve_kvm_images → oneclickvirt/kvm_images → 官方上游
get_image_url() {
    IMAGE_URL=""
    local official_url org_ver

    # 标准化系统名，设置 IMAGE_OS 和官方上游回退 URL
    case "$SYSTEM" in
        ubuntu|ubuntu2204|ubuntu22)
            IMAGE_OS="ubuntu"
            SYSTEM="ubuntu"
            official_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
            ;;
        ubuntu24|ubuntu2404)
            IMAGE_OS="ubuntu"
            SYSTEM="ubuntu24"
            official_url="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
            ;;
        debian|debian12)
            IMAGE_OS="debian"
            SYSTEM="debian"
            official_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
            ;;
        debian11)
            IMAGE_OS="debian"
            SYSTEM="debian11"
            official_url="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
            ;;
        almalinux|alma|almalinux9)
            IMAGE_OS="almalinux"
            SYSTEM="almalinux"
            official_url="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
            ;;
        rockylinux|rocky|rockylinux9)
            IMAGE_OS="rockylinux"
            SYSTEM="rockylinux"
            official_url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
            ;;
        centos|centos7)
            IMAGE_OS="centos"
            SYSTEM="centos"
            official_url="https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2"
            ;;
        centos8|centos8-stream|centos-stream8)
            IMAGE_OS="centos"
            SYSTEM="centos8-stream"
            official_url="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-latest.x86_64.qcow2"
            ;;
        centos9|centosstream9|centos-stream|centos-stream9)
            IMAGE_OS="centos"
            SYSTEM="centos9-stream"
            official_url="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
            ;;
        opensuse|suse|opensuse15|opensuselap|opensuse-leap)
            IMAGE_OS="opensuse"
            SYSTEM="opensuse"
            official_url="https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.x86_64-Cloud.qcow2"
            ;;
        *)
            _error "不支持的系统：$SYSTEM\n支持：ubuntu, debian, debian11, almalinux, rockylinux, centos, centos8-stream, centos9-stream, opensuse"
            ;;
    esac

    # 检测 CDN 可用性
    check_cdn || true

    _step "解析镜像地址（优先顺序：pve_kvm_images → kvm_images → 官方上游）..."

    # 获取组织镜像版本标识
    org_ver=$(get_org_image_ver "$SYSTEM")

    # 第1优先：pve_kvm_images（直接按已知 URL 模式，不调用 GitHub API）
    if [ -n "$org_ver" ] && _find_in_pve_kvm_images "$org_ver" "$IMAGE_OS"; then
        _info "使用来源：oneclickvirt/pve_kvm_images"
        _info "镜像地址：$IMAGE_URL"
        return 0
    fi

    # 第2优先：kvm_images（release tag 与文件名均为版本标识）
    if [ -n "$org_ver" ] && _find_in_kvm_images "$org_ver"; then
        _info "使用来源：oneclickvirt/kvm_images"
        _info "镜像地址：$IMAGE_URL"
        return 0
    fi

    # 最终回退：官方上游地址（兜底）
    _warn "oneclickvirt 镜像源均不可用，回退到官方上游地址"
    IMAGE_URL="$official_url"
    _info "使用来源：官方上游"
    _info "镜像地址：$IMAGE_URL"
}

# ===== 创建 cloud-init 密钥 =====
create_cloudinit_secret() {
    _step "创建 cloud-init 配置..."

    local SECRET_NAME="${VM_NAME}-cloudinit"
    kubectl delete secret "$SECRET_NAME" -n "$NS" 2>/dev/null || true

    # Base64 编码密码以避免 YAML 转义问题
    local pw_b64
    pw_b64=$(printf '%s' "$PASSWORD" | base64 -w0)

    # 创建初始化脚本，安全地设置密码和 SSH
    local init_script
    init_script=$(cat <<INITSCRIPT
#!/bin/sh
pw=\$(printf '%s' '${pw_b64}' | base64 -d)
echo "root:\${pw}" | chpasswd
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\\nPasswordAuthentication yes\\n' > /etc/ssh/sshd_config.d/99-kubevirt.conf
sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
rm -f /tmp/.kubevirt-init.sh
INITSCRIPT
)

    local init_b64
    init_b64=$(printf '%s' "$init_script" | base64 -w0)

    local user_data="#cloud-config
hostname: ${VM_NAME}
users:
  - name: root
    lock_passwd: false
ssh_pwauth: true
disable_root: false
write_files:
  - path: /tmp/.kubevirt-init.sh
    permissions: '0700'
    encoding: b64
    content: ${init_b64}
runcmd:
  - /tmp/.kubevirt-init.sh
timezone: Asia/Shanghai"

    if ! kubectl create secret generic "$SECRET_NAME" \
        -n "$NS" \
        --from-literal=userdata="$user_data"; then
        _error "cloud-init Secret 创建失败：${SECRET_NAME}"
    fi

    _info "cloud-init 配置已创建"
}

# ===== 创建 DataVolume =====
create_datavolume() {
    _step "创建数据卷（开始下载镜像）..."

    local DV_NAME="${VM_NAME}-dv"
    local DISK_SIZE="${DISK_GB}Gi"

    # 删除已存在的 DataVolume
    kubectl delete datavolume "$DV_NAME" -n "$NS" 2>/dev/null || true
    sleep 2

    if ! cat <<EOF | kubectl apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${DV_NAME}
  namespace: ${NS}
  labels:
    kubevirt.io/vm: ${VM_NAME}
    app: kubevirt-vm
spec:
  source:
    http:
      url: "${IMAGE_URL}"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${DISK_SIZE}
    storageClassName: local-path
EOF
    then
        cleanup_failed_vm_resources
        _error "DataVolume ${DV_NAME} 创建失败"
    fi

    _info "DataVolume ${DV_NAME} 创建成功，开始下载镜像..."
    _info "使用 'kubectl get dv ${DV_NAME} -n ${NS}' 查看下载进度"
}

# ===== 创建 VirtualMachine =====
create_virtualmachine() {
    _step "创建 VirtualMachine 资源..."

    local MEMORY="${MEMORY_GB}Gi"
    local CPU_CORES="${CPU}"
    local DV_NAME="${VM_NAME}-dv"
    local SECRET_NAME="${VM_NAME}-cloudinit"

    if ! cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NS}
  labels:
    app: kubevirt-vm
    kubevirt.io/vm: ${VM_NAME}
    vm-system: ${IMAGE_OS}
  annotations:
    kubevirt.io/ssh-port: "${SSH_PORT}"
    kubevirt.io/start-port: "${START_PORT}"
    kubevirt.io/end-port: "${END_PORT}"
    kubevirt.io/disk-size: "${DISK_GB}Gi"
    kubevirt.io/password-stored: "false"
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM_NAME}
        app: kubevirt-vm
    spec:
      domain:
        cpu:
          cores: ${CPU_CORES}
          sockets: 1
          threads: 1
        memory:
          guest: ${MEMORY}
        devices:
          disks:
            - name: datavolumedisk
              disk:
                bus: virtio
              bootOrder: 1
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
          rng: {}
      networks:
        - name: default
          pod: {}
      terminationGracePeriodSeconds: 30
      volumes:
        - name: datavolumedisk
          dataVolume:
            name: ${DV_NAME}
        - name: cloudinitdisk
          cloudInitNoCloud:
            secretRef:
              name: ${SECRET_NAME}
EOF
    then
        cleanup_failed_vm_resources
        _error "VirtualMachine ${VM_NAME} 创建失败"
    fi

    if _is_truthy "${STORE_PASSWORD_ANNOTATION:-}"; then
        _warn "STORE_PASSWORD_ANNOTATION=true，将明文密码写入 VM 注解"
        if ! kubectl annotate vm "$VM_NAME" -n "$NS" --overwrite \
            "kubevirt.io/password=${PASSWORD}" \
            "kubevirt.io/password-stored=true"; then
            _error "VirtualMachine ${VM_NAME} 密码注解写入失败"
        fi
    fi

    _info "VirtualMachine ${VM_NAME} 已创建"
}

cleanup_failed_vm_resources() {
    if _is_truthy "${KEEP_FAILED_RESOURCES:-}"; then
        _warn "KEEP_FAILED_RESOURCES=true，保留失败现场资源用于排查"
        return 0
    fi

    _warn "清理本次创建失败残留资源..."
    kubectl delete vm "$VM_NAME" -n "$NS" --timeout=60s 2>/dev/null || true
    kubectl delete datavolume "${VM_NAME}-dv" -n "$NS" --timeout=60s 2>/dev/null || true
    kubectl delete pvc "${VM_NAME}-dv" -n "$NS" --timeout=60s 2>/dev/null || true
    kubectl delete secret "${VM_NAME}-cloudinit" -n "$NS" 2>/dev/null || true
    if [ -f "$FIREWALL_LIB" ] && command -v fw_remove_vm >/dev/null 2>&1; then
        fw_remove_vm "$VM_NAME" 2>/dev/null || true
    fi
}

# ===== 等待 DataVolume 导入完成 =====
wait_for_datavolume() {
    _step "等待镜像导入完成..."
    local DV_NAME="${VM_NAME}-dv"
    local timeout=1800  # 30 分钟
    local elapsed=0
    local last_progress=""

    _info "正在下载并导入镜像，请耐心等待（可能需要 5-30 分钟，取决于网速）..."

    while true; do
        local phase
        phase=$(kubectl get datavolume "$DV_NAME" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        local progress
        progress=$(kubectl get datavolume "$DV_NAME" -n "$NS" \
            -o jsonpath='{.status.progress}' 2>/dev/null || echo "")

        if [ "$phase" = "Succeeded" ]; then
            echo ""
            _info "镜像导入成功！"
            return 0
        elif [ "$phase" = "Failed" ]; then
            echo ""
            local message
            message=$(kubectl get datavolume "$DV_NAME" -n "$NS" \
                -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "unknown error")
            cleanup_failed_vm_resources
            _error "镜像导入失败：$message\n请检查镜像 URL 是否可访问或磁盘空间是否充足"
        fi

        if [ "$progress" != "$last_progress" ] && [ -n "$progress" ]; then
            echo -e "\r  进度: ${YELLOW}${progress}${NC} (状态: ${phase})        "
            last_progress="$progress"
        else
            echo -n "."
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo ""
            cleanup_failed_vm_resources
            _error "镜像导入超时（${timeout}秒），请检查网络连接和磁盘空间"
        fi
    done
}

# ===== 启动虚拟机 =====
start_vm() {
    _step "启动虚拟机..."

    if command -v virtctl >/dev/null 2>&1; then
        if ! virtctl start "$VM_NAME" -n "$NS"; then
            cleanup_failed_vm_resources
            _error "virtctl 启动 VM 失败：${VM_NAME}"
        fi
    else
        if ! kubectl patch vm "$VM_NAME" -n "$NS" \
            --type merge \
            -p '{"spec":{"running":true}}'; then
            cleanup_failed_vm_resources
            _error "kubectl 启动 VM 失败：${VM_NAME}"
        fi
    fi

    _info "虚拟机启动命令已发送"
}

# ===== 等待虚拟机实例就绪 =====
wait_for_vmi() {
    _step "等待虚拟机实例启动..."
    local timeout=300
    local elapsed=0

    while true; do
        local phase
        phase=$(kubectl get vmi "$VM_NAME" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        if [ "$phase" = "Running" ]; then
            _info "虚拟机实例已运行"
            return 0
        elif [ "$phase" = "Failed" ] || [ "$phase" = "Succeeded" ]; then
            cleanup_failed_vm_resources
            _error "虚拟机实例状态异常：$phase"
        fi

        echo -n "."
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo ""
            cleanup_failed_vm_resources
            _error "虚拟机启动超时（${timeout}秒）\n尝试：kubectl describe vmi $VM_NAME -n $NS"
        fi
    done
    echo ""
}

# ===== 选择虚拟机 IPv4 / IPv6 地址 =====
# Kubernetes does not guarantee the order of ipAddresses in a dual-stack
# cluster. Keep the address families separate so an IPv6-first VMI can never
# be written into an IPv4 DNAT rule.
select_vm_ip_addresses() {
    local candidate
    VM_IP=""
    VM_IP6="-"

    for candidate in "$@"; do
        case "$candidate" in
            ""|null) ;;
            *:*)
                if [ "$VM_IP6" = "-" ]; then
                    VM_IP6="$candidate"
                fi
                ;;
            *.*)
                if [ -z "$VM_IP" ]; then
                    VM_IP="$candidate"
                fi
                ;;
        esac
    done
}

log_selected_vm_ips() {
    local source="$1"
    if [ -n "$VM_IP" ]; then
        _info "${source} IPv4：$VM_IP"
    fi
    if [ "$VM_IP6" != "-" ]; then
        _info "${source} IPv6：$VM_IP6"
    fi
}

# ===== 获取虚拟机 IP（IPv4 + IPv6）=====
get_vm_ip() {
    _step "获取虚拟机内部 IP..."
    local max_retry=60
    local retry=0
    VM_IP=""
    VM_IP6="-"

    while [ "$retry" -lt "$max_retry" ]; do
        # 方法1：从 VMI 状态获取。ipAddress is only the primary address, so
        # include it as a compatibility fallback after the complete list.
        local vmi_ips vmi_primary
        vmi_ips=$(kubectl get vmi "$VM_NAME" -n "$NS" \
            -o jsonpath='{.status.interfaces[0].ipAddresses[*]}' 2>/dev/null || echo "")
        vmi_primary=$(kubectl get vmi "$VM_NAME" -n "$NS" \
            -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
        # shellcheck disable=SC2086 # Kubernetes jsonpath emits a space-separated address list.
        select_vm_ip_addresses $vmi_ips "$vmi_primary"
        if [ -n "$VM_IP" ] || [ "$VM_IP6" != "-" ]; then
            log_selected_vm_ips "虚拟机"
            return 0
        fi

        # 方法2：从 virt-launcher Pod 获取
        local pod_name pod_ips pod_primary
        pod_name=$(kubectl get pod -n "$NS" \
            -l "kubevirt.io/vm=$VM_NAME" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$pod_name" ] && [ "$pod_name" != "null" ]; then
            pod_ips=$(kubectl get pod "$pod_name" -n "$NS" \
                -o jsonpath='{.status.podIPs[*].ip}' 2>/dev/null || echo "")
            pod_primary=$(kubectl get pod "$pod_name" -n "$NS" \
                -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
            # shellcheck disable=SC2086 # Kubernetes jsonpath emits a space-separated address list.
            select_vm_ip_addresses $pod_ips "$pod_primary"
            if [ -n "$VM_IP" ] || [ "$VM_IP6" != "-" ]; then
                log_selected_vm_ips "虚拟机 Pod（通过 virt-launcher 获取）"
                return 0
            fi
        fi

        echo -n "."
        sleep 3
        retry=$((retry + 1))
    done

    echo ""
    _warn "无法获取虚拟机 IP，端口转发将无法配置"
    VM_IP=""
    VM_IP6="-"
    return 1
}

# ===== 配置端口转发 =====
setup_port_forward() {
    _step "配置端口转发..."

    if [ -z "$VM_IP" ] && [ "$VM_IP6" = "-" ]; then
        cleanup_failed_vm_resources
        _error "VM IP 未知，无法配置端口转发"
    fi

    if ! detect_fw_backend; then
        cleanup_failed_vm_resources
        _error "未找到可用防火墙后端，无法配置端口转发"
    fi
    if [ -n "$VM_IP" ]; then
        _info "IPv4 SSH 端口转发：宿主机:${SSH_PORT} → VM:22（后端：${FW_BACKEND}）"
    fi
    if [ "$VM_IP6" != "-" ]; then
        _info "IPv6 SSH 端口转发：宿主机:${SSH_PORT} → VM:22（后端：${FW_BACKEND}）"
    fi
    if [ "$START_PORT" != "0" ] && [ "$END_PORT" != "0" ]; then
        _info "端口范围转发：宿主机:${START_PORT}-${END_PORT} → VM:${START_PORT}-${END_PORT}"
    fi

    if ! fw_add_vm "$VM_NAME" "$VM_IP" "$SSH_PORT" "$START_PORT" "$END_PORT" "$VM_IP6"; then
        cleanup_failed_vm_resources
        _error "端口转发规则配置失败：${VM_NAME}"
    fi

    _info "端口转发规则已配置并持久化"
}

# ===== 保存连接信息到日志 =====
save_vmlog() {
    local log_file="vmlog"

    local HOST_IP
    HOST_IP=$(get_host_ip)

    local log_line="${VM_NAME} root@${HOST_IP}:${SSH_PORT} 密码: ${PASSWORD} 端口范围: ${START_PORT}-${END_PORT} 系统: ${SYSTEM} CPU: ${CPU}核 内存: ${MEMORY_GB}GB 磁盘: ${DISK_GB}GB"

    # 如果已有该 VM 的记录，先删除
    if [ -f "$log_file" ]; then
        sed -i "/^${VM_NAME} /d" "$log_file" 2>/dev/null || true
    fi

    echo "$log_line" >> "$log_file"
    _info "连接信息已保存到 vmlog 文件"
}

# ===== 等待 SSH 可用 =====
wait_for_ssh() {
    _step "等待 SSH 服务就绪（最多 3 分钟）..."
    local HOST_IP
    HOST_IP=$(get_host_ip)
    if [ "$HOST_IP" = "<宿主机IP>" ]; then
        _warn "无法确定宿主机 IP，跳过 SSH 连通性等待"
        return 0
    fi

    local timeout=180
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if timeout 3 bash -c "echo >/dev/tcp/${HOST_IP}/${SSH_PORT}" 2>/dev/null; then
            echo ""
            _info "SSH 服务已就绪"
            return 0
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    _warn "SSH 端口 ${SSH_PORT} 尚未响应，虚拟机可能仍在初始化中（cloud-init 运行中）"
    _warn "请等待 1-2 分钟后再尝试连接"
}

# ===== 输出连接信息 =====
print_connection_info() {
    local HOST_IP
    HOST_IP=$(get_host_ip)

    echo ""
    echo "======================================================"
    echo -e "${GREEN}  虚拟机 ${VM_NAME} 创建成功！${NC}"
    echo "======================================================"
    echo ""
    echo "  连接信息："
    echo -e "  SSH:      ${GREEN}ssh root@${HOST_IP} -p ${SSH_PORT}${NC}"
    echo -e "  密码:     ${YELLOW}${PASSWORD}${NC}"
    echo "  系统:     ${SYSTEM}"
    echo "  CPU:      ${CPU} 核"
    echo "  内存:     ${MEMORY_GB} GB"
    echo "  磁盘:     ${DISK_GB} GB"
    echo ""
    if [ "$START_PORT" != "0" ]; then
        echo "  额外端口: ${START_PORT} - ${END_PORT}"
    fi
    echo ""
    echo "  管理命令："
    echo "  virtctl start ${VM_NAME} -n ${NS}    # 启动"
    echo "  virtctl stop ${VM_NAME} -n ${NS}     # 停止"
    echo "  virtctl restart ${VM_NAME} -n ${NS}  # 重启"
    echo "  virtctl console ${VM_NAME} -n ${NS}  # 进入控制台"
    echo ""
    echo "  注意：首次启动需要 cloud-init 初始化，约 1-2 分钟后 SSH 可用"
    echo "======================================================"
}

# ===== 主流程 =====
main() {
    echo "======================================================"
    echo -e "${GREEN}  KubeVirt 虚拟机创建脚本${NC}"
    echo "  https://github.com/oneclickvirt/kubevirt"
    echo "======================================================"
    echo ""

    parse_args "$@"
    check_prerequisites
    get_image_url
    create_cloudinit_secret
    create_datavolume
    create_virtualmachine
    wait_for_datavolume
    wait_for_vmi
    if ! get_vm_ip; then
        cleanup_failed_vm_resources
        _error "无法获取虚拟机 IP，无法配置端口转发"
    fi
    setup_port_forward
    save_vmlog
    wait_for_ssh
    print_connection_info
}

main "$@"

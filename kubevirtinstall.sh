#!/bin/bash
# =====================================================================
# KubeVirt 一键安装脚本
# 基于 K3s + KubeVirt + CDI 的虚拟机环境
# https://github.com/oneclickvirt/kubevirt
# =====================================================================
#
# 支持通过环境变量实现完全无交互安装：
#
#   noninteractive=true  统一无交互标记
#   K3S_VERSION       K3s 版本          默认: v1.29.3+k3s1
#   KUBEVIRT_VERSION  KubeVirt 版本     默认: v1.2.1
#   CDI_VERSION       CDI 版本          默认: v1.59.0
#   VIRTCTL_VERSION   virtctl 版本      默认: v1.2.1
#   K3S_INSTALL_SCRIPT       本地 K3s 安装脚本路径
#   KUBEVIRT_MANIFEST_DIR    本地 KubeVirt manifest 目录
#   CDI_MANIFEST_DIR         本地 CDI manifest 目录
#   VIRTCTL_BINARY           本地 virtctl 二进制路径
#   KUBEVIRT_SCRIPT_DIR      本地脚本目录（包含 scripts/*.sh 或 *.sh）
#
# 示例（一键无交互安装）：
#   noninteractive=true bash kubevirtinstall.sh
#   noninteractive=true KUBEVIRT_VERSION=v1.3.0 CDI_VERSION=v1.60.0 bash kubevirtinstall.sh
#
# =====================================================================

# ===== 全局非交互模式 =====
export DEBIAN_FRONTEND=noninteractive
set -o pipefail

# ===== 版本配置（支持环境变量覆盖）=====
K3S_VERSION="${K3S_VERSION:-v1.29.3+k3s1}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.1}"
CDI_VERSION="${CDI_VERSION:-v1.59.0}"
VIRTCTL_VERSION="${VIRTCTL_VERSION:-v1.2.1}"

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

# ===== 检查函数 =====
check_root() {
    if [ "$(id -u)" != "0" ]; then
        _error "请以 root 权限运行此脚本"
    fi
}

check_arch() {
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        _error "当前仅支持 x86_64 架构，当前架构：$ARCH"
    fi
    _info "架构检测：$ARCH"
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        _error "无法检测操作系统"
    fi
    case "$OS_ID" in
        ubuntu|debian) _info "操作系统：$PRETTY_NAME" ;;
        *) _warn "未经测试的操作系统：$PRETTY_NAME，将尝试继续安装" ;;
    esac
}

check_kvm() {
    _step "检查 KVM 虚拟化支持..."
    # 检查 CPU 虚拟化标志
    local cpu_flags
    cpu_flags=$(grep -cE '(vmx|svm)' /proc/cpuinfo 2>/dev/null) || true
    cpu_flags="${cpu_flags:-0}"
    if [ "$cpu_flags" -eq 0 ]; then
        _warn "CPU 不支持硬件虚拟化（vmx/svm），可能在嵌套虚拟化环境中"
    fi
    if [ ! -e /dev/kvm ]; then
        _warn "/dev/kvm 不存在，尝试加载 kvm 模块..."
        modprobe kvm 2>/dev/null || true
        modprobe kvm_intel 2>/dev/null || true
        modprobe kvm_amd 2>/dev/null || true
        sleep 1
    fi
    if [ ! -e /dev/kvm ]; then
        _warn "/dev/kvm 不存在，KubeVirt 将使用 QEMU TCG 软件模拟（性能较低）"
        USE_EMULATION=1
    else
        if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
            _warn "/dev/kvm 存在但当前 root 会话不可读写，请检查设备权限和内核模块"
        fi
        _info "KVM 硬件虚拟化可用（嵌套虚拟化或物理机），不修改 /dev/kvm 权限"
        USE_EMULATION=0
    fi
}

check_resources() {
    _step "检查系统资源..."
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    if [ "$TOTAL_MEM_GB" -lt 2 ]; then
        _warn "内存不足 2GB（当前：${TOTAL_MEM_GB}GB），可能影响稳定性"
    else
        _info "内存：${TOTAL_MEM_GB}GB"
    fi

    AVAIL_DISK_GB=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
    if [ "$AVAIL_DISK_GB" -lt 15 ]; then
        _warn "可用磁盘不足 15GB（当前：${AVAIL_DISK_GB}GB），建议至少 20GB"
    else
        _info "可用磁盘：${AVAIL_DISK_GB}GB"
    fi
}

# ===== 依赖安装 =====
install_dependencies() {
    _step "安装基础依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -qq
        apt-get install -y -qq \
            curl wget git jq socat conntrack \
            nftables iptables ebtables ipset iproute2 \
            ca-certificates gnupg lsb-release \
            qemu-utils cloud-image-utils \
            apache2-utils util-linux sshpass 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q \
            curl wget git jq socat conntrack-tools \
            nftables iptables ebtables ipset iproute \
            ca-certificates gnupg qemu-img util-linux sshpass 2>/dev/null || true
    fi
    _info "依赖安装完成"
}

verify_dependencies() {
    _step "校验基础命令依赖..."

    local missing=""
    local cmd
    for cmd in curl jq ss ip awk sed grep base64 flock; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done

    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        missing="${missing} nft-or-iptables"
    fi

    if [ -n "$missing" ]; then
        _error "基础依赖缺失：${missing}。请检查包管理器、软件源或手动安装后重试"
    fi

    _info "基础命令依赖校验通过"
}

# ===== 带重试的下载函数 =====
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retry=3
    local retry=0

    while [ "$retry" -lt "$max_retry" ]; do
        if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$output"; then
            return 0
        fi
        retry=$((retry + 1))
        _warn "下载失败，第 ${retry}/${max_retry} 次重试..."
        sleep $((retry * 5))
    done
    return 1
}

download_or_error() {
    local url="$1"
    local output="$2"
    local label="$3"
    if ! download_with_retry "$url" "$output"; then
        _error "${label} 下载失败：${url}"
    fi
}

use_local_or_download() {
    local url="$1"
    local output="$2"
    local label="$3"
    local local_path="${4:-}"

    if [ -n "$local_path" ]; then
        if [ ! -f "$local_path" ]; then
            _error "${label} 本地文件不存在：${local_path}"
        fi
        cp "$local_path" "$output"
        _info "使用本地 ${label}：${local_path}"
        return 0
    fi

    download_or_error "$url" "$output" "$label"
}

find_local_script() {
    local script_name="$1"
    local local_path=""

    if [ -n "${KUBEVIRT_SCRIPT_DIR:-}" ]; then
        if [ -f "${KUBEVIRT_SCRIPT_DIR}/${script_name}" ]; then
            local_path="${KUBEVIRT_SCRIPT_DIR}/${script_name}"
        elif [ -f "${KUBEVIRT_SCRIPT_DIR}/scripts/${script_name}" ]; then
            local_path="${KUBEVIRT_SCRIPT_DIR}/scripts/${script_name}"
        else
            return 1
        fi
    elif [ -f "./scripts/${script_name}" ]; then
        local_path="./scripts/${script_name}"
    elif [ -f "./${script_name}" ]; then
        local_path="./${script_name}"
    fi

    [ -n "$local_path" ] || return 1
    printf '%s\n' "$local_path"
}

install_helper_script() {
    local script_name="$1"
    local dest="$2"
    local label="$3"
    local url="https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/${script_name}"
    local local_path=""

    local_path=$(find_local_script "$script_name" 2>/dev/null || true)
    if [ -n "${KUBEVIRT_SCRIPT_DIR:-}" ] && [ -z "$local_path" ]; then
        _error "${label} 本地脚本不存在：${KUBEVIRT_SCRIPT_DIR}/${script_name} 或 ${KUBEVIRT_SCRIPT_DIR}/scripts/${script_name}"
    fi

    if [ -n "$local_path" ]; then
        cp "$local_path" "$dest"
        _info "安装本地 ${label}：${local_path} -> ${dest}"
    else
        download_or_error "$url" "$dest" "$label"
    fi
    chmod +x "$dest"
}

print_k3s_diagnostics() {
    _warn "K3s 安装诊断信息："
    if [ -f /tmp/k3s-install-log.txt ]; then
        _warn "最近的 K3s 安装日志："
        tail -40 /tmp/k3s-install-log.txt 2>/dev/null || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status k3s --no-pager -l 2>/dev/null | tail -40 || true
    fi
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u k3s --no-pager -n 40 2>/dev/null || true
    fi
}

print_namespace_diagnostics() {
    local ns="$1"
    local label="$2"
    _warn "${label} 诊断信息（namespace: ${ns}）："
    kubectl get pods -n "$ns" -o wide 2>/dev/null || true
    kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
}

wait_for_k3s_node_ready() {
    local timeout="${K3S_NODE_READY_TIMEOUT:-300}"
    local elapsed=0

    _info "等待 K3s 节点注册（最多 ${timeout} 秒）..."
    while ! k3s kubectl get nodes --no-headers 2>/dev/null | awk 'NF { found=1 } END { exit found ? 0 : 1 }'; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$elapsed" -ge "$timeout" ]; then
            print_k3s_diagnostics
            _error "K3s 节点未在预期时间内注册"
        fi
        echo -n "."
    done
    echo ""

    _info "等待 K3s 节点就绪（最多 ${timeout} 秒）..."
    if ! k3s kubectl wait --for=condition=Ready nodes --all --timeout="${timeout}s"; then
        print_k3s_diagnostics
        _error "K3s 节点未在预期时间内 Ready"
    fi
}

# ===== K3s 安装 =====
install_k3s() {
    _step "安装 K3s（轻量级 Kubernetes）..."

    if command -v k3s >/dev/null 2>&1 && k3s kubectl get nodes >/dev/null 2>&1; then
        _info "K3s 已安装，确认节点就绪..."
        wait_for_k3s_node_ready
        _info "K3s 已安装且运行正常，跳过"
        return 0
    fi

    # 下载 K3s 安装脚本（优先国内镜像，失败回退官方）
    local install_script="/tmp/k3s-install.sh"
    if [ -n "${K3S_INSTALL_SCRIPT:-}" ]; then
        if [ ! -f "$K3S_INSTALL_SCRIPT" ]; then
            _error "本地 K3s 安装脚本不存在：${K3S_INSTALL_SCRIPT}"
        fi
        cp "$K3S_INSTALL_SCRIPT" "$install_script"
        _info "使用本地 K3s 安装脚本：${K3S_INSTALL_SCRIPT}"
    else
        _info "下载 K3s 安装脚本..."
        if ! curl -fsSL --connect-timeout 15 --max-time 60 \
            "https://rancher-mirror.rancher.cn/k3s/k3s-install.sh" -o "$install_script" 2>/dev/null; then
            _warn "国内镜像下载失败，使用官方源..."
            if ! curl -fsSL --connect-timeout 30 --max-time 120 \
                "https://get.k3s.io" -o "$install_script"; then
                _error "K3s 安装脚本下载失败，请检查网络、DNS 或代理配置；也可设置 K3S_INSTALL_SCRIPT 使用本地脚本"
            fi
        fi
    fi
    chmod +x "$install_script"

    # 禁用 traefik，减少资源占用；开放全部端口范围
    _info "执行 K3s 安装..."
    if ! INSTALL_K3S_VERSION="${K3S_VERSION}" \
    sh "$install_script" \
        --disable traefik \
        --disable servicelb \
        --disable metrics-server \
        --kube-apiserver-arg="service-node-port-range=1-65535" \
        --write-kubeconfig-mode 644 \
        2>&1 | tee /tmp/k3s-install-log.txt; then
        print_k3s_diagnostics
        _error "K3s 安装命令失败，请根据以上日志检查网络、权限、内核或 systemd 状态"
    fi

    # 等待 K3s 就绪
    _info "等待 K3s 启动（最多 120 秒）..."
    local timeout=120
    local elapsed=0
    until k3s kubectl get nodes >/dev/null 2>&1; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$elapsed" -ge "$timeout" ]; then
            print_k3s_diagnostics
            _error "K3s 启动超时，请检查日志：journalctl -u k3s"
        fi
        echo -n "."
    done
    echo ""

    wait_for_k3s_node_ready

    # 配置 kubectl 环境变量（幂等）
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    cat > /etc/profile.d/k3s.sh <<'PROFILE'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
alias kubectl="k3s kubectl"
PROFILE
    export PATH=$PATH:/usr/local/bin

    _info "K3s 安装完成"
    k3s kubectl get nodes
}

# ===== kubectl 别名 =====
setup_kubectl() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    # 兼容：如果没有独立的 kubectl，使用 k3s kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
    fi
}

# ===== 安装 KubeVirt =====
install_kubevirt() {
    _step "安装 KubeVirt ${KUBEVIRT_VERSION}..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if kubectl get namespace kubevirt >/dev/null 2>&1; then
        local kv_phase
        kv_phase=$(kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$kv_phase" = "Deployed" ]; then
            _info "KubeVirt 已安装，跳过"
            return 0
        fi
    fi

    local KV_BASE="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"
    local KV_OPERATOR_LOCAL="${KUBEVIRT_OPERATOR_YAML:-${KUBEVIRT_MANIFEST_DIR:+${KUBEVIRT_MANIFEST_DIR}/kubevirt-operator.yaml}}"
    local KV_CR_LOCAL="${KUBEVIRT_CR_YAML:-${KUBEVIRT_MANIFEST_DIR:+${KUBEVIRT_MANIFEST_DIR}/kubevirt-cr.yaml}}"

    # Operator
    _info "下载并部署 KubeVirt Operator..."
    use_local_or_download "${KV_BASE}/kubevirt-operator.yaml" "/tmp/kubevirt-operator.yaml" "KubeVirt Operator" "$KV_OPERATOR_LOCAL"
    if ! kubectl apply -f /tmp/kubevirt-operator.yaml; then
        print_namespace_diagnostics "kubevirt" "KubeVirt Operator apply 失败"
        _error "KubeVirt Operator 部署失败"
    fi

    # 等待 operator 就绪
    _info "等待 KubeVirt Operator 就绪（最多 5 分钟）..."
    if ! kubectl wait --for=condition=Available \
        deployment/virt-operator \
        -n kubevirt \
        --timeout=300s; then
        print_namespace_diagnostics "kubevirt" "KubeVirt Operator 未就绪"
        _error "KubeVirt Operator 未在 5 分钟内就绪"
    fi

    # CR
    _info "下载并部署 KubeVirt CR..."
    use_local_or_download "${KV_BASE}/kubevirt-cr.yaml" "/tmp/kubevirt-cr.yaml" "KubeVirt CR" "$KV_CR_LOCAL"
    if ! kubectl apply -f /tmp/kubevirt-cr.yaml; then
        print_namespace_diagnostics "kubevirt" "KubeVirt CR apply 失败"
        _error "KubeVirt CR 部署失败"
    fi

    # 如果不支持 KVM，启用软件模拟
    if [ "${USE_EMULATION:-0}" = "1" ]; then
        _warn "启用软件模拟（无 KVM）..."
        kubectl patch kubevirt kubevirt -n kubevirt --type merge \
            -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    fi

    # 等待所有 KubeVirt 组件就绪
    _info "等待 KubeVirt 部署完成（最多 10 分钟）..."
    if ! kubectl wait kubevirt kubevirt \
        -n kubevirt \
        --for=condition=Available \
        --timeout=600s; then
        print_namespace_diagnostics "kubevirt" "KubeVirt 未就绪"
        _error "KubeVirt 未在 10 分钟内完成部署"
    fi

    _info "KubeVirt 安装完成"
    kubectl get pods -n kubevirt
}

# ===== 安装 CDI =====
install_cdi() {
    _step "安装 CDI（Containerized Data Importer）${CDI_VERSION}..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if kubectl get namespace cdi >/dev/null 2>&1; then
        local cdi_phase
        cdi_phase=$(kubectl get cdi cdi -n cdi -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$cdi_phase" = "Deployed" ]; then
            _info "CDI 已安装，跳过"
            return 0
        fi
        _warn "检测到 cdi 命名空间但 CDI 未完成部署，将继续应用 manifests"
    fi

    local CDI_BASE="https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}"
    local CDI_OPERATOR_LOCAL="${CDI_OPERATOR_YAML:-${CDI_MANIFEST_DIR:+${CDI_MANIFEST_DIR}/cdi-operator.yaml}}"
    local CDI_CR_LOCAL="${CDI_CR_YAML:-${CDI_MANIFEST_DIR:+${CDI_MANIFEST_DIR}/cdi-cr.yaml}}"

    # Operator
    _info "下载并部署 CDI Operator..."
    use_local_or_download "${CDI_BASE}/cdi-operator.yaml" "/tmp/cdi-operator.yaml" "CDI Operator" "$CDI_OPERATOR_LOCAL"
    if ! kubectl apply -f /tmp/cdi-operator.yaml; then
        print_namespace_diagnostics "cdi" "CDI Operator apply 失败"
        _error "CDI Operator 部署失败"
    fi

    # 等待 operator
    _info "等待 CDI Operator 就绪（最多 5 分钟）..."
    if ! kubectl wait --for=condition=Available \
        deployment/cdi-operator \
        -n cdi \
        --timeout=300s; then
        print_namespace_diagnostics "cdi" "CDI Operator 未就绪"
        _error "CDI Operator 未在 5 分钟内就绪"
    fi

    # CR
    _info "下载并部署 CDI CR..."
    use_local_or_download "${CDI_BASE}/cdi-cr.yaml" "/tmp/cdi-cr.yaml" "CDI CR" "$CDI_CR_LOCAL"
    if ! kubectl apply -f /tmp/cdi-cr.yaml; then
        print_namespace_diagnostics "cdi" "CDI CR apply 失败"
        _error "CDI CR 部署失败"
    fi

    # 等待 CDI 就绪
    _info "等待 CDI 部署完成（最多 5 分钟）..."
    if ! kubectl wait cdi cdi \
        -n cdi \
        --for=condition=Available \
        --timeout=300s; then
        print_namespace_diagnostics "cdi" "CDI 未就绪"
        _error "CDI 未在 5 分钟内完成部署"
    fi

    _info "CDI 安装完成"
    kubectl get pods -n cdi
}

# ===== 安装 virtctl =====
install_virtctl() {
    _step "安装 virtctl 命令行工具..."

    if command -v virtctl >/dev/null 2>&1; then
        _info "virtctl 已安装，跳过"
        return 0
    fi

    local VIRTCTL_URL="https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-amd64"

    if [ -n "${VIRTCTL_BINARY:-}" ]; then
        if [ ! -f "$VIRTCTL_BINARY" ]; then
            _warn "本地 virtctl 二进制不存在：${VIRTCTL_BINARY}"
            return 1
        fi
        cp "$VIRTCTL_BINARY" /usr/local/bin/virtctl
    elif ! curl -fsSL --connect-timeout 30 --max-time 300 "$VIRTCTL_URL" -o /usr/local/bin/virtctl; then
        _warn "从 GitHub 下载 virtctl 失败"
        _warn "可以稍后手动安装，或设置 VIRTCTL_BINARY 使用本地二进制"
        return 1
    fi

    chmod +x /usr/local/bin/virtctl
    _info "virtctl 安装完成：$(virtctl version --client 2>/dev/null | head -1)"
}

# ===== 安装管理脚本 =====
install_management_scripts() {
    _step "安装 KubeVirt 管理脚本..."

    install_helper_script "onevm.sh" "/usr/local/bin/onevm.sh" "单 VM 创建脚本"
    install_helper_script "create_vm.sh" "/usr/local/bin/create_vm.sh" "批量 VM 创建脚本"
    install_helper_script "deletevm.sh" "/usr/local/bin/deletevm.sh" "VM 删除脚本"
    install_helper_script "listvms.sh" "/usr/local/bin/listvms.sh" "VM 查询脚本"
    install_helper_script "update-port-rules.sh" "/usr/local/bin/update-port-rules.sh" "端口规则更新脚本"
    install_helper_script "snapshotvm.sh" "/usr/local/bin/snapshotvm.sh" "VM 快照脚本"
    install_helper_script "resizevm.sh" "/usr/local/bin/resizevm.sh" "VM 资源调整脚本"

    _info "管理脚本安装完成（/usr/local/bin）"
}

# ===== 创建 VM 命名空间 =====
create_vm_namespace() {
    _step "创建虚拟机命名空间..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    kubectl create namespace kubevirt-vms 2>/dev/null || true

    # 添加必要的标签（允许特权容器 - KubeVirt 需要）
    kubectl label namespace kubevirt-vms \
        kubevirt.io=vms \
        --overwrite 2>/dev/null || true

    _info "命名空间 kubevirt-vms 已就绪"
}

# ===== 配置存储类 =====
configure_storage() {
    _step "配置本地存储..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # K3s 默认带有 local-path provisioner，检查是否存在
    if kubectl get storageclass local-path >/dev/null 2>&1; then
        _info "存储类 local-path 已存在"
        # 设为默认存储类
        kubectl patch storageclass local-path \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
            2>/dev/null || true
    else
        _warn "未找到默认存储类，CDI 可能无法正常工作"
    fi
}

# ===== 配置 CDI 上传代理 =====
configure_cdi_proxy() {
    _step "配置 CDI 上传代理..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # 暴露 CDI 上传代理服务（NodePort）
    kubectl patch svc cdi-uploadproxy \
        -n cdi \
        --type='json' \
        -p='[{"op":"replace","path":"/spec/type","value":"NodePort"}]' \
        2>/dev/null || true

    _info "CDI 代理配置完成"
}

# ===== 配置防火墙持久化服务 =====
setup_firewall_service() {
    _step "配置防火墙持久化服务..."

    # 安装防火墙管理库
    mkdir -p /usr/local/lib/kubevirt /etc/kubevirt
    local fw_url="https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/firewall.sh"
    local fw_local=""
    fw_local=$(find_local_script "firewall.sh" 2>/dev/null || true)
    if [ -n "${KUBEVIRT_SCRIPT_DIR:-}" ] && [ -z "$fw_local" ]; then
        _error "防火墙库本地脚本不存在：${KUBEVIRT_SCRIPT_DIR}/firewall.sh 或 ${KUBEVIRT_SCRIPT_DIR}/scripts/firewall.sh"
    fi

    if [ -n "$fw_local" ]; then
        cp "$fw_local" /usr/local/lib/kubevirt/firewall.sh
        _info "安装本地防火墙库：${fw_local} -> /usr/local/lib/kubevirt/firewall.sh"
    elif ! curl -fsSL --connect-timeout 15 --max-time 30 "$fw_url" -o /usr/local/lib/kubevirt/firewall.sh 2>/dev/null; then
        if [ ! -f /usr/local/lib/kubevirt/firewall.sh ]; then
            _error "下载防火墙库失败，请检查网络；也可设置 KUBEVIRT_SCRIPT_DIR 使用本地脚本"
        fi
        _warn "下载防火墙库失败，使用已存在的版本"
    fi
    chmod +x /usr/local/lib/kubevirt/firewall.sh

    # 检测防火墙后端
    source /usr/local/lib/kubevirt/firewall.sh
    if ! detect_fw_backend; then
        _error "未找到可用防火墙后端，请检查 nftables/iptables 是否可用"
    fi
    _info "防火墙后端：${FW_BACKEND}"

    # iptables 后端：安装 iptables-persistent 作为额外持久化
    if [ "$FW_BACKEND" = "iptables" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            _info "安装 iptables-persistent 用于规则持久化（IPv4 + IPv6）..."
            # 预配置避免安装时的交互提示
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent netfilter-persistent 2>/dev/null || true
            # 启用并启动服务
            systemctl enable netfilter-persistent 2>/dev/null || true
            systemctl start netfilter-persistent 2>/dev/null || true
            # 立即保存当前规则（IPv4 + IPv6）
            netfilter-persistent save 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            _info "安装 iptables-services 用于规则持久化（IPv4 + IPv6）..."
            yum install -y -q iptables-services 2>/dev/null || true
            # 立即保存当前规则
            mkdir -p /etc/sysconfig
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
            # 启用并启动服务
            systemctl enable iptables ip6tables 2>/dev/null || true
            systemctl start iptables ip6tables 2>/dev/null || true
        fi
    fi

    # 创建恢复脚本
    cat > /usr/local/bin/kubevirt-restore-rules.sh <<'SCRIPT'
#!/bin/bash
source /usr/local/lib/kubevirt/firewall.sh
detect_fw_backend || exit 1
fw_rebuild
SCRIPT

    # 创建清除脚本
    cat > /usr/local/bin/kubevirt-clear-rules.sh <<'SCRIPT'
#!/bin/bash
source /usr/local/lib/kubevirt/firewall.sh
detect_fw_backend || exit 0
fw_clear_rules
SCRIPT

    chmod +x /usr/local/bin/kubevirt-restore-rules.sh
    chmod +x /usr/local/bin/kubevirt-clear-rules.sh

    # systemd 服务
    cat > /etc/systemd/system/kubevirt-firewall.service <<'EOF'
[Unit]
Description=KubeVirt VM Port Forwarding Rules
After=network.target k3s.service
Wants=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/kubevirt-restore-rules.sh
ExecStop=/usr/local/bin/kubevirt-clear-rules.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable kubevirt-firewall.service 2>/dev/null || true

    _info "防火墙持久化服务配置完成（${FW_BACKEND}）"
}

# ===== 配置 IP 转发 =====
setup_ip_forward() {
    _step "配置 IP 转发（IPv4 + IPv6）..."

    # 启用 IPv4 转发
    echo 1 > /proc/sys/net/ipv4/ip_forward
    # 启用 IPv6 转发
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true

    cat > /etc/sysctl.d/99-kubevirt-ipforward.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-kubevirt-ipforward.conf >/dev/null 2>&1 || true

    _info "IP 转发已启用（IPv4 + IPv6）"
}

# ===== 输出安装摘要 =====
print_summary() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo ""
    echo "======================================================"
    echo -e "${GREEN}  KubeVirt 环境安装完成！${NC}"
    echo "======================================================"
    echo ""
    echo "已安装组件："
    echo "  - K3s:       ${K3S_VERSION}"
    echo "  - KubeVirt:  ${KUBEVIRT_VERSION}"
    echo "  - CDI:       ${CDI_VERSION}"
    echo "  - virtctl:   ${VIRTCTL_VERSION}"
    echo ""
    echo "常用命令："
    echo "  kubectl get vm -n kubevirt-vms          # 查看虚拟机"
    echo "  kubectl get vmi -n kubevirt-vms         # 查看运行中的 VM 实例"
    echo "  kubectl get dv -n kubevirt-vms          # 查看数据卷状态"
    echo "  virtctl console <name> -n kubevirt-vms  # 进入 VM 控制台"
    echo "  onevm.sh vm1 2 2 20 MyPass 25000 34975 35000 debian"
    echo "  create_vm.sh                            # 批量创建 VM"
    echo "  listvms.sh                              # 查看 VM"
    echo "  snapshotvm.sh vm1                       # 创建 DataVolume 克隆快照"
    echo "  resizevm.sh vm1 4 8 40                  # 调整 CPU/内存/磁盘"
    echo ""
    echo "开始使用："
    echo "  export noninteractive=true"
    echo "  onevm.sh vm1 2 2 20 MyPass 25000 34975 35000 debian"
    echo ""
    echo "KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    echo "======================================================"
}

# ===== 主流程 =====
main() {
    echo "======================================================"
    echo -e "${GREEN}  KubeVirt 一键安装脚本${NC}"
    echo "  https://github.com/oneclickvirt/kubevirt"
    echo "======================================================"
    echo ""

    check_root
    check_arch
    check_os
    check_kvm
    check_resources
    install_dependencies
    verify_dependencies
    install_k3s
    setup_kubectl
    install_kubevirt
    install_cdi
    if ! install_virtctl; then
        _warn "virtctl 安装失败，环境主体已继续安装；请根据上方提示稍后手动安装"
    fi
    install_management_scripts
    create_vm_namespace
    configure_storage
    configure_cdi_proxy
    setup_ip_forward
    setup_firewall_service
    print_summary
}

main "$@"

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
#
# 示例（一键无交互安装）：
#   noninteractive=true bash kubevirtinstall.sh
#   noninteractive=true KUBEVIRT_VERSION=v1.3.0 CDI_VERSION=v1.60.0 bash kubevirtinstall.sh
#
# =====================================================================

# ===== 全局非交互模式 =====
export DEBIAN_FRONTEND=noninteractive

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
        chmod 666 /dev/kvm 2>/dev/null || true
        _info "KVM 硬件虚拟化可用（嵌套虚拟化或物理机）"
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
            apache2-utils 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q \
            curl wget git jq socat conntrack-tools \
            nftables iptables ebtables ipset iproute \
            ca-certificates gnupg qemu-img 2>/dev/null || true
    fi
    _info "依赖安装完成"
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

# ===== K3s 安装 =====
install_k3s() {
    _step "安装 K3s（轻量级 Kubernetes）..."

    if command -v k3s >/dev/null 2>&1 && k3s kubectl get nodes >/dev/null 2>&1; then
        _info "K3s 已安装且运行正常，跳过"
        return 0
    fi

    # 下载 K3s 安装脚本（优先国内镜像，失败回退官方）
    local install_script="/tmp/k3s-install.sh"
    _info "下载 K3s 安装脚本..."
    if ! curl -fsSL --connect-timeout 15 --max-time 60 \
            "https://rancher-mirror.rancher.cn/k3s/k3s-install.sh" -o "$install_script" 2>/dev/null; then
        _warn "国内镜像下载失败，使用官方源..."
        curl -fsSL --connect-timeout 30 --max-time 120 \
            "https://get.k3s.io" -o "$install_script"
    fi
    chmod +x "$install_script"

    # 禁用 traefik，减少资源占用；开放全部端口范围
    _info "执行 K3s 安装..."
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    sh "$install_script" \
        --disable traefik \
        --disable servicelb \
        --disable metrics-server \
        --kube-apiserver-arg="service-node-port-range=1-65535" \
        --write-kubeconfig-mode 644 \
        2>&1 | tee /tmp/k3s-install-log.txt

    # 等待 K3s 就绪
    _info "等待 K3s 启动（最多 120 秒）..."
    local timeout=120
    local elapsed=0
    until k3s kubectl get nodes >/dev/null 2>&1; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$elapsed" -ge "$timeout" ]; then
            _error "K3s 启动超时，请检查日志：journalctl -u k3s"
        fi
        echo -n "."
    done
    echo ""

    # 等待节点 Ready
    _info "等待节点就绪..."
    k3s kubectl wait --for=condition=Ready nodes --all --timeout=120s

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
        kv_phase=$(kubectl get kubevirt -n kubevirt kubevirt 2>/dev/null | grep -oP 'Deployed|Deploying' | head -1 || true)
        if [ "$kv_phase" = "Deployed" ]; then
            _info "KubeVirt 已安装，跳过"
            return 0
        fi
    fi

    local KV_BASE="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"

    # Operator
    _info "下载并部署 KubeVirt Operator..."
    download_with_retry "${KV_BASE}/kubevirt-operator.yaml" "/tmp/kubevirt-operator.yaml"
    kubectl apply -f /tmp/kubevirt-operator.yaml

    # 等待 operator 就绪
    _info "等待 KubeVirt Operator 就绪（最多 5 分钟）..."
    kubectl wait --for=condition=Available \
        deployment/virt-operator \
        -n kubevirt \
        --timeout=300s

    # CR
    _info "下载并部署 KubeVirt CR..."
    download_with_retry "${KV_BASE}/kubevirt-cr.yaml" "/tmp/kubevirt-cr.yaml"
    kubectl apply -f /tmp/kubevirt-cr.yaml

    # 如果不支持 KVM，启用软件模拟
    if [ "${USE_EMULATION:-0}" = "1" ]; then
        _warn "启用软件模拟（无 KVM）..."
        kubectl patch kubevirt kubevirt -n kubevirt --type merge \
            -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    fi

    # 等待所有 KubeVirt 组件就绪
    _info "等待 KubeVirt 部署完成（最多 10 分钟）..."
    kubectl wait kubevirt kubevirt \
        -n kubevirt \
        --for=condition=Available \
        --timeout=600s

    _info "KubeVirt 安装完成"
    kubectl get pods -n kubevirt
}

# ===== 安装 CDI =====
install_cdi() {
    _step "安装 CDI（Containerized Data Importer）${CDI_VERSION}..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    if kubectl get namespace cdi >/dev/null 2>&1; then
        _info "CDI 已安装，跳过"
        return 0
    fi

    local CDI_BASE="https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}"

    # Operator
    _info "下载并部署 CDI Operator..."
    download_with_retry "${CDI_BASE}/cdi-operator.yaml" "/tmp/cdi-operator.yaml"
    kubectl apply -f /tmp/cdi-operator.yaml

    # 等待 operator
    _info "等待 CDI Operator 就绪（最多 5 分钟）..."
    kubectl wait --for=condition=Available \
        deployment/cdi-operator \
        -n cdi \
        --timeout=300s

    # CR
    _info "下载并部署 CDI CR..."
    download_with_retry "${CDI_BASE}/cdi-cr.yaml" "/tmp/cdi-cr.yaml"
    kubectl apply -f /tmp/cdi-cr.yaml

    # 等待 CDI 就绪
    _info "等待 CDI 部署完成（最多 5 分钟）..."
    kubectl wait cdi cdi \
        -n cdi \
        --for=condition=Available \
        --timeout=300s

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

    if ! curl -fsSL --connect-timeout 30 --max-time 300 "$VIRTCTL_URL" -o /usr/local/bin/virtctl; then
        _warn "从 GitHub 下载 virtctl 失败"
        _warn "可以稍后手动安装：curl -L ${VIRTCTL_URL} -o /usr/local/bin/virtctl && chmod +x /usr/local/bin/virtctl"
        return 1
    fi

    chmod +x /usr/local/bin/virtctl
    _info "virtctl 安装完成：$(virtctl version --client 2>/dev/null | head -1)"
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
    if ! curl -fsSL --connect-timeout 15 --max-time 30 "$fw_url" -o /usr/local/lib/kubevirt/firewall.sh 2>/dev/null; then
        if [ ! -f /usr/local/lib/kubevirt/firewall.sh ]; then
            _error "下载防火墙库失败，请检查网络"
        fi
        _warn "下载防火墙库失败，使用已存在的版本"
    fi
    chmod +x /usr/local/lib/kubevirt/firewall.sh

    # 检测防火墙后端
    source /usr/local/lib/kubevirt/firewall.sh
    detect_fw_backend
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
    echo ""
    echo "开始使用："
    echo "  curl -sSL -o onevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh"
    echo "  chmod +x onevm.sh"
    echo "  ./onevm.sh vm1 2 2 20 MyPass 25000 34975 35000 debian"
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
    install_k3s
    setup_kubectl
    install_kubevirt
    install_cdi
    install_virtctl
    create_vm_namespace
    configure_storage
    configure_cdi_proxy
    setup_ip_forward
    setup_firewall_service
    print_summary
}

main "$@"

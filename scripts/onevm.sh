#!/bin/bash
# =====================================================================
# KubeVirt 单个虚拟机开设脚本
# 用法: ./onevm.sh <name> <cpu> <memory_gb> <disk_gb> <password> <sshport> <startport> <endport> [system]
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

# ===== 环境变量 =====
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="kubevirt-vms"
RULES_FILE="/etc/kubevirt/iptables-rules"

# ===== 参数解析 =====
parse_args() {
    VM_NAME="${1:-test}"
    CPU="${2:-1}"
    MEMORY_GB="${3:-1}"
    DISK_GB="${4:-10}"
    PASSWORD="${5:-123456}"
    SSH_PORT="${6:-25000}"
    START_PORT="${7:-34975}"
    END_PORT="${8:-35000}"
    SYSTEM="${9:-ubuntu}"

    # 转换为小写
    SYSTEM=$(echo "$SYSTEM" | tr '[:upper:]' '[:lower:]')

    # 验证 VM 名称（只允许小写字母、数字、连字符）
    if ! echo "$VM_NAME" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'; then
        _error "VM 名称只允许小写字母、数字和连字符，且不能以连字符开头或结尾：$VM_NAME"
    fi

    # 验证端口
    for port in "$SSH_PORT"; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            _error "端口无效：$port（必须在 1-65535 范围内）"
        fi
    done

    # 允许 startport/endport 为 0（表示不分配额外端口）
    if [ "$START_PORT" != "0" ] || [ "$END_PORT" != "0" ]; then
        for port in "$START_PORT" "$END_PORT"; do
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 0 ] || [ "$port" -gt 65535 ]; then
                _error "端口无效：$port（必须在 0-65535 范围内，0 表示不分配）"
            fi
        done
    fi

    if [ "$START_PORT" -gt "$END_PORT" ]; then
        _error "起始端口 ($START_PORT) 不能大于结束端口 ($END_PORT)"
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
        _error "未找到 kubectl/k3s，请先运行安装脚本：bash <(wget -qO- .../kubevirtinstall.sh)"
    fi

    # 使用 k3s kubectl 如果没有独立 kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        alias kubectl='k3s kubectl'
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

# 从 oneclickvirt/pve_kvm_images releases 中查找最佳匹配镜像
# 参数: $1=搜索关键词（grep -i 模式），结果写入 IMAGE_URL
_find_in_pve_kvm_images() {
    local pattern="$1"
    local api_url="https://api.github.com/repos/oneclickvirt/pve_kvm_images/releases/tags/images"
    local api_json

    _info "查询 pve_kvm_images releases..."
    api_json=$(curl -sL --max-time 15 "$api_url" 2>/dev/null)
    [ -z "$api_json" ] && return 1

    # 从 JSON 中提取所有 .qcow2 资产名（兼容无 jq 环境）
    local names
    names=$(echo "$api_json" | grep -oP '"name":\s*"\K[^"]+\.qcow2' 2>/dev/null || \
            echo "$api_json" | python3 -c \
              "import sys,json; d=json.load(sys.stdin); [print(a['name']) for a in d.get('assets',[]) if a['name'].endswith('.qcow2')]" 2>/dev/null)
    [ -z "$names" ] && return 1

    # 优先选含 cloud 的，再按版本号从高到低排序取第一
    local best
    best=$(echo "$names" | grep -i "$pattern" | grep -i "cloud" | sort -V | tail -1)
    [ -z "$best" ] && best=$(echo "$names" | grep -i "$pattern" | sort -V | tail -1)
    [ -z "$best" ] && return 1

    local base_url="https://github.com/oneclickvirt/pve_kvm_images/releases/download/images/${best}"
    IMAGE_URL="${CDN_PREFIX}${base_url}"
    _info "pve_kvm_images 中找到镜像：$best"
    return 0
}

# 从 idc.wiki 镜像站查找
_find_in_idc_wiki() {
    local pattern="$1"
    local index_url="https://down.idc.wiki/Image/realServer-Template/current/qcow2/"
    local names

    _info "查询 idc.wiki 镜像站..."
    names=$(curl -sL --max-time 10 "$index_url" 2>/dev/null | \
            grep -oP 'href="[^"]+\.qcow2"' | grep -oP '[^"/]+\.qcow2')
    [ -z "$names" ] && return 1

    local best
    best=$(echo "$names" | grep -i "$pattern" | grep -i "cloud" | sort -V | tail -1)
    [ -z "$best" ] && best=$(echo "$names" | grep -i "$pattern" | sort -V | tail -1)
    [ -z "$best" ] && return 1

    local base_url="${index_url}${best}"
    IMAGE_URL="${CDN_PREFIX}${base_url}"
    _info "idc.wiki 中找到镜像：$best"
    return 0
}

# 从 oneclickvirt/kvm_images releases 下载（已知版本映射）
# 参数: $1=系统名（如 debian12），$2=版本 tag（如 v2.0）
_find_in_kvm_images() {
    local sysname="$1"
    local ver="$2"
    local base_url="https://github.com/oneclickvirt/kvm_images/releases/download/${ver}/${sysname}.qcow2"
    local try_url="${CDN_PREFIX}${base_url}"

    if _url_accessible "$try_url" || _url_accessible "$base_url"; then
        IMAGE_URL="$try_url"
        _info "kvm_images ${ver} 中找到镜像：${sysname}.qcow2"
        return 0
    fi
    return 1
}

# ===== 获取云镜像 URL（优先 oneclickvirt 组织镜像，不存在再用官方源） =====
get_image_url() {
    # 确定 IMAGE_OS 和各层备选方案
    local pve_pattern kvm_name kvm_ver official_url
    IMAGE_URL=""

    case "$SYSTEM" in
        ubuntu|ubuntu2204|ubuntu22|ubuntu24)
            IMAGE_OS="ubuntu"
            pve_pattern="ubuntu"
            kvm_name="ubuntu22"; kvm_ver="v2.0"
            official_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
            ;;
        debian|debian12)
            IMAGE_OS="debian"
            pve_pattern="debian-12\|debian12"
            kvm_name="debian12"; kvm_ver="v2.0"
            official_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
            ;;
        debian11)
            IMAGE_OS="debian"
            pve_pattern="debian-11\|debian11"
            kvm_name="debian11"; kvm_ver="v2.0"
            official_url="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
            ;;
        almalinux|alma|almalinux9)
            IMAGE_OS="almalinux"
            pve_pattern="alma"
            kvm_name="almalinux8"; kvm_ver="v2.0"
            official_url="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
            ;;
        rockylinux|rocky|rockylinux9)
            IMAGE_OS="rockylinux"
            pve_pattern="rocky"
            kvm_name="rockylinux8"; kvm_ver="v2.0"
            official_url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
            ;;
        centos|centos7)
            IMAGE_OS="centos"
            pve_pattern="centos"
            kvm_name="centos7"; kvm_ver="v2.0"
            official_url="https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2"
            ;;
        centos8|centos8-stream|centos-stream8)
            IMAGE_OS="centos"
            pve_pattern="centos.*8\|centos8"
            kvm_name="centos8-stream"; kvm_ver="v2.0"
            official_url="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-latest.x86_64.qcow2"
            ;;
        centos9|centosstream9|centos-stream|centos-stream9)
            IMAGE_OS="centos"
            pve_pattern="centos.*9\|centos9"
            kvm_name="centos8-stream"; kvm_ver="v2.0"
            official_url="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"
            ;;
        opensuse|suse|opensuse15|opensuselap|opensuse-leap)
            IMAGE_OS="opensuse"
            pve_pattern="opensuse\|suse\|leap"
            kvm_name="opensuse-leap-15"; kvm_ver="v1.0"
            official_url="https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.x86_64-Cloud.qcow2"
            ;;
        *)
            _error "不支持的系统：$SYSTEM\n支持：ubuntu, debian, debian11, almalinux, rockylinux, centos, centos8-stream, centos9-stream, opensuse"
            ;;
    esac

    # 检测 CDN 可用性
    check_cdn || true

    _step "解析镜像地址（优先 oneclickvirt 组织镜像）..."

    # 第1优先：pve_kvm_images releases（最新版本）
    if _find_in_pve_kvm_images "$pve_pattern"; then
        _info "使用来源：oneclickvirt/pve_kvm_images [releases]"
        _info "镜像地址：$IMAGE_URL"
        return 0
    fi

    # 第2优先：idc.wiki 镜像站
    if _find_in_idc_wiki "$pve_pattern"; then
        _info "使用来源：idc.wiki [mirror]"
        _info "镜像地址：$IMAGE_URL"
        return 0
    fi

    # 第3优先：kvm_images releases（已知系统版本映射）
    if [ -n "$kvm_name" ] && _find_in_kvm_images "$kvm_name" "$kvm_ver"; then
        _info "使用来源：oneclickvirt/kvm_images [${kvm_ver}]"
        _info "镜像地址：$IMAGE_URL"
        return 0
    fi

    # centos8-stream 特殊备用地址
    if [ "$IMAGE_OS" = "centos" ] && _url_accessible "https://api.ilolicon.com/centos8-stream.qcow2"; then
        IMAGE_URL="https://api.ilolicon.com/centos8-stream.qcow2"
        _info "使用来源：ilolicon [centos8-stream]"
        _info "镜像地址：$IMAGE_URL"
        return 0
    fi

    # 最终回退：官方上游地址
    _warn "oneclickvirt 镜像源均不可用，回退到官方上游地址"
    IMAGE_URL="$official_url"
    _info "使用来源：官方上游"
    _info "镜像地址：$IMAGE_URL"
}

# ===== 创建 cloud-init 密钥 =====
create_cloudinit_secret() {
    _step "创建 cloud-init 配置..."

    local SECRET_NAME="${VM_NAME}-cloudinit"

    # 删除已存在的 secret
    kubectl delete secret "$SECRET_NAME" -n "$NS" 2>/dev/null || true

    # 为不同系统生成适合的 cloud-init 配置
    local cloud_init_content
    cloud_init_content=$(cat <<CLOUDINIT
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.local

# 创建 root 用户并设置密码
users:
  - name: root
    lock_passwd: false
    hashed_passwd: $(echo "$PASSWORD" | openssl passwd -6 -stdin 2>/dev/null || python3 -c "import crypt; print(crypt.crypt('${PASSWORD}', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "$PASSWORD")

# SSH 配置
ssh_pwauth: true
disable_root: false

# 修改 sshd 配置允许 root 登录和密码认证
runcmd:
  - sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
  - echo "PermitRootLogin yes" >> /etc/ssh/sshd_config.d/99-kubevirt.conf || true
  - echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/99-kubevirt.conf || true
  - mkdir -p /etc/ssh/sshd_config.d
  - printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-kubevirt.conf
  - systemctl restart sshd || service ssh restart || true
  - echo "root:${PASSWORD}" | chpasswd

# 设置时区
timezone: Asia/Shanghai

# 安装基础工具
packages:
  - curl
  - wget
  - vim
  - net-tools
  - iputils-ping
package_update: false
package_upgrade: false
CLOUDINIT
)

    # 注意：openssl passwd 对特殊字符可能有问题，直接使用明文密码通过 chpasswd
    # 使用更可靠的密码设置方法
    local user_data
    user_data=$(cat <<CLOUDINIT
#cloud-config
hostname: ${VM_NAME}
users:
  - name: root
    lock_passwd: false
ssh_pwauth: true
disable_root: false
runcmd:
  - echo "root:${PASSWORD}" | chpasswd
  - mkdir -p /etc/ssh/sshd_config.d
  - printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-kubevirt.conf
  - systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || true
timezone: Asia/Shanghai
CLOUDINIT
)

    # 创建 Secret
    kubectl create secret generic "$SECRET_NAME" \
        -n "$NS" \
        --from-literal=userdata="$user_data"

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

    cat <<EOF | kubectl apply -f -
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

    cat <<EOF | kubectl apply -f -
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
    kubevirt.io/password: "${PASSWORD}"
spec:
  running: false
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
        resources:
          requests:
            memory: ${MEMORY}
            cpu: "${CPU_CORES}"
          limits:
            memory: ${MEMORY}
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

    _info "VirtualMachine ${VM_NAME} 已创建"
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
            _error "镜像导入超时（${timeout}秒），请检查网络连接和磁盘空间"
        fi
    done
}

# ===== 启动虚拟机 =====
start_vm() {
    _step "启动虚拟机..."

    if command -v virtctl >/dev/null 2>&1; then
        virtctl start "$VM_NAME" -n "$NS"
    else
        kubectl patch vm "$VM_NAME" -n "$NS" \
            --type merge \
            -p '{"spec":{"running":true}}'
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
            _error "虚拟机实例状态异常：$phase"
        fi

        echo -n "."
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo ""
            _error "虚拟机启动超时（${timeout}秒）\n尝试：kubectl describe vmi $VM_NAME -n $NS"
        fi
    done
    echo ""
}

# ===== 获取虚拟机 IP =====
get_vm_ip() {
    _step "获取虚拟机内部 IP..."
    local max_retry=60
    local retry=0

    while [ "$retry" -lt "$max_retry" ]; do
        # 方法1：从 VMI 状态获取
        VM_IP=$(kubectl get vmi "$VM_NAME" -n "$NS" \
            -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")

        if [ -n "$VM_IP" ] && [ "$VM_IP" != "null" ]; then
            _info "虚拟机 IP：$VM_IP"
            return 0
        fi

        # 方法2：从 virt-launcher Pod 获取
        local pod_name
        pod_name=$(kubectl get pod -n "$NS" \
            -l "kubevirt.io/vm=$VM_NAME" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$pod_name" ] && [ "$pod_name" != "null" ]; then
            VM_IP=$(kubectl get pod "$pod_name" -n "$NS" \
                -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
            if [ -n "$VM_IP" ] && [ "$VM_IP" != "null" ]; then
                _info "虚拟机 Pod IP：$VM_IP（通过 virt-launcher 获取）"
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
    return 1
}

# ===== 配置 iptables 端口转发 =====
setup_port_forward() {
    _step "配置端口转发..."

    if [ -z "$VM_IP" ]; then
        _warn "VM IP 未知，跳过端口转发配置"
        return 1
    fi

    # 确保规则文件目录存在
    mkdir -p /etc/kubevirt
    touch "$RULES_FILE"

    local HOST_IP
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

    # 清理该 VM 的旧规则
    cleanup_vm_iptables "$VM_NAME"

    _info "SSH 端口转发：宿主机:${SSH_PORT} → VM:22"
    # SSH 端口 DNAT（TCP）
    iptables -t nat -A PREROUTING \
        -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ssh" \
        -p tcp --dport "$SSH_PORT" \
        -j DNAT --to-destination "${VM_IP}:22"

    # 本机访问支持（OUTPUT 链）
    iptables -t nat -A OUTPUT \
        -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ssh-local" \
        -p tcp --dport "$SSH_PORT" \
        -j DNAT --to-destination "${VM_IP}:22"

    # MASQUERADE（允许 VM 回包）
    iptables -t nat -A POSTROUTING \
        -m comment --comment "KUBEVIRT-VM-${VM_NAME}-masq" \
        -s "${VM_IP}" \
        -j MASQUERADE

    # 保存 SSH 规则
    cat >> "$RULES_FILE" <<EOF
# VM: ${VM_NAME} SSH
-t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ssh" -p tcp --dport ${SSH_PORT} -j DNAT --to-destination ${VM_IP}:22
-t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ssh-local" -p tcp --dport ${SSH_PORT} -j DNAT --to-destination ${VM_IP}:22
-t nat -A POSTROUTING -m comment --comment "KUBEVIRT-VM-${VM_NAME}-masq" -s ${VM_IP} -j MASQUERADE
EOF

    # 额外端口范围转发
    if [ "$START_PORT" != "0" ] && [ "$END_PORT" != "0" ] && [ "$START_PORT" -le "$END_PORT" ]; then
        _info "端口范围转发：宿主机:${START_PORT}-${END_PORT} → VM:${START_PORT}-${END_PORT}"

        # TCP DNAT
        iptables -t nat -A PREROUTING \
            -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ports-tcp" \
            -p tcp --dport "${START_PORT}:${END_PORT}" \
            -j DNAT --to-destination "${VM_IP}"

        # UDP DNAT
        iptables -t nat -A PREROUTING \
            -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ports-udp" \
            -p udp --dport "${START_PORT}:${END_PORT}" \
            -j DNAT --to-destination "${VM_IP}"

        # 本机 TCP
        iptables -t nat -A OUTPUT \
            -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ports-tcp-local" \
            -p tcp --dport "${START_PORT}:${END_PORT}" \
            -j DNAT --to-destination "${VM_IP}"

        # 保存端口范围规则
        cat >> "$RULES_FILE" <<EOF
# VM: ${VM_NAME} Ports ${START_PORT}-${END_PORT}
-t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ports-tcp" -p tcp --dport ${START_PORT}:${END_PORT} -j DNAT --to-destination ${VM_IP}
-t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ports-udp" -p udp --dport ${START_PORT}:${END_PORT} -j DNAT --to-destination ${VM_IP}
-t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${VM_NAME}-ports-tcp-local" -p tcp --dport ${START_PORT}:${END_PORT} -j DNAT --to-destination ${VM_IP}
EOF
    fi

    # 启用 FORWARD
    iptables -P FORWARD ACCEPT 2>/dev/null || true

    _info "端口转发规则已配置并持久化"
}

# ===== 清理指定 VM 的 iptables 规则 =====
cleanup_vm_iptables() {
    local vm="$1"

    # 从当前 iptables 规则中删除该 VM 的规则
    for table in nat; do
        for chain in PREROUTING OUTPUT POSTROUTING; do
            while true; do
                local rule_num
                rule_num=$(iptables -t "$table" -L "$chain" --line-numbers -n 2>/dev/null | \
                    grep "KUBEVIRT-VM-${vm}" | head -1 | awk '{print $1}' || true)
                if [ -z "$rule_num" ]; then
                    break
                fi
                iptables -t "$table" -D "$chain" "$rule_num" 2>/dev/null || break
            done
        done
    done

    # 从规则文件中删除该 VM 的规则
    if [ -f "$RULES_FILE" ]; then
        sed -i "/KUBEVIRT-VM-${vm}/d" "$RULES_FILE" 2>/dev/null || true
        sed -i "/# VM: ${vm} /d" "$RULES_FILE" 2>/dev/null || true
    fi
}

# ===== 保存连接信息到日志 =====
save_vmlog() {
    local log_file="vmlog"

    local HOST_IP
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

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
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

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
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' \
        || hostname -I | awk '{print $1}' \
        || curl -s ifconfig.me 2>/dev/null || echo "<宿主机IP>")

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
    start_vm
    wait_for_vmi
    get_vm_ip
    setup_port_forward
    save_vmlog
    wait_for_ssh
    print_connection_info
}

main "$@"

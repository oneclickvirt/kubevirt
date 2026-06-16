# kubevirt

[![Hits](https://hits.spiritlhl.net/kubevirt.svg)](https://hits.spiritlhl.net/kubevirt)

基于 KubeVirt + K3s 的虚拟机环境一键安装与管理脚本

支持一键安装 KubeVirt 运行时，并开设各种 Linux 虚拟机（提供 SSH 访问），支持 CPU、内存、磁盘资源限制，端口映射，cloud-init 初始化等。

## 说明

- 使用 K3s 作为轻量级 Kubernetes，自动安装单节点集群
- 使用 KubeVirt 提供虚拟机能力（基于 KVM/QEMU）
- 使用 CDI（Containerized Data Importer）导入云镜像
- 通过 nftables/iptables DNAT 实现端口映射
- 支持系统：Ubuntu 22.04/24.04, Debian 11/12, AlmaLinux 9, RockyLinux 9, CentOS 7, CentOS Stream 8/9, openSUSE Leap 15.5
- 支持架构：amd64 (x86_64)
- 宿主机系统支持：Ubuntu 20.04/22.04/24.04，Debian 11/12

## 环境要求

- 宿主机需支持 KVM 虚拟化（`/dev/kvm` 存在且可用）
- 最低配置：2 核 CPU，4GB RAM，20GB 可用磁盘
- root 权限运行
- 需要公网访问以下载 K3s、KubeVirt 组件和虚拟机镜像

## 安装 KubeVirt 环境

```bash
export noninteractive=true
bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/kubevirtinstall.sh)
```

安装完成后会把常用管理脚本安装到 `/usr/local/bin`，可直接运行 `onevm.sh`、`create_vm.sh`、`listvms.sh`、`snapshotvm.sh`、`resizevm.sh`、`deletevm.sh` 和 `update-port-rules.sh`。

弱网或离线环境可提前准备安装文件后运行：

```bash
export noninteractive=true
export K3S_INSTALL_SCRIPT=/path/to/k3s-install.sh
export KUBEVIRT_MANIFEST_DIR=/path/to/kubevirt-manifests
export CDI_MANIFEST_DIR=/path/to/cdi-manifests
export VIRTCTL_BINARY=/path/to/virtctl
export KUBEVIRT_SCRIPT_DIR=/path/to/kubevirt
bash kubevirtinstall.sh
```

## 开设单个虚拟机

```bash
curl -sSL -o onevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh
chmod +x onevm.sh
export noninteractive=true
./onevm.sh <name> <cpu> <memory_gb> <disk_gb> <password> <sshport> <startport> <endport> [system]
```

**参数说明：**

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `name` | 虚拟机名称（小写字母数字和连字符） | `test` |
| `cpu` | CPU 核心数 | `1` |
| `memory_gb` | 内存（GB） | `1` |
| `disk_gb` | 磁盘大小（GB） | `10` |
| `password` | root 密码 | `123456` |
| `sshport` | 宿主机 SSH 映射端口 | `25000` |
| `startport` | 公网端口范围起始 | `34975` |
| `endport` | 公网端口范围结束 | `35000` |
| `system` | 操作系统 | `ubuntu` |

**支持的系统：**

| 系统标识 | 说明 | 镜像来源 |
|----------|------|----------|
| `ubuntu` | Ubuntu 22.04 LTS | pve_kvm_images(ubuntu22) → kvm_images(ubuntu22) → 官方 |
| `ubuntu24` | Ubuntu 24.04 LTS | pve_kvm_images(ubuntu24) → kvm_images(ubuntu24) → 官方 |
| `debian` | Debian 12 | pve_kvm_images(debian12) → kvm_images(debian12) → 官方 |
| `debian11` | Debian 11 | pve_kvm_images(debian11) → kvm_images(debian11) → 官方 |
| `almalinux` | AlmaLinux 9 | pve_kvm_images(almalinux9) → kvm_images(almalinux9) → 官方 |
| `rockylinux` | RockyLinux 9 | pve_kvm_images(rockylinux9) → kvm_images(rockylinux9) → 官方 |
| `centos` | CentOS 7 | pve_kvm_images(centos7) → kvm_images(centos7) → 官方 |
| `centos8-stream` | CentOS Stream 8 | pve_kvm_images(centos8-stream) → kvm_images(centos8-stream) → 官方 |
| `centos-stream` | CentOS Stream 9 | 官方上游（无组织预置镜像） |
| `opensuse` | openSUSE Leap 15.5 | pve_kvm_images(opensuse-leap-15) → kvm_images(opensuse-leap-15) → 官方 |

**示例：**

```bash
export noninteractive=true
./onevm.sh vm1 2 2 20 MyPassword 25000 34975 35000 debian
```

## 批量开设虚拟机

```bash
curl -sSL -o create_vm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/create_vm.sh
chmod +x create_vm.sh
export noninteractive=true
./create_vm.sh
```

## 查看所有虚拟机

```bash
curl -sSL -o listvms.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/listvms.sh
chmod +x listvms.sh
export noninteractive=true
./listvms.sh
```

## 创建虚拟机快照（DataVolume 克隆）

```bash
curl -sSL -o snapshotvm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/snapshotvm.sh
chmod +x snapshotvm.sh
export noninteractive=true
./snapshotvm.sh vm1 vm1-snapshot-001
```

说明：

- 快照通过 CDI 从 `vm1-dv` 克隆出新的 DataVolume，不会直接创建新 VM。
- 默认拒绝对运行中的 VM 创建快照，避免数据不一致；如确认可接受风险，可设置 `ALLOW_RUNNING_SNAPSHOT=true`。
- 默认等待克隆完成，可用 `WAIT_SNAPSHOT=false` 改为提交任务后立即返回。

## 调整虚拟机资源

```bash
curl -sSL -o resizevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/resizevm.sh
chmod +x resizevm.sh
export noninteractive=true
./resizevm.sh vm1 4 8 40
```

说明：

- 参数依次为 `vmname cpu memory_gb disk_gb`，留空表示不调整对应资源，例如：`./resizevm.sh vm1 "" "" 40`。
- CPU/内存会更新 VM 模板；运行中的 VM 通常需要重启后完全生效，可设置 `RESTART_VM=true` 自动重启。
- 磁盘只支持扩容，且依赖 StorageClass 支持 PVC 扩容；虚拟机内文件系统可能仍需手动扩容。

## 删除单个虚拟机

```bash
curl -sSL -o deletevm.sh https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/deletevm.sh
chmod +x deletevm.sh
export noninteractive=true
./deletevm.sh <name>
```

默认会保留该 VM 的快照 DataVolume，避免误删备份；如需一并删除，设置 `DELETE_SNAPSHOTS=true`。

## 卸载（完整清理）

```bash
export noninteractive=true
bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/kubevirtuninstall.sh)
```

## 日志文件

批量开设时，连接信息会记录在当前目录的 `vmlog` 文件中，格式如下：

```
vm1 root@<宿主机IP>:25000 密码: MyPassword 端口范围: 34975-35000
vm2 root@<宿主机IP>:25001 密码: MyPassword 端口范围: 35001-35026
```

## 常用环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `noninteractive=true` | 统一无交互模式标记 | 未启用 |
| `K3S_VERSION` | 安装的 K3s 版本 | `v1.29.3+k3s1` |
| `KUBEVIRT_VERSION` | 安装的 KubeVirt 版本 | `v1.2.1` |
| `CDI_VERSION` | 安装的 CDI 版本 | `v1.59.0` |
| `VIRTCTL_VERSION` | 安装的 virtctl 版本 | `v1.2.1` |
| `K3S_INSTALL_SCRIPT` | 本地 K3s 安装脚本路径，供离线/弱网安装使用 | 未设置 |
| `KUBEVIRT_MANIFEST_DIR` | 本地 KubeVirt manifest 目录，需包含 `kubevirt-operator.yaml` 和 `kubevirt-cr.yaml` | 未设置 |
| `CDI_MANIFEST_DIR` | 本地 CDI manifest 目录，需包含 `cdi-operator.yaml` 和 `cdi-cr.yaml` | 未设置 |
| `KUBEVIRT_OPERATOR_YAML` / `KUBEVIRT_CR_YAML` | 分别指定本地 KubeVirt Operator/CR manifest 文件 | 未设置 |
| `CDI_OPERATOR_YAML` / `CDI_CR_YAML` | 分别指定本地 CDI Operator/CR manifest 文件 | 未设置 |
| `VIRTCTL_BINARY` | 本地 virtctl 二进制路径 | 未设置 |
| `KUBEVIRT_SCRIPT_DIR` | 本地脚本目录，供离线安装 `firewall.sh`、`onevm.sh`、`snapshotvm.sh` 等脚本 | 未设置 |
| `KEEP_FAILED_RESOURCES=true` | VM 创建失败时保留 VM/DV/Secret 现场排查 | 未启用 |
| `STORE_PASSWORD_ANNOTATION=true` | 将 VM 明文密码写入 Kubernetes 注解，便于后续查询但会扩大暴露面 | 未启用 |
| `DELETE_SNAPSHOTS=true` | 删除 VM 时同时删除由 `snapshotvm.sh` 创建的 DataVolume 克隆 | 未启用 |
| `ALLOW_RUNNING_SNAPSHOT=true` | 允许对运行中 VM 做 DataVolume 克隆 | 未启用 |
| `WAIT_SNAPSHOT=false` | 创建快照后不等待克隆完成 | `true` |
| `RESTART_VM=true` | 资源调整后自动重启 VM | 未启用 |
| `SHOW_PASSWORD=true` | `listvms.sh` 显示已存储在 VM 注解或本地 `vmlog` 中的明文密码 | 未启用 |

## 工作原理

```
宿主机（K3s + KubeVirt）
├── K3s Kubernetes（单节点）
│   ├── KubeVirt Operator（管理虚拟机生命周期）
│   └── CDI（导入云镜像到 PVC）
├── 虚拟机 Pod（virt-launcher）
│   ├── vm1（QEMU/KVM）
│   │   ├── SSH :22  ←→  iptables DNAT → 宿主机:25000
│   │   └── 额外端口 ←→  iptables DNAT → 宿主机:34975-35000
│   └── vm2（QEMU/KVM）
│       ├── SSH :22  ←→  iptables DNAT → 宿主机:25001
│       └── 额外端口 ←→  iptables DNAT → 宿主机:35001-35026
```

## 常用管理命令

```bash
# 查看所有虚拟机状态
kubectl get vm -n kubevirt-vms

# 查看虚拟机实例（运行中的）
kubectl get vmi -n kubevirt-vms

# 查看数据卷导入进度
kubectl get dv -n kubevirt-vms

# 进入虚拟机串口控制台（Ctrl+] 退出）
virtctl console <vmname> -n kubevirt-vms

# 启动/停止/重启虚拟机
virtctl start <vmname> -n kubevirt-vms
virtctl stop <vmname> -n kubevirt-vms
virtctl restart <vmname> -n kubevirt-vms
```

## 注意事项

1. 虚拟机首次启动需要等待镜像下载导入（根据网速可能需要 5-20 分钟）
2. 宿主机需要开启 KVM 嵌套虚拟化或直接使用裸金属服务器
3. 端口转发通过 iptables/nftables 实现（支持IPv4 + IPv6双栈）：
   - 使用 systemd 服务在重启后自动恢复规则
   - Debian/Ubuntu 系统自动安装 `iptables-persistent` 和 `netfilter-persistent`
   - Red Hat/CentOS 系统自动安装 `iptables-services`
   - 规则变更后自动持久化，确保重启后不失效
4. 当前脚本仅支持 amd64/x86_64；ARM64 未提供镜像和 KubeVirt 兼容性保证
5. CentOS 7 已 EOL，仅作为兼容镜像选项保留，生产环境建议使用 Debian/Ubuntu/Rocky/AlmaLinux
6. 如需重置密码，通过 `virtctl console` 进入控制台手动修改

## FAQ

**K3s 安装失败怎么办？**

安装脚本会输出 `/tmp/k3s-install-log.txt` 最近日志、`systemctl status k3s` 和 `journalctl -u k3s` 片段。优先检查网络/DNS、root 权限、systemd、内核和防火墙限制。

**镜像导入失败或超时后会留下资源吗？**

默认会清理本次创建的 VM、DataVolume、PVC 和 cloud-init Secret。需要保留现场时设置 `KEEP_FAILED_RESOURCES=true`。

**为什么 `listvms.sh <vmname>` 不再显示密码？**

新 VM 默认不把明文密码写入 Kubernetes 注解，避免普通元数据查询泄露密码。密码仍会用于 cloud-init 初始化，并记录在创建时输出和本地 `vmlog` 中；`listvms.sh` 默认会对 `vmlog` 密码脱敏。如确需后续从 VM 注解或 `vmlog` 查询，创建时设置 `STORE_PASSWORD_ANNOTATION=true`，查询时再设置 `SHOW_PASSWORD=true`。

**快照是否等同于应用一致性备份？**

不是。`snapshotvm.sh` 使用 CDI DataVolume 克隆。运行中 VM 的磁盘可能存在未刷盘数据，建议先停止 VM 再创建快照。

# kubevirt

[![Hits](https://hits.spiritlhl.net/kubevirt.svg)](https://hits.spiritlhl.net/kubevirt)

基于 KubeVirt + K3s 的虚拟机环境一键安装与管理脚本

支持一键安装 KubeVirt 运行时，并开设各种 Linux 虚拟机（提供 SSH 访问），支持 CPU、内存、磁盘资源限制，端口映射，cloud-init 初始化等。

## 说明

- 使用 K3s 作为轻量级 Kubernetes，自动安装单节点集群
- 使用 KubeVirt 提供虚拟机能力（基于 KVM/QEMU）
- 使用 CDI（Containerized Data Importer）导入云镜像
- 通过 NodePort Service + iptables DNAT 实现端口映射
- 支持系统：Ubuntu 22.04, Debian 12, AlmaLinux 9, RockyLinux 9, CentOS Stream 9, openSUSE Leap 15.5
- 支持架构：amd64 (x86_64)
- 宿主机系统支持：Ubuntu 20.04/22.04/24.04，Debian 11/12

## 环境要求

- 宿主机需支持 KVM 虚拟化（`/dev/kvm` 存在且可用）
- 最低配置：2 核 CPU，4GB RAM，20GB 可用磁盘
- root 权限运行
- 需要公网访问以下载 K3s、KubeVirt 组件和虚拟机镜像

## 安装 KubeVirt 环境

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/kubevirtinstall.sh)
```

## 开设单个虚拟机

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/onevm.sh
chmod +x onevm.sh
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
| `ubuntu` | Ubuntu 22.04 LTS | pve_kvm_images → kvm_images(ubuntu22) → 官方 |
| `debian` | Debian 12 | pve_kvm_images → kvm_images(debian12) → 官方 |
| `debian11` | Debian 11 | pve_kvm_images → kvm_images(debian11) → 官方 |
| `almalinux` | AlmaLinux 9 | pve_kvm_images → kvm_images(almalinux8) → 官方 |
| `rockylinux` | RockyLinux 9 | pve_kvm_images → kvm_images(rockylinux8) → 官方 |
| `centos` | CentOS 7 | pve_kvm_images → kvm_images(centos7) → 官方 |
| `centos8-stream` | CentOS Stream 8 | pve_kvm_images → kvm_images → 官方 |
| `centos-stream` | CentOS Stream 9 | pve_kvm_images → 官方 |
| `opensuse` | openSUSE Leap 15.5 | pve_kvm_images → kvm_images(opensuse-leap-15) → 官方 |

> 镜像来源优先级：
> 1. `oneclickvirt/pve_kvm_images` releases（最新编译版）
> 2. `idc.wiki` 镜像站
> 3. `oneclickvirt/kvm_images` releases（稳定版）
> 4. 官方上游地址（最终兜底）
>
> 下载均支持 CDN 加速（`cdn0.spiritlhl.top` 等），网络不佳时自动检测并启用。

**示例：**

```bash
./onevm.sh vm1 2 2 20 MyPassword 25000 34975 35000 debian
```

## 批量开设虚拟机

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/create_vm.sh
chmod +x create_vm.sh
./create_vm.sh
```

## 查看所有虚拟机

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/listvms.sh
chmod +x listvms.sh
./listvms.sh
```

## 删除单个虚拟机

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/deletevm.sh
chmod +x deletevm.sh
./deletevm.sh <name>
```

## 卸载（完整清理）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/kubevirtuninstall.sh)
```

## 日志文件

批量开设时，连接信息会记录在当前目录的 `vmlog` 文件中，格式如下：

```
vm1 root@<宿主机IP>:25000 密码: MyPassword 端口范围: 34975-35000
vm2 root@<宿主机IP>:25001 密码: MyPassword 端口范围: 35001-35026
```

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
3. 端口转发通过 iptables 实现，重启后自动通过 systemd 服务恢复
4. 如需重置密码，通过 `virtctl console` 进入控制台手动修改
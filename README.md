# kubevirt

[![Hits](https://hits.spiritlhl.net/kubevirt.svg)](https://hits.spiritlhl.net/kubevirt)

基于 KubeVirt + K3s 的虚拟机环境一键安装与管理脚本

支持一键安装 KubeVirt 运行时，并开设各种 Linux 虚拟机（提供 SSH 访问），支持 CPU、内存、磁盘资源限制，端口映射，cloud-init 初始化等。

## 更新

[更新日志](CHANGELOG.md)

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/guide/kubevirt/kubevirt_precheck.html](https://virt.spiritlhl.net/guide/kubevirt/kubevirt_precheck.html)

国际(English Docs)：

[https://www.spiritlhl.net/en/guide/kubevirt/kubevirt_precheck.html](https://www.spiritlhl.net/en/guide/kubevirt/kubevirt_precheck.html)

说明文档中 KubeVirt 分区内容

## 说明

- 使用 K3s 作为轻量级 Kubernetes，自动安装单节点集群
- 使用 KubeVirt 提供虚拟机能力（基于 KVM/QEMU）
- 使用 CDI（Containerized Data Importer）导入云镜像
- 新建虚拟机通过 Kubernetes NodePort Service 实现 SSH 及额外 TCP/UDP 端口映射
- 支持系统：Ubuntu 22.04/24.04, Debian 11/12, AlmaLinux 9, RockyLinux 9, CentOS 7, CentOS Stream 8/9, openSUSE Leap 15.5
- 支持架构：amd64 (x86_64)
- 宿主机系统支持：Ubuntu 20.04/22.04/24.04，Debian 11/12

## 环境要求

- 推荐宿主机支持 KVM 虚拟化（`/dev/kvm` 存在且可用）；缺少设备时使用较慢的 QEMU TCG 模拟
- 最低配置：2 核 CPU，4GB RAM，20GB 可用磁盘
- root 权限运行
- 需要联网下载 K3s、KubeVirt 组件和虚拟机镜像，或提前准备对应的本地文件和镜像

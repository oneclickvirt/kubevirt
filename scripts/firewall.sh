#!/bin/bash
# =====================================================================
# KubeVirt 防火墙管理库
# nftables 优先，iptables 回退
# 统一管理 VM 端口转发规则（IPv4/IPv6）
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

KUBEVIRT_CONF_DIR="/etc/kubevirt"
KUBEVIRT_PORT_RULES="${KUBEVIRT_CONF_DIR}/port-rules.conf"
KUBEVIRT_FW_LOCK="/var/lock/kubevirt-fw.lock"
FW_BACKEND=""

# ===== 检测防火墙后端 =====
detect_fw_backend() {
    if [ -n "$FW_BACKEND" ]; then
        return 0
    fi
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        FW_BACKEND="nftables"
    elif command -v iptables >/dev/null 2>&1; then
        FW_BACKEND="iptables"
    else
        echo "[ERROR] 未找到 nftables 或 iptables" >&2
        return 1
    fi
}

# ===== 确保目录和状态文件存在 =====
fw_ensure_dirs() {
    mkdir -p "$KUBEVIRT_CONF_DIR"
    [ -f "$KUBEVIRT_PORT_RULES" ] || touch "$KUBEVIRT_PORT_RULES"
}

# ===== nftables: 从状态文件重建全部规则 =====
_nft_rebuild() {
    nft delete table inet kubevirt 2>/dev/null || true

    local has_rules=0
    while IFS=' ' read -r vm_name _rest; do
        [[ "$vm_name" =~ ^# || -z "$vm_name" ]] && continue
        has_rules=1
        break
    done < "$KUBEVIRT_PORT_RULES"

    [ "$has_rules" -eq 0 ] && return 0

    nft add table inet kubevirt
    nft add chain inet kubevirt prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
    nft add chain inet kubevirt output '{ type nat hook output priority -100; policy accept; }'
    nft add chain inet kubevirt postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'

    while IFS=' ' read -r vm_name vm_ip ssh_port start_port end_port; do
        [[ "$vm_name" =~ ^# || -z "$vm_name" ]] && continue

        # SSH DNAT
        nft add rule inet kubevirt prerouting tcp dport "$ssh_port" dnat ip to "${vm_ip}:22" comment \"KUBEVIRT-VM-${vm_name}-ssh\"
        nft add rule inet kubevirt output tcp dport "$ssh_port" dnat ip to "${vm_ip}:22" comment \"KUBEVIRT-VM-${vm_name}-ssh-local\"
        nft add rule inet kubevirt postrouting ip saddr "$vm_ip" masquerade comment \"KUBEVIRT-VM-${vm_name}-masq\"

        # 额外端口范围
        if [ "$start_port" != "0" ] && [ "$end_port" != "0" ] && [ "$start_port" -le "$end_port" ]; then
            nft add rule inet kubevirt prerouting tcp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-tcp\"
            nft add rule inet kubevirt prerouting udp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-udp\"
            nft add rule inet kubevirt output tcp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-tcp-local\"
        fi
    done < "$KUBEVIRT_PORT_RULES"
}

# ===== iptables: 清除所有 KUBEVIRT 规则 =====
_ipt_flush() {
    local chain
    for chain in PREROUTING OUTPUT POSTROUTING; do
        local i=0
        while [ "$i" -lt 500 ]; do
            local rule_num
            rule_num=$(iptables -t nat -L "$chain" --line-numbers -n 2>/dev/null | \
                grep "KUBEVIRT-VM-" | head -1 | awk '{print $1}')
            [ -z "$rule_num" ] && break
            iptables -t nat -D "$chain" "$rule_num" 2>/dev/null || break
            i=$((i + 1))
        done
    done
}

# ===== iptables: 从状态文件重建全部规则 =====
_ipt_rebuild() {
    _ipt_flush

    while IFS=' ' read -r vm_name vm_ip ssh_port start_port end_port; do
        [[ "$vm_name" =~ ^# || -z "$vm_name" ]] && continue

        iptables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ssh" -p tcp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22"
        iptables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ssh-local" -p tcp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22"
        iptables -t nat -A POSTROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-masq" -s "${vm_ip}" -j MASQUERADE

        if [ "$start_port" != "0" ] && [ "$end_port" != "0" ] && [ "$start_port" -le "$end_port" ]; then
            iptables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-tcp" -p tcp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
            iptables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-udp" -p udp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
            iptables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-tcp-local" -p tcp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
        fi
    done < "$KUBEVIRT_PORT_RULES"

    iptables -P FORWARD ACCEPT 2>/dev/null || true
}

# ===== 添加 VM 端口转发规则 =====
# 用法: fw_add_vm <vm_name> <vm_ip> <ssh_port> <start_port> <end_port>
fw_add_vm() {
    local vm_name="$1" vm_ip="$2" ssh_port="$3" start_port="${4:-0}" end_port="${5:-0}"

    detect_fw_backend || return 1
    fw_ensure_dirs

    (
        flock -x 200 || return 1
        # 删除旧条目
        sed -i "/^${vm_name} /d" "$KUBEVIRT_PORT_RULES" 2>/dev/null || true
        # 添加新条目
        echo "${vm_name} ${vm_ip} ${ssh_port} ${start_port} ${end_port}" >> "$KUBEVIRT_PORT_RULES"
        # 重建规则
        _fw_rebuild_locked
    ) 200>"$KUBEVIRT_FW_LOCK"
}

# ===== 删除 VM 端口转发规则 =====
# 用法: fw_remove_vm <vm_name>
fw_remove_vm() {
    local vm_name="$1"

    detect_fw_backend || return 1
    fw_ensure_dirs

    (
        flock -x 200 || return 1
        sed -i "/^${vm_name} /d" "$KUBEVIRT_PORT_RULES" 2>/dev/null || true
        _fw_rebuild_locked
    ) 200>"$KUBEVIRT_FW_LOCK"
}

# ===== 内部: 带锁的重建 =====
_fw_rebuild_locked() {
    case "$FW_BACKEND" in
        nftables) _nft_rebuild ;;
        iptables) _ipt_rebuild ;;
    esac
}

# ===== 重建所有规则（公共接口） =====
fw_rebuild() {
    detect_fw_backend || return 1
    fw_ensure_dirs

    (
        flock -x 200 || return 1
        _fw_rebuild_locked
    ) 200>"$KUBEVIRT_FW_LOCK"
}

# ===== 清除所有 KubeVirt 规则（保留状态文件） =====
fw_clear_rules() {
    detect_fw_backend || return 0

    case "$FW_BACKEND" in
        nftables) nft delete table inet kubevirt 2>/dev/null || true ;;
        iptables) _ipt_flush ;;
    esac
}

# ===== 清除所有 KubeVirt 规则并清空状态文件 =====
fw_cleanup_all() {
    detect_fw_backend || return 0

    case "$FW_BACKEND" in
        nftables) nft delete table inet kubevirt 2>/dev/null || true ;;
        iptables) _ipt_flush ;;
    esac

    [ -f "$KUBEVIRT_PORT_RULES" ] && : > "$KUBEVIRT_PORT_RULES"
}

# ===== 获取 VM 记录的 IP =====
fw_get_vm_ip() {
    local vm_name="$1"
    [ -f "$KUBEVIRT_PORT_RULES" ] || return 1
    awk -v name="$vm_name" '$1 == name {print $2}' "$KUBEVIRT_PORT_RULES"
}

# ===== 获取防火墙后端名称 =====
fw_backend_name() {
    detect_fw_backend || echo "none"
    echo "$FW_BACKEND"
}

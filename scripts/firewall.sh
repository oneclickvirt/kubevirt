#!/bin/bash
# =====================================================================
# KubeVirt 防火墙管理库
# nftables 优先，iptables 回退；IPv4 + IPv6 双栈支持
# 统一管理 VM 端口转发规则
# https://github.com/oneclickvirt/kubevirt
# =====================================================================

KUBEVIRT_CONF_DIR="/etc/kubevirt"
KUBEVIRT_PORT_RULES="${KUBEVIRT_CONF_DIR}/port-rules.conf"
KUBEVIRT_FW_LOCK="/var/lock/kubevirt-fw.lock"
FW_BACKEND=""

# 状态文件格式（每行）:
#   vm_name vm_ip ssh_port start_port end_port [vm_ip6]
# vm_ip6 为 "-" 或不存在时表示无 IPv6

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

_fw_is_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 0 ] && [ "$value" -le 65535 ]
}

_fw_valid_vm_name() {
    local vm_name="$1"
    [[ "$vm_name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]
}

_fw_validate_record() {
    local vm_name="$1" vm_ip="$2" ssh_port="$3" start_port="${4:-0}" end_port="${5:-0}" vm_ip6="${6:--}"

    _fw_valid_vm_name "$vm_name" || return 1
    [ -n "$vm_ip" ] && [ "$vm_ip" != "-" ] && [[ "$vm_ip" != *[[:space:]]* ]] || return 1
    [ -n "$vm_ip6" ] && [[ "$vm_ip6" != *[[:space:]]* ]] || return 1
    _fw_is_port "$ssh_port" && [ "$ssh_port" -gt 0 ] || return 1
    _fw_is_port "$start_port" || return 1
    _fw_is_port "$end_port" || return 1

    if { [ "$start_port" = "0" ] && [ "$end_port" != "0" ]; } || \
       { [ "$start_port" != "0" ] && [ "$end_port" = "0" ]; }; then
        return 1
    fi
    [ "$start_port" -le "$end_port" ] || return 1
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

    while IFS=' ' read -r vm_name vm_ip ssh_port start_port end_port vm_ip6; do
        [[ "$vm_name" =~ ^# || -z "$vm_name" ]] && continue
        vm_ip6="${vm_ip6:--}"
        if ! _fw_validate_record "$vm_name" "$vm_ip" "$ssh_port" "$start_port" "$end_port" "$vm_ip6"; then
            echo "[WARN] 跳过无效端口规则记录：${vm_name}" >&2
            continue
        fi

        # --- IPv4 规则 ---
        nft add rule inet kubevirt prerouting tcp dport "$ssh_port" dnat ip to "${vm_ip}:22" comment \"KUBEVIRT-VM-${vm_name}-ssh\"
        nft add rule inet kubevirt output tcp dport "$ssh_port" dnat ip to "${vm_ip}:22" comment \"KUBEVIRT-VM-${vm_name}-ssh-local\"
        nft add rule inet kubevirt postrouting ip saddr "$vm_ip" masquerade comment \"KUBEVIRT-VM-${vm_name}-masq\"

        # --- IPv6 规则（如果有 IPv6 地址）---
        if [ "$vm_ip6" != "-" ] && [ -n "$vm_ip6" ]; then
            nft add rule inet kubevirt prerouting tcp dport "$ssh_port" dnat ip6 to "[${vm_ip6}]:22" comment \"KUBEVIRT-VM-${vm_name}-ssh6\"
            nft add rule inet kubevirt output tcp dport "$ssh_port" dnat ip6 to "[${vm_ip6}]:22" comment \"KUBEVIRT-VM-${vm_name}-ssh6-local\"
            nft add rule inet kubevirt postrouting ip6 saddr "$vm_ip6" masquerade comment \"KUBEVIRT-VM-${vm_name}-masq6\"
        fi

        # --- 额外端口范围 ---
        if [ "$start_port" != "0" ] && [ "$end_port" != "0" ] && [ "$start_port" -le "$end_port" ]; then
            nft add rule inet kubevirt prerouting tcp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-tcp\"
            nft add rule inet kubevirt prerouting udp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-udp\"
            nft add rule inet kubevirt output tcp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-tcp-local\"
            nft add rule inet kubevirt output udp dport "${start_port}-${end_port}" dnat ip to "$vm_ip" comment \"KUBEVIRT-VM-${vm_name}-ports-udp-local\"
            if [ "$vm_ip6" != "-" ] && [ -n "$vm_ip6" ]; then
                nft add rule inet kubevirt prerouting tcp dport "${start_port}-${end_port}" dnat ip6 to "$vm_ip6" comment \"KUBEVIRT-VM-${vm_name}-ports6-tcp\"
                nft add rule inet kubevirt prerouting udp dport "${start_port}-${end_port}" dnat ip6 to "$vm_ip6" comment \"KUBEVIRT-VM-${vm_name}-ports6-udp\"
                nft add rule inet kubevirt output tcp dport "${start_port}-${end_port}" dnat ip6 to "$vm_ip6" comment \"KUBEVIRT-VM-${vm_name}-ports6-tcp-local\"
                nft add rule inet kubevirt output udp dport "${start_port}-${end_port}" dnat ip6 to "$vm_ip6" comment \"KUBEVIRT-VM-${vm_name}-ports6-udp-local\"
            fi
        fi
    done < "$KUBEVIRT_PORT_RULES"
}

# ===== iptables/ip6tables: 清除所有 KUBEVIRT 规则 =====
_ipt_flush() {
    local cmd
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        local chain
        for chain in PREROUTING OUTPUT POSTROUTING; do
            local i=0
            while [ "$i" -lt 500 ]; do
                local rule_num
                rule_num=$($cmd -t nat -L "$chain" --line-numbers -n 2>/dev/null | \
                    grep "KUBEVIRT-VM-" | head -1 | awk '{print $1}')
                [ -z "$rule_num" ] && break
                $cmd -t nat -D "$chain" "$rule_num" 2>/dev/null || break
                i=$((i + 1))
            done
        done
    done
}

# ===== iptables/ip6tables: 从状态文件重建全部规则 =====
_ipt_rebuild() {
    _ipt_flush

    while IFS=' ' read -r vm_name vm_ip ssh_port start_port end_port vm_ip6; do
        [[ "$vm_name" =~ ^# || -z "$vm_name" ]] && continue
        vm_ip6="${vm_ip6:--}"
        if ! _fw_validate_record "$vm_name" "$vm_ip" "$ssh_port" "$start_port" "$end_port" "$vm_ip6"; then
            echo "[WARN] 跳过无效端口规则记录：${vm_name}" >&2
            continue
        fi

        # --- IPv4 ---
        iptables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ssh" -p tcp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22"
        iptables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ssh-local" -p tcp --dport "$ssh_port" -j DNAT --to-destination "${vm_ip}:22"
        iptables -t nat -A POSTROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-masq" -s "${vm_ip}" -j MASQUERADE

        # --- IPv6（如果有地址且 ip6tables 可用）---
        if [ "$vm_ip6" != "-" ] && [ -n "$vm_ip6" ] && command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ssh6" -p tcp --dport "$ssh_port" -j DNAT --to-destination "[${vm_ip6}]:22"
            ip6tables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ssh6-local" -p tcp --dport "$ssh_port" -j DNAT --to-destination "[${vm_ip6}]:22"
            ip6tables -t nat -A POSTROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-masq6" -s "${vm_ip6}" -j MASQUERADE
        fi

        # --- 额外端口范围 ---
        if [ "$start_port" != "0" ] && [ "$end_port" != "0" ] && [ "$start_port" -le "$end_port" ]; then
            iptables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-tcp" -p tcp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
            iptables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-udp" -p udp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
            iptables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-tcp-local" -p tcp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
            iptables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ports-udp-local" -p udp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip}"
            if [ "$vm_ip6" != "-" ] && [ -n "$vm_ip6" ] && command -v ip6tables >/dev/null 2>&1; then
                ip6tables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ports6-tcp" -p tcp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip6}"
                ip6tables -t nat -A PREROUTING -m comment --comment "KUBEVIRT-VM-${vm_name}-ports6-udp" -p udp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip6}"
                ip6tables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ports6-tcp-local" -p tcp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip6}"
                ip6tables -t nat -A OUTPUT -m comment --comment "KUBEVIRT-VM-${vm_name}-ports6-udp-local" -p udp --dport "${start_port}:${end_port}" -j DNAT --to-destination "${vm_ip6}"
            fi
        fi
    done < "$KUBEVIRT_PORT_RULES"

    iptables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true

    # 通过 netfilter-persistent 持久化 iptables 规则
    _ipt_save_persistent
}

# ===== iptables: 通过 netfilter-persistent 保存规则 =====
_ipt_save_persistent() {
    # 方法1: netfilter-persistent (Debian/Ubuntu 推荐)
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    # 方法2: iptables-persistent 传统方式
    elif [ -x /etc/init.d/iptables-persistent ]; then
        /etc/init.d/iptables-persistent save 2>/dev/null || true
    # 方法3: Red Hat/CentOS 方式
    elif command -v iptables-save >/dev/null 2>&1; then
        # 保存 IPv4 规则
        mkdir -p /etc/sysconfig
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        # 保存 IPv6 规则（如果 ip6tables 可用）
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
        fi
    fi
}

# ===== 添加 VM 端口转发规则 =====
# 用法: fw_add_vm <vm_name> <vm_ip> <ssh_port> <start_port> <end_port> [vm_ip6]
fw_add_vm() {
    local vm_name="$1" vm_ip="$2" ssh_port="$3" start_port="${4:-0}" end_port="${5:-0}" vm_ip6="${6:--}"

    if ! _fw_validate_record "$vm_name" "$vm_ip" "$ssh_port" "$start_port" "$end_port" "$vm_ip6"; then
        echo "[ERROR] 无效端口规则参数：${vm_name} ${vm_ip} ${ssh_port} ${start_port} ${end_port} ${vm_ip6}" >&2
        return 1
    fi

    detect_fw_backend || return 1
    fw_ensure_dirs

    (
        flock -x 200 || return 1
        # 删除旧条目
        sed -i "/^${vm_name} /d" "$KUBEVIRT_PORT_RULES" 2>/dev/null || true
        # 添加新条目
        echo "${vm_name} ${vm_ip} ${ssh_port} ${start_port} ${end_port} ${vm_ip6}" >> "$KUBEVIRT_PORT_RULES"
        # 重建规则
        _fw_rebuild_locked
    ) 200>"$KUBEVIRT_FW_LOCK"
}

# ===== 删除 VM 端口转发规则 =====
# 用法: fw_remove_vm <vm_name>
fw_remove_vm() {
    local vm_name="$1"

    if ! _fw_valid_vm_name "$vm_name"; then
        echo "[ERROR] 无效 VM 名称：${vm_name}" >&2
        return 1
    fi

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
        *) return 1 ;;
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
        iptables) _ipt_flush ; _ipt_save_persistent ;;
    esac
}

# ===== 清除所有 KubeVirt 规则并清空状态文件 =====
# 用于完全卸载时，删除所有KUBEVIRT相关的防火墙规则
# 并持久化清理结果，确保重启后规则不会恢复
fw_cleanup_all() {
    detect_fw_backend || return 0

    case "$FW_BACKEND" in
        nftables) 
            nft delete table inet kubevirt 2>/dev/null || true 
            ;;
        iptables) 
            # 清除IPv4规则
            _ipt_flush
            # 同时清除IPv6规则（如果存在）
            if command -v ip6tables >/dev/null 2>&1; then
                local chain
                for chain in PREROUTING OUTPUT POSTROUTING; do
                    local i=0
                    while [ "$i" -lt 500 ]; do
                        local rule_num
                        rule_num=$(ip6tables -t nat -L "$chain" --line-numbers -n 2>/dev/null | \
                            grep "KUBEVIRT-VM-" | head -1 | awk '{print $1}')
                        [ -z "$rule_num" ] && break
                        ip6tables -t nat -D "$chain" "$rule_num" 2>/dev/null || break
                        i=$((i + 1))
                    done
                done
            fi
            # 持久化清理后的规则（IPv4 + IPv6）
            _ipt_save_persistent
            ;;
    esac

    # 清空状态文件
    [ -f "$KUBEVIRT_PORT_RULES" ] && : > "$KUBEVIRT_PORT_RULES"
}

# ===== 获取 VM 记录的 IPv4 =====
fw_get_vm_ip() {
    local vm_name="$1"
    [ -f "$KUBEVIRT_PORT_RULES" ] || return 1
    awk -v name="$vm_name" '$1 == name {print $2}' "$KUBEVIRT_PORT_RULES"
}

# ===== 获取 VM 记录的 IPv6 =====
fw_get_vm_ip6() {
    local vm_name="$1"
    [ -f "$KUBEVIRT_PORT_RULES" ] || return 1
    local ip6
    ip6=$(awk -v name="$vm_name" '$1 == name {print $6}' "$KUBEVIRT_PORT_RULES")
    [ -z "$ip6" ] || [ "$ip6" = "-" ] && return 1
    echo "$ip6"
}

# ===== 获取防火墙后端名称 =====
fw_backend_name() {
    if detect_fw_backend; then
        echo "$FW_BACKEND"
    else
        echo "none"
    fi
}

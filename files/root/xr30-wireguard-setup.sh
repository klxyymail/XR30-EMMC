#!/bin/sh
# =============================================================================
# XR30 eMMC / ImmortalWrt —— WireGuard 回家隧道（重新）初始化脚本
#
# 首次刷机时 uci-defaults 已经自动建好 wg0 并生成默认客户端 phone 的配置，
# 这个脚本用于「手动重来一遍 / 改端口 / 换网段 / 一次性加多个客户端」。
#
# 用法（路由器 SSH，root）：
#   sh /root/xr30-wireguard-setup.sh
#   VPN_PORT=51821 CLIENT_NAME=iphone sh /root/xr30-wireguard-setup.sh
#   FULL_TUNNEL=0 sh /root/xr30-wireguard-setup.sh        只访问家里内网
#   CLIENTS="phone ipad tv" sh /root/xr30-wireguard-setup.sh   一次建多个
#
# 可调变量：
#   VPN_PORT     监听端口，默认 51820/udp
#   VPN_NET      隧道网段前三位，默认 10.66.66（服务端 .1，客户端从 .2 起）
#   CLIENT_NAME  单个客户端名，默认 phone
#   CLIENTS      多个客户端名（空格分隔），优先于 CLIENT_NAME
#   FULL_TUNNEL  1=所有流量走家里（默认），0=只访问家里内网
#   ENDPOINT     固定公网域名/IP，留空自动探测
# =============================================================================

VPN_PORT="${VPN_PORT:-51820}"
VPN_NET="${VPN_NET:-10.66.66}"
CLIENT_NAME="${CLIENT_NAME:-phone}"
CLIENTS="${CLIENTS:-}"
FULL_TUNNEL="${FULL_TUNNEL:-1}"
ENDPOINT="${ENDPOINT:-}"
WG_DIR=/etc/wireguard
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/wg-backup-$TS"

log()  { printf '\033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$1"; }
die()  { printf '\033[31m[X]\033[0m %s\n' "$1" >&2; exit 1; }

# ---------- 0. 环境检查 ----------
[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -f /etc/config/network ] || die "这不是 OpenWrt 系统"
command -v uci >/dev/null 2>&1 || die "找不到 uci"

echo "--- 当前固件 ---"
. /etc/openwrt_release 2>/dev/null || true
echo "  系统: ${DISTRIB_DESCRIPTION:-未知}"
echo "  内核: $(uname -r)"

# ---------- 1. 依赖检查（本固件已内置，不再 opkg 安装） ----------
[ -x /usr/bin/wg ] || die "缺少 wireguard-tools：固件未编入该包（CONFIG_PACKAGE_wireguard-tools=y）"
[ -x /usr/bin/wg-client ] || warn "缺少 /usr/bin/wg-client，将使用脚本内建逻辑生成配置"
modprobe wireguard 2>/dev/null || true
wg show >/dev/null 2>&1 || die "WireGuard 内核模块不可用，请确认固件已编入 kmod-wireguard"
log "依赖检查通过"

# ---------- 2. 备份 ----------
mkdir -p "$BACKUP_DIR"
cp -f /etc/config/network "$BACKUP_DIR/network" 2>/dev/null || true
cp -f /etc/config/firewall "$BACKUP_DIR/firewall" 2>/dev/null || true
[ -d "$WG_DIR" ] && cp -a "$WG_DIR" "$BACKUP_DIR/wireguard" 2>/dev/null || true
log "原配置已备份到 $BACKUP_DIR"

# ---------- 3. 服务端密钥 ----------
mkdir -p "$WG_DIR/clients"
chmod 700 "$WG_DIR" "$WG_DIR/clients"
[ -s "$WG_DIR/server.key" ] || { umask 077; wg genkey > "$WG_DIR/server.key"; }
[ -s "$WG_DIR/server.pub" ] || wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub"
chmod 600 "$WG_DIR/server.key"
chmod 644 "$WG_DIR/server.pub"
log "服务端密钥就绪"

# ---------- 4. 内网网段 ----------
LAN_IP="$(uci -q get network.lan.ipaddr)"
[ -n "$LAN_IP" ] || LAN_IP=192.168.6.1
case "$LAN_IP" in
    *[!0-9.]*|"") die "读到的 LAN IP 异常：$LAN_IP" ;;
esac
LAN_NET="$(echo "$LAN_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')"
echo "  内网: $LAN_NET（网关 $LAN_IP）"
echo "$LAN_NET" > "$WG_DIR/lan.net"

# ---------- 5. wg0 接口 ----------
uci -q delete network.wg0
uci set network.wg0='interface'
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$(cat "$WG_DIR/server.key")"
uci set network.wg0.listen_port="$VPN_PORT"
# 1380 而不是 1420：PPPoE（1492）下 1420 容易分片，表现为「能握手但传不动文件」
uci set network.wg0.mtu='1380'
uci add_list network.wg0.addresses="${VPN_NET}.1/24"
uci commit network
log "wg0 写入完成（${VPN_NET}.1/24，UDP $VPN_PORT，MTU 1380）"

# ---------- 6. 防火墙 ----------
uci -q delete firewall.vpn
uci set firewall.vpn='zone'
uci set firewall.vpn.name='vpn'
uci set firewall.vpn.input='ACCEPT'
uci set firewall.vpn.output='ACCEPT'
uci set firewall.vpn.forward='ACCEPT'
uci set firewall.vpn.masq='1'
uci set firewall.vpn.mtu_fix='1'
uci add_list firewall.vpn.network='wg0'

uci -q delete firewall.vpn_to_lan
uci set firewall.vpn_to_lan='forwarding'
uci set firewall.vpn_to_lan.src='vpn'
uci set firewall.vpn_to_lan.dest='lan'

uci -q delete firewall.lan_to_vpn
uci set firewall.lan_to_vpn='forwarding'
uci set firewall.lan_to_vpn.src='lan'
uci set firewall.lan_to_vpn.dest='vpn'

# 关键：WAN 侧放行 UDP 端口。少了这条，隧道能起但外网永远连不进来。
uci -q delete firewall.wg_wan
uci set firewall.wg_wan='rule'
uci set firewall.wg_wan.name='Allow-WireGuard'
uci set firewall.wg_wan.src='wan'
uci set firewall.wg_wan.proto='udp'
uci set firewall.wg_wan.dest_port="$VPN_PORT"
uci set firewall.wg_wan.target='ACCEPT'
uci commit firewall
log "防火墙写入完成（vpn 区域 + 双向转发 + WAN 放行 UDP $VPN_PORT）"

# ---------- 7. 应用 ----------
/etc/init.d/network reload >/dev/null 2>&1 || true
sleep 2
ifup wg0 >/dev/null 2>&1 || /etc/init.d/network restart >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true
sleep 1
wg show wg0 >/dev/null 2>&1 && log "wg0 已启动" || warn "wg0 未启动，稍后执行 /etc/init.d/network restart 重试"

# ---------- 8. 生成客户端 ----------
[ -n "$ENDPOINT" ] && { echo "$ENDPOINT" > "$WG_DIR/endpoint"; log "Endpoint 固定为 $ENDPOINT"; }

MODE="full"
[ "$FULL_TUNNEL" = "0" ] && MODE="lan"

LIST="$CLIENTS"
[ -n "$LIST" ] || LIST="$CLIENT_NAME"

if [ -x /usr/bin/wg-client ]; then
    for _c in $LIST; do
        echo ""
        wg-client add "$_c" "$MODE"
    done
else
    warn "缺少 wg-client，跳过客户端配置生成。手动方法：LuCI → 网络 → 接口 → 添加新接口 wg0 的 peer"
fi

# ---------- 9. 公网可达性提示 ----------
EP="$(cat "$WG_DIR/endpoint" 2>/dev/null || true)"
if [ -z "$EP" ]; then
    EP="$(uci -q get network.wan.ipaddr)"
fi
if [ -z "$EP" ]; then
    EP="$(wget -q -O - -T 8 https://api.ipify.org 2>/dev/null)"
fi

echo ""
echo "--- 还需要确认的事 ---"
case "$EP" in
    10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*|"")
        warn "当前 WAN 地址是内网/CGNAT（$EP），外网直连进不来"
        echo "    A) 光猫改桥接 + 路由器 PPPoE 拨号，拿到公网 IPv4，再放行 UDP $VPN_PORT"
        echo "    B) 用固件内置 ZeroTier（LuCI → VPN → ZeroTier），无需公网 IP"
        ;;
    *)
        echo "  1) 光猫/上级路由放行 UDP $VPN_PORT 到 $EP（DMZ 或端口转发）"
        echo "  2) 动态 IP 建议配 DDNS：LuCI → 服务 → 动态 DNS，然后把域名固定下来："
        echo "     wg-client endpoint 你的域名.xxx.org"
        ;;
esac
echo "  3) 查看握手：wg show wg0 latest-handshakes"
echo "  4) 回滚：cp $BACKUP_DIR/network /etc/config/network && cp $BACKUP_DIR/firewall /etc/config/firewall && /etc/init.d/network restart"
echo "  5) 加客户端：wg-client add <名字>"

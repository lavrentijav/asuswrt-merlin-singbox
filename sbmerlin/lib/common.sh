#!/bin/sh
# sbmerlin — common helpers: paths, logging, locking, platform detection.
# POSIX sh (busybox ash). No bashisms.

SBM_NAME="sbmerlin"
SBM_VERSION="0.1.0"
SBM_SCHEMA_VERSION=1

# Paths may be overridden for local testing.
SBM_ADDON_DIR="${SBM_ADDON_DIR:-/jffs/addons/sbmerlin}"
SBM_DATA_DIR="${SBM_DATA_DIR:-/opt/share/sbmerlin}"
SBM_BIN="${SBM_BIN:-/opt/sbin/sing-box}"

SBM_LIB_DIR="$SBM_ADDON_DIR/lib"
SBM_WWW_DIR="$SBM_ADDON_DIR/www"
SBM_TEMPLATE_DIR="$SBM_ADDON_DIR/templates"

SBM_SETTINGS="$SBM_DATA_DIR/settings.json"
SBM_CONFIG="$SBM_DATA_DIR/config.json"
SBM_GEO_DIR="$SBM_DATA_DIR/geo"
SBM_CACHE="$SBM_DATA_DIR/cache.db"
SBM_LOG="$SBM_DATA_DIR/sbmerlin.log"
SBM_CORE_LOG="$SBM_DATA_DIR/sing-box.log"
SBM_RUN_DIR="${SBM_RUN_DIR:-/var/run}"
SBM_PID="$SBM_RUN_DIR/sbmerlin.pid"
SBM_STATE="$SBM_DATA_DIR/state.json"

# Network constants
SBM_TPROXY_PORT="${SBM_TPROXY_PORT:-7893}"
SBM_REDIR_PORT="${SBM_REDIR_PORT:-7892}"
SBM_DNS_PORT="${SBM_DNS_PORT:-7853}"  # 5353 is taken by avahi-daemon on ASUS firmware
SBM_API_PORT="${SBM_API_PORT:-9095}"
# Mark and table must not collide with the firmware's own: /etc/iproute2/rt_tables
# maps 100->wan0, 111-115->ovpnc1..5, 200->wan1, and low marks are used by QoS/VPN.
SBM_FWMARK="${SBM_FWMARK:-0x5b0}"
SBM_ROUTE_TABLE="${SBM_ROUTE_TABLE:-9863}"

# Marker used for every line we inject into firmware hook scripts.
SBM_TAG="# sbmerlin"

SBM_LOG_MAX_BYTES="${SBM_LOG_MAX_BYTES:-262144}"

# Health-check target for node election. It must live on the same infrastructure
# as the traffic that matters: a node can answer cp.cloudflare.com long after
# Google and YouTube have become unreachable through it.
SBM_HEALTH_URL="${SBM_HEALTH_URL:-https://www.gstatic.com/generate_204}"

# Firmware binaries must be used for anything that talks to the kernel: the Entware
# copies (iptables 1.4.21 / ipset 7.24) mismatch the 4.1 kernel modules the firmware
# built its own (1.4.15 / 7.6) against.
SBM_IPT="${SBM_IPT:-/usr/sbin/iptables}"
SBM_IPSET="${SBM_IPSET:-/usr/sbin/ipset}"
SBM_IP="${SBM_IP:-/usr/sbin/ip}"
# Entware userland for everything else.
SBM_JQ="${SBM_JQ:-/opt/bin/jq}"
SBM_CURL="${SBM_CURL:-/opt/bin/curl}"

sbm_log() {
	_lvl="$1"; shift
	_msg="$(date '+%Y-%m-%d %H:%M:%S') [$_lvl] $*"
	[ -d "$SBM_DATA_DIR" ] && printf '%s\n' "$_msg" >> "$SBM_LOG" 2>/dev/null
	[ -n "$SBM_VERBOSE" ] && printf '%s\n' "$_msg" >&2
	return 0
}
sbm_info()  { sbm_log INFO  "$@"; }
sbm_warn()  { sbm_log WARN  "$@"; }
sbm_error() { sbm_log ERROR "$@"; SBM_VERBOSE=1 printf '%s\n' "$*" >&2; }
sbm_die()   { sbm_error "$@"; exit 1; }

sbm_rotate_log() {
	for _f in "$SBM_LOG" "$SBM_CORE_LOG"; do
		[ -f "$_f" ] || continue
		_sz=$(sbm_filesize "$_f")
		[ "$_sz" -gt "$SBM_LOG_MAX_BYTES" ] 2>/dev/null && mv -f "$_f" "$_f.1"
	done
	return 0
}

sbm_filesize() {
	# busybox stat may lack -c on some builds; fall back to wc.
	stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0
}

# --- locking -----------------------------------------------------------------
# Single global lock; every mutating entry point takes it so that cron, the WebUI
# and a shell session cannot rewrite the config at the same time.
sbm_lock() {
	_lockdir="$SBM_RUN_DIR/sbmerlin.lock"
	_tries=0
	while ! mkdir "$_lockdir" 2>/dev/null; do
		_tries=$((_tries + 1))
		if [ "$_tries" -gt 60 ]; then
			# Stale lock (owner died) — take it over.
			if [ -f "$_lockdir/pid" ] && ! kill -0 "$(cat "$_lockdir/pid" 2>/dev/null)" 2>/dev/null; then
				sbm_warn "removing stale lock"
				rm -rf "$_lockdir"
				continue
			fi
			sbm_error "could not acquire lock"
			return 1
		fi
		sleep 1
	done
	echo $$ > "$_lockdir/pid"
	SBM_LOCK_HELD=1
	return 0
}

sbm_unlock() {
	[ -n "$SBM_LOCK_HELD" ] || return 0
	rm -rf "$SBM_RUN_DIR/sbmerlin.lock"
	unset SBM_LOCK_HELD
	return 0
}

# --- platform ----------------------------------------------------------------
sbm_arch() {
	case "$(uname -m)" in
		aarch64|arm64) echo "linux-arm64" ;;
		armv7l|armv7|armv8l) echo "linux-armv7" ;;
		mips) echo "linux-mips-softfloat" ;;
		x86_64|amd64) echo "linux-amd64" ;;
		*) echo "unsupported" ;;
	esac
}

sbm_has_module() {
	# A module counts as available if it is loaded, loadable, or built in.
	_m="$1"
	lsmod 2>/dev/null | grep -q "^$_m " && return 0
	modprobe "$_m" 2>/dev/null && return 0
	[ -d "/sys/module/$_m" ] && return 0
	return 1
}

# NOTE: busybox ash on Merlin has no `command` builtin in non-interactive mode.
sbm_have() { which "$1" >/dev/null 2>&1; }

# Effective intercept mode: what the user asked for, degraded to what the kernel supports.
sbm_effective_mode() {
	_want="${1:-tproxy}"
	if [ "$_want" = "tproxy" ]; then
		if sbm_has_module xt_TPROXY || sbm_has_module nft_tproxy; then
			echo tproxy
		else
			echo redirect
		fi
	else
		echo redirect
	fi
}

sbm_lan_if()  { nvram get lan_ifname 2>/dev/null || echo br0; }
sbm_lan_ip()  { nvram get lan_ipaddr 2>/dev/null || echo 192.168.1.1; }

# Upstream resolver for "local" lookups. It must NOT be the router's own address:
# dnsmasq forwards to sing-box, so pointing back at dnsmasq builds a DNS loop.
sbm_wan_dns() {
	for _v in wan0_xdns wan0_dns wan1_xdns wan1_dns; do
		for _d in $(nvram get "$_v" 2>/dev/null); do
			case "$_d" in
				''|0.0.0.0|127.*) continue ;;
				"$(sbm_lan_ip)") continue ;;
			esac
			printf '%s' "$_d"
			return 0
		done
	done
	# Last resort: a resolver that at least answers, even if it is not the ISP's.
	printf '77.88.8.8'
}
sbm_lan_cidr() {
	_ip=$(sbm_lan_ip)
	_mask=$(nvram get lan_netmask 2>/dev/null || echo 255.255.255.0)
	_bits=0
	for _o in $(echo "$_mask" | tr '.' ' '); do
		while [ "$_o" -gt 0 ]; do
			_bits=$((_bits + (_o % 2)))
			_o=$((_o / 2))
		done
	done
	_net=$(echo "$_ip" | awk -F. '{print $1"."$2"."$3".0"}')
	echo "$_net/$_bits"
}

# Reserved ranges that must never be proxied.
SBM_RESERVED_NETS="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"

sbm_require_jq() {
	[ -x "$SBM_JQ" ] && return 0
	sbm_have jq && { SBM_JQ=jq; return 0; }
	sbm_die "jq not found — install with: opkg install jq"
}

sbm_json_get() {
	# sbm_json_get <file> <jq-filter> [default]
	_out=$("$SBM_JQ" -r "$2 // empty" "$1" 2>/dev/null)
	if [ -z "$_out" ]; then printf '%s' "$3"; else printf '%s' "$_out"; fi
}

# Atomically replace a file: write to .tmp then rename.
sbm_atomic_write() {
	_dest="$1"
	_tmp="$_dest.tmp.$$"
	cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$_dest"
}

sbm_sha256() {
	if sbm_have sha256sum; then sha256sum "$1" | awk '{print $1}'
	elif sbm_have openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
	else echo ""; fi
}

sbm_fetch() {
	# sbm_fetch <url> <dest> — curl preferred, wget fallback.
	_url="$1"; _dest="$2"
	if [ -x "$SBM_CURL" ]; then
		"$SBM_CURL" -fsSL --connect-timeout 10 --max-time 120 -o "$_dest" "$_url"
	else
		wget -q -T 10 -O "$_dest" "$_url"
	fi
}

sbm_mkdirs() {
	mkdir -p "$SBM_DATA_DIR" "$SBM_GEO_DIR" "$SBM_ADDON_DIR" 2>/dev/null
	return 0
}

# Switching firmware apps (Download Master and friends) repoints /tmp/opt at the
# old ASUS Optware tree, and Entware — jq, curl, sing-box and all our data —
# silently disappears from every path. Point it back at the Entware tree.
sbm_repair_opt() {
	[ -x /opt/bin/jq ] && return 0
	for _d in /tmp/mnt/*/entware; do
		[ -x "$_d/bin/jq" ] || continue
		ln -nsf "$_d" /tmp/opt
		logger -t sbmerlin "Entware link was repointed; restored /tmp/opt -> $_d"
		sbm_warn "Entware link was repointed; restored /tmp/opt -> $_d"
		return 0
	done
	return 1
}

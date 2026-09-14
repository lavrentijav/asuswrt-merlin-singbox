#!/bin/sh
# sbmerlin — packet interception. TPROXY (TCP+UDP) with a REDIRECT fallback for
# kernels without xt_TPROXY. All rules live in our own chains so teardown is exact.

SBM_CHAIN="SBM_PRE"
SBM_SET_BYPASS_IP="sbm_byp_ip"
SBM_SET_BYPASS_MAC="sbm_byp_mac"
SBM_SET_DIRECT_NET="sbm_direct_net"

_sbm_ipt()   { "$SBM_IPT" "$@" 2>/dev/null; }
_sbm_ipset() { "$SBM_IPSET" "$@" 2>/dev/null; }

sbm_ipset_init() {
	_sbm_ipset create "$SBM_SET_BYPASS_IP"  hash:ip  family inet -exist
	_sbm_ipset create "$SBM_SET_BYPASS_MAC" hash:mac -exist
	_sbm_ipset create "$SBM_SET_DIRECT_NET" hash:net family inet -exist
	# One set per group that has pinned clients.
	for _g in $(sbm_forced_groups); do
		_sbm_ipset create "sbm_f_${_g}_ip"  hash:ip  family inet -exist
		_sbm_ipset create "sbm_f_${_g}_mac" hash:mac -exist
	done
}

# Groups referenced by a client in "force:<group>" mode.
sbm_forced_groups() {
	[ -f "$SBM_SETTINGS" ] || return 0
	"$SBM_JQ" -r '[.clients[]? | select((.mode // "") | startswith("force:"))
		| (.mode | ltrimstr("force:"))] | unique | .[]' "$SBM_SETTINGS" 2>/dev/null
}

# Fill the sets from settings.json: bypassed clients and pinned clients.
sbm_ipset_load() {
	_sbm_ipset flush "$SBM_SET_BYPASS_IP"
	_sbm_ipset flush "$SBM_SET_BYPASS_MAC"
	for _g in $(sbm_forced_groups); do
		_sbm_ipset flush "sbm_f_${_g}_ip"
		_sbm_ipset flush "sbm_f_${_g}_mac"
	done

	"$SBM_JQ" -r '.clients[]? | "\(.mode // "rules")\t\(.mac // "")\t\(.ip // "")"' \
		"$SBM_SETTINGS" 2>/dev/null | while IFS="$(printf '\t')" read -r _mode _mac _ip; do
		case "$_mode" in
			bypass)
				[ -n "$_mac" ] && _sbm_ipset add "$SBM_SET_BYPASS_MAC" "$_mac" -exist
				[ -n "$_ip" ]  && _sbm_ipset add "$SBM_SET_BYPASS_IP" "$_ip" -exist
				;;
			force:*)
				_g="${_mode#force:}"
				[ -n "$_mac" ] && _sbm_ipset add "sbm_f_${_g}_mac" "$_mac" -exist
				[ -n "$_ip" ]  && _sbm_ipset add "sbm_f_${_g}_ip" "$_ip" -exist
				;;
		esac
	done
	sbm_ipset_load_direct
}

# Large "always direct" IP lists stay in the kernel: such packets never reach
# sing-box at all, which is the cheapest possible path for RU traffic.
sbm_ipset_load_direct() {
	_f="$SBM_GEO_DIR/direct-nets.lst"
	[ -f "$_f" ] || return 0
	_sbm_ipset create "${SBM_SET_DIRECT_NET}_new" hash:net family inet -exist
	_sbm_ipset flush "${SBM_SET_DIRECT_NET}_new"
	while IFS= read -r _net; do
		case "$_net" in ''|\#*) continue ;; esac
		_sbm_ipset add "${SBM_SET_DIRECT_NET}_new" "$_net" -exist
	done < "$_f"
	# Swap is atomic: no window where the list is half-loaded.
	_sbm_ipset swap "${SBM_SET_DIRECT_NET}_new" "$SBM_SET_DIRECT_NET"
	_sbm_ipset destroy "${SBM_SET_DIRECT_NET}_new"
	sbm_info "direct-net set: $(_sbm_ipset list "$SBM_SET_DIRECT_NET" | grep -c '^[0-9]') entries"
}

sbm_firewall_up() {
	_mode=$(sbm_effective_mode "$(sbm_json_get "$SBM_SETTINGS" '.general.mode' tproxy)")
	sbm_firewall_down
	# Sets for groups nobody is pinned to any more: the chain no longer references
	# them once it is torn down, so they can go.
	_keep=" $(sbm_forced_groups | tr '
' ' ') "
	for _set in $(_sbm_ipset list -n | grep '^sbm_f_'); do
		_g=${_set#sbm_f_}; _g=${_g%_*}
		case "$_keep" in *" $_g "*) : ;; *) _sbm_ipset destroy "$_set" ;; esac
	done
	sbm_ipset_init
	sbm_ipset_load
	_lan=$(sbm_lan_if)
	_lanip=$(sbm_lan_ip)

	if [ "$_mode" = "tproxy" ]; then
		modprobe xt_TPROXY 2>/dev/null
		modprobe xt_socket 2>/dev/null
		"$SBM_IP" rule add fwmark "$SBM_FWMARK" lookup "$SBM_ROUTE_TABLE" 2>/dev/null
		"$SBM_IP" route add local default dev lo table "$SBM_ROUTE_TABLE" 2>/dev/null

		_sbm_ipt -t mangle -N "$SBM_CHAIN"
		_sbm_ipt -t mangle -F "$SBM_CHAIN"
		_sbm_firewall_exclusions mangle
		# Pinned clients first: each group has its own inbound port.
		_i=0
		for _g in $(sbm_forced_groups); do
			_port=$((SBM_TPROXY_PORT + 1 + _i))
			for _proto in tcp udp; do
				_sbm_ipt -t mangle -A "$SBM_CHAIN" -p "$_proto" -m set --match-set "sbm_f_${_g}_mac" src \
					-j TPROXY --on-port "$_port" --tproxy-mark "$SBM_FWMARK"
				_sbm_ipt -t mangle -A "$SBM_CHAIN" -p "$_proto" -m set --match-set "sbm_f_${_g}_ip" src \
					-j TPROXY --on-port "$_port" --tproxy-mark "$SBM_FWMARK"
			done
			_i=$((_i + 1))
		done
		for _proto in tcp udp; do
			_sbm_ipt -t mangle -A "$SBM_CHAIN" -p "$_proto" \
				-j TPROXY --on-port "$SBM_TPROXY_PORT" --tproxy-mark "$SBM_FWMARK"
		done
		_sbm_ipt -t mangle -A PREROUTING -i "$_lan" -j "$SBM_CHAIN"
	else
		# REDIRECT fallback: TCP only, UDP stays direct.
		sbm_warn "xt_TPROXY unavailable — running in REDIRECT mode, UDP/QUIC is not proxied"
		_sbm_ipt -t nat -N "$SBM_CHAIN"
		_sbm_ipt -t nat -F "$SBM_CHAIN"
		_sbm_firewall_exclusions nat
		_i=0
		for _g in $(sbm_forced_groups); do
			_port=$((SBM_REDIR_PORT + 1 + _i))
			_sbm_ipt -t nat -A "$SBM_CHAIN" -p tcp -m set --match-set "sbm_f_${_g}_mac" src \
				-j REDIRECT --to-ports "$_port"
			_sbm_ipt -t nat -A "$SBM_CHAIN" -p tcp -m set --match-set "sbm_f_${_g}_ip" src \
				-j REDIRECT --to-ports "$_port"
			_i=$((_i + 1))
		done
		_sbm_ipt -t nat -A "$SBM_CHAIN" -p tcp -j REDIRECT --to-ports "$SBM_REDIR_PORT"
		_sbm_ipt -t nat -A PREROUTING -i "$_lan" -p tcp -j "$SBM_CHAIN"
	fi

	sbm_socks_open "$_lan"
	sbm_info "firewall up in $_mode mode on $_lan ($_lanip)"
	echo "$_mode"
}

# The LAN-facing SOCKS/HTTP port has to be accepted explicitly: the firmware's
# INPUT chain drops anything it does not know about.
sbm_socks_open() {
	_lan="${1:-$(sbm_lan_if)}"
	_port=$(sbm_json_get "$SBM_SETTINGS" '.general.socks_port' 0)
	[ "$_port" -gt 0 ] 2>/dev/null || return 0
	_sbm_ipt -I INPUT -i "$_lan" -p tcp --dport "$_port" -j ACCEPT
	_sbm_ipt -I INPUT -i "$_lan" -p udp --dport "$_port" -j ACCEPT
	sbm_info "SOCKS5/HTTP proxy open on $(sbm_lan_ip):$_port for $_lan"
}

sbm_socks_close() {
	_lan=$(sbm_lan_if)
	for _p in $(sbm_json_get "$SBM_SETTINGS" '.general.socks_port' 0) \
	          $(sbm_json_get "$SBM_SETTINGS" '.general.socks_port_prev' 0); do
		[ "$_p" -gt 0 ] 2>/dev/null || continue
		while _sbm_ipt -D INPUT -i "$_lan" -p tcp --dport "$_p" -j ACCEPT; do :; done
		while _sbm_ipt -D INPUT -i "$_lan" -p udp --dport "$_p" -j ACCEPT; do :; done
	done
	return 0
}

# Traffic that must never be proxied, in both table variants.
_sbm_firewall_exclusions() {
	_t="$1"
	_lanip=$(sbm_lan_ip)
	# The router itself (DNS, WebUI, SSH) and the proxy's own uplink.
	_sbm_ipt -t "$_t" -A "$SBM_CHAIN" -d "$_lanip" -j RETURN
	for _net in $SBM_RESERVED_NETS; do
		_sbm_ipt -t "$_t" -A "$SBM_CHAIN" -d "$_net" -j RETURN
	done
	_sbm_ipt -t "$_t" -A "$SBM_CHAIN" -m set --match-set "$SBM_SET_DIRECT_NET" dst -j RETURN
	_sbm_ipt -t "$_t" -A "$SBM_CHAIN" -m set --match-set "$SBM_SET_BYPASS_MAC" src -j RETURN
	_sbm_ipt -t "$_t" -A "$SBM_CHAIN" -m set --match-set "$SBM_SET_BYPASS_IP" src -j RETURN
	# Node servers are reached directly, otherwise the proxy would loop through itself.
	for _srv in $(sbm_node_server_ips); do
		_sbm_ipt -t "$_t" -A "$SBM_CHAIN" -d "$_srv" -j RETURN
	done
}

# Resolved addresses of every configured node server.
sbm_node_server_ips() {
	[ -f "$SBM_SETTINGS" ] || return 0
	for _h in $("$SBM_JQ" -r '[.nodes[]?.json.server // empty] | unique | .[]' "$SBM_SETTINGS" 2>/dev/null); do
		case "$_h" in
			*[0-9].[0-9]*) # already an address
				printf '%s\n' "$_h"; continue ;;
		esac
		# busybox nslookup prints the resolver first, then the answers; take the
		# answer column and drop anything that is not a routable address.
		nslookup "$_h" 2>/dev/null | sed -n 's/^Address [0-9]*: \([0-9.]*\).*/\1/p;s/^Address: \([0-9.]*\).*/\1/p' \
			| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
			| grep -vE '^(0\.0\.0\.0|127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
			| head -4
	done | sort -u
}

sbm_firewall_down() {
	_lan=$(sbm_lan_if)
	sbm_socks_close
	while _sbm_ipt -t mangle -D PREROUTING -i "$_lan" -j "$SBM_CHAIN"; do :; done
	while _sbm_ipt -t nat -D PREROUTING -i "$_lan" -p tcp -j "$SBM_CHAIN"; do :; done
	_sbm_ipt -t mangle -F "$SBM_CHAIN"; _sbm_ipt -t mangle -X "$SBM_CHAIN"
	_sbm_ipt -t nat -F "$SBM_CHAIN";    _sbm_ipt -t nat -X "$SBM_CHAIN"
	"$SBM_IP" rule del fwmark "$SBM_FWMARK" lookup "$SBM_ROUTE_TABLE" 2>/dev/null
	# Delete only our own route: never flush a table the firmware might share.
	"$SBM_IP" route del local default dev lo table "$SBM_ROUTE_TABLE" 2>/dev/null
	return 0
}

# Full teardown including the sets (used by uninstall).
sbm_firewall_purge() {
	sbm_firewall_down
	for _s in "$SBM_SET_BYPASS_IP" "$SBM_SET_BYPASS_MAC" "$SBM_SET_DIRECT_NET"; do
		_sbm_ipset destroy "$_s"
	done
	for _g in $(sbm_forced_groups); do
		_sbm_ipset destroy "sbm_f_${_g}_ip"
		_sbm_ipset destroy "sbm_f_${_g}_mac"
	done
	return 0
}

sbm_firewall_status() {
	_sbm_ipt -t mangle -S "$SBM_CHAIN" 2>/dev/null | head -30
	_sbm_ipt -t nat -S "$SBM_CHAIN" 2>/dev/null | head -30
}

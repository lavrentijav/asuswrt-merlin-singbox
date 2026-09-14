#!/bin/sh
# sbmerlin — sing-box process lifecycle.

sbm_pid() {
	[ -f "$SBM_PID" ] || return 1
	_p=$(cat "$SBM_PID" 2>/dev/null)
	[ -n "$_p" ] && [ -d "/proc/$_p" ] || return 1
	grep -q sing-box "/proc/$_p/cmdline" 2>/dev/null || return 1
	printf '%s' "$_p"
}

sbm_running() { sbm_pid >/dev/null 2>&1; }

# Resident memory of the core, in MiB.
sbm_rss_mb() {
	_p=$(sbm_pid) || { echo 0; return 1; }
	_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$_p/status" 2>/dev/null)
	echo $(( ${_kb:-0} / 1024 ))
}

# Seconds the core process has been alive, from its start time in jiffies.
sbm_core_uptime() {
	_p=$(sbm_pid) || { echo 0; return 1; }
	_starttime=$(awk '{print $22}' "/proc/$_p/stat" 2>/dev/null)
	_hz=$(getconf CLK_TCK 2>/dev/null); [ -n "$_hz" ] || _hz=100
	_boot=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
	[ -n "$_starttime" ] && [ -n "$_boot" ] || { echo 0; return 1; }
	echo $(( _boot - _starttime / _hz ))
}

sbm_core_start() {
	sbm_running && { sbm_info "already running"; return 0; }
	[ -x "$SBM_BIN" ] || { sbm_error "sing-box binary missing: $SBM_BIN"; return 1; }
	[ -f "$SBM_CONFIG" ] || { sbm_error "no config — run 'sbmerlin gen' first"; return 1; }

	_mem=$(sbm_json_get "$SBM_SETTINGS" '.general.mem_limit_mb' 48)
	sbm_rotate_log

	# GOMEMLIMIT is the main RAM lever: it makes the Go runtime collect early
	# instead of growing the heap to whatever the machine allows.
	GOMEMLIMIT="${_mem}MiB" GOGC=40 \
		"$SBM_BIN" run -c "$SBM_CONFIG" -D "$SBM_DATA_DIR" >> "$SBM_CORE_LOG" 2>&1 &
	echo $! > "$SBM_PID"

	# Wait for the control API to answer before reporting success.
	_i=0
	while [ "$_i" -lt 30 ]; do
		sbm_api_get /version >/dev/null 2>&1 && {
			sbm_info "started (pid $(cat "$SBM_PID"), mem limit ${_mem}MiB)"
			return 0
		}
		sbm_running || break
		_i=$((_i + 1))
		sleep 1
	done
	sbm_error "core failed to start; last log lines:"
	tail -5 "$SBM_CORE_LOG" >&2
	sbm_core_stop
	return 1
}

sbm_core_stop() {
	_p=$(sbm_pid) || { rm -f "$SBM_PID"; return 0; }
	kill "$_p" 2>/dev/null
	_i=0
	while [ "$_i" -lt 10 ] && [ -d "/proc/$_p" ]; do
		_i=$((_i + 1))
		sleep 1
	done
	[ -d "/proc/$_p" ] && kill -9 "$_p" 2>/dev/null
	rm -f "$SBM_PID"
	sbm_info "stopped"
	return 0
}

# --- clash API ---------------------------------------------------------------
sbm_api_get() {
	"$SBM_CURL" -fsS --max-time 5 "http://127.0.0.1:$SBM_API_PORT$1" 2>/dev/null
}

sbm_api_put() {
	"$SBM_CURL" -fsS --max-time 5 -X PUT -H 'Content-Type: application/json' \
		-d "$2" "http://127.0.0.1:$SBM_API_PORT$1" 2>/dev/null
}

# sbm_group_delays <group_tag> — trigger a health check and print "node<TAB>ms".
sbm_group_test() {
	_g="$1"
	_url=$("$SBM_JQ" -rn --arg d "$(sbm_json_get "$SBM_SETTINGS" '.groups[0].url' '')" \
		'if $d == "" then "http://cp.cloudflare.com/generate_204" else $d end')
	sbm_api_get "/group/$_g/delay?url=$_url&timeout=5000"
}

# --- dnsmasq -----------------------------------------------------------------
# Point the LAN resolver at sing-box so DNS answers follow the same routing rules.
sbm_dnsmasq_conf() {
	_hijack=$(sbm_json_get "$SBM_SETTINGS" '.general.dns.hijack' true)
	_f="$1"
	[ -n "$_f" ] || return 0
	sed -i '/#sbmerlin$/d' "$_f" 2>/dev/null
	[ "$_hijack" = "true" ] || return 0
	sbm_running || return 0
	# Only add keys the firmware does not already set: dnsmasq refuses to start
	# on a repeated single-value keyword ("illegal repeated keyword"), and a dead
	# dnsmasq means no DHCP and no clients on the LAN at all.
	grep -qE '^[[:space:]]*no-resolv' "$_f" || echo "no-resolv #sbmerlin" >> "$_f"
	echo "server=127.0.0.1#$SBM_DNS_PORT #sbmerlin" >> "$_f"
	return 0
}

sbm_dnsmasq_running() { ps w 2>/dev/null | grep -q '[d]nsmasq --log-async\|[d]nsmasq -'; }

# A dead dnsmasq means no DHCP and no LAN at all, so never leave it down: if it
# did not come back, drop our additions and restart it without them.
sbm_dnsmasq_verify() {
	_i=0
	while [ "$_i" -lt 12 ]; do
		sbm_dnsmasq_running && return 0
		_i=$((_i + 1))
		sleep 1
	done
	sbm_error "dnsmasq did not start — removing sbmerlin DNS lines and restarting it"
	sed -i '/#sbmerlin$/d' /etc/dnsmasq.conf 2>/dev/null
	# Keep it out of the generated config until the user re-enables it.
	"$SBM_JQ" '.general.dns.hijack = false' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" \
		&& mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
	service restart_dnsmasq >/dev/null 2>&1
	return 1
}

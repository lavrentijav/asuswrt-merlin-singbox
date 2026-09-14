#!/bin/sh
# sbmerlin — liveness, memory cap and group failover.
#
# sing-box's urltest already picks a healthy node inside a group. What it cannot
# express is "the whole group is down": for rules configured with on_fail=direct
# we flip their selector to `direct` here, and flip it back on recovery. Rules
# configured with on_fail=block need nothing — a dead group fails the dial, which
# is exactly the kill-switch behaviour.

sbm_watchdog() {
	# The WebUI lives in tmpfs; httpd restarts and firmware events can wipe it.
	if [ ! -f "$SBM_EXT_DIR/settings.json" ] || ! grep -q sbmerlin "$SBM_MENU_SRC" 2>/dev/null; then
		sbm_mount_ui
		sbm_export_ui
	fi

	# Losing dnsmasq costs the whole LAN its DHCP, so check it before anything else.
	if ! sbm_dnsmasq_running; then
		sbm_warn "dnsmasq is down — repairing"
		sbm_dnsmasq_verify
	fi

	_enabled=$(sbm_json_get "$SBM_SETTINGS" '.general.enabled' false)
	[ "$_enabled" = "true" ] || { sbm_write_status; return 0; }

	if ! sbm_running; then
		sbm_warn "core not running — restarting"
		sbm_core_start || return 1
	fi

	_limit=$(sbm_json_get "$SBM_SETTINGS" '.general.watchdog.rss_limit_mb' 96)
	_rss=$(sbm_rss_mb)
	if [ "$_rss" -gt "$_limit" ] 2>/dev/null; then
		sbm_warn "RSS ${_rss}MiB over ${_limit}MiB limit — restarting core"
		sbm_core_stop
		sbm_core_start
	fi

	# cron is the only thing driving this function; if it vanished (a reboot wipes
	# /var/spool) nothing would ever run again, including this check.
	cru l 2>/dev/null | grep -q sbmerlin_watchdog || {
		sbm_warn "cron entries missing — reinstalling"
		sbm_cron_install
	}

	sbm_rotate_log
	sbm_refresh_groups
	sbm_failover_check
	sbm_write_status
}

# Ask the core to re-measure every group. urltest only re-elects on its own
# schedule and will keep a node that still answers the cheap health URL while
# real traffic through it already fails — which is exactly what makes YouTube
# die until a restart. Probing here forces a fresh election every few minutes.
sbm_refresh_groups() {
	for _g in $("$SBM_JQ" -r '.groups[]?.id' "$SBM_SETTINGS" 2>/dev/null); do
		_before=$(sbm_api_get "/proxies/grp-$_g" | "$SBM_JQ" -r '.now // ""')
		_alive=$(sbm_group_alive_count "$_g")
		_after=$(sbm_api_get "/proxies/grp-$_g" | "$SBM_JQ" -r '.now // ""')
		if [ "$_before" != "$_after" ]; then
			sbm_info "group $_g re-elected: $_before -> $_after ($_alive alive)"
		fi
	done
	return 0
}

# Groups that some rule wants to fall back to direct when they die.
sbm_failover_groups() {
	"$SBM_JQ" -r '[.rules[]? | select((.enabled != false)
			and ((.action // "") | startswith("group:"))
			and ((.on_fail // "block") == "direct"))
		| (.action | ltrimstr("group:"))] | unique | .[]' "$SBM_SETTINGS" 2>/dev/null
}

sbm_failover_check() {
	for _g in $(sbm_failover_groups); do
		_sel="sel-$_g-direct"
		sbm_api_get "/proxies/$_sel" >/dev/null 2>&1 || continue

		_alive=$(sbm_group_alive_count "$_g")
		_cur=$(sbm_api_get "/proxies/$_sel" | "$SBM_JQ" -r '.now // ""')
		if [ "$_alive" = "0" ]; then
			if [ "$_cur" != "direct" ]; then
				sbm_api_put "/proxies/$_sel" '{"name":"direct"}' >/dev/null
				sbm_warn "group $_g is down — rules with on_fail=direct now go direct"
			fi
		else
			if [ "$_cur" != "grp-$_g" ]; then
				sbm_api_put "/proxies/$_sel" "{\"name\":\"grp-$_g\"}" >/dev/null
				sbm_info "group $_g recovered ($_alive nodes) — routing restored"
			fi
		fi
	done
}

# Number of nodes in a group that answer a fresh latency probe. Asking the core
# to re-test is what makes this authoritative: cached history can be minutes old.
sbm_group_alive_count() {
	_g="$1"
	_url=$(sbm_json_get "$SBM_SETTINGS" ".groups[] | select(.id == \"$_g\") | .url" \
		"$SBM_HEALTH_URL")
	_res=$(sbm_api_get "/group/grp-$_g/delay?url=$_url&timeout=5000")
	if [ -z "$_res" ]; then echo 0; return 0; fi
	printf '%s' "$_res" | "$SBM_JQ" -r '
		if type == "object" and (has("message") | not)
		then [ to_entries[] | select(.value > 0) ] | length
		else 0 end' 2>/dev/null | head -1
}

sbm_write_status() {
	mkdir -p "$SBM_EXT_DIR" 2>/dev/null
	_running=false
	sbm_running && _running=true
	_pid=$(sbm_pid 2>/dev/null)
	_mode=$(sbm_effective_mode "$(sbm_json_get "$SBM_SETTINGS" '.general.mode' tproxy)")
	_uptime=$(sbm_core_uptime)
	_proxies=$(sbm_api_get /proxies)
	[ -n "$_proxies" ] || _proxies='{}'
	printf '%s' "$_proxies" > "$SBM_RUN_DIR/sbm_proxies.$$"

	"$SBM_JQ" -n \
		--arg running "$_running" --arg pid "${_pid:-}" --arg mode "$_mode" \
		--arg rss "$(sbm_rss_mb 2>/dev/null || echo 0)" \
		--arg uptime "$_uptime" \
		--arg ver "$SBM_VERSION" \
		--arg core "$("$SBM_BIN" version 2>/dev/null | head -1)" \
		--arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
		--slurpfile px "$SBM_RUN_DIR/sbm_proxies.$$" \
		--slurpfile st "$SBM_SETTINGS" '
		($px[0].proxies // {}) as $P |
		{
			running: ($running == "true"),
			pid: $pid, mode: $mode, rss_mb: ($rss | tonumber), version: $ver,
			uptime_s: ($uptime | tonumber),
			core: $core, updated: $ts,
			groups: [ $st[0].groups[]? | . as $g | ("grp-" + $g.id) as $t |
				{ id: $g.id, name: ($g.name // $g.id),
				  selected: ($P[$t].now // ""),
				  nodes: [ ($P[$t].all // [])[] | . as $m |
					{ tag: $m,
					  delay: (($P[$m].history // []) | last | (.delay // 0)) } ] } ],
			geo: [ $st[0].geo[]? | select(.enabled // false) | { id: .id, name: (.name // .id) } ]
		}' > "$SBM_EXT_DIR/status.json" 2>/dev/null
	rm -f "$SBM_RUN_DIR/sbm_proxies.$$"
	return 0
}

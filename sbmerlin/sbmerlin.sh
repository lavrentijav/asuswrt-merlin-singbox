#!/bin/sh
# sbmerlin — sing-box proxy addon for ASUSWRT-Merlin.
# Single entry point: firmware hooks, cron and the WebUI all call this script.

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/sbin:/opt/bin"
export LC_ALL=C
unset LD_LIBRARY_PATH

SBM_SELF="$(readlink -f "$0" 2>/dev/null || echo /jffs/addons/sbmerlin/sbmerlin.sh)"
SBM_ADDON_DIR="${SBM_ADDON_DIR:-$(dirname "$SBM_SELF")}"

. "$SBM_ADDON_DIR/lib/common.sh"
. "$SBM_ADDON_DIR/lib/outbound.sh"
. "$SBM_ADDON_DIR/lib/config.sh"
. "$SBM_ADDON_DIR/lib/generate.sh"
. "$SBM_ADDON_DIR/lib/firewall.sh"
. "$SBM_ADDON_DIR/lib/service.sh"
. "$SBM_ADDON_DIR/lib/geo.sh"
. "$SBM_ADDON_DIR/lib/watchdog.sh"
. "$SBM_ADDON_DIR/lib/webui.sh"

# Every entry point runs from cron or a firmware hook; make sure Entware is
# reachable before anything below needs jq or the data directory.
sbm_repair_opt

SBM_HOOKS="services-start firewall-start service-event post-mount unmount dnsmasq.postconf"

# --- lifecycle ---------------------------------------------------------------
sbm_cmd_start() {
	sbm_require_jq
	sbm_settings_init
	# /www/user and /www/ext are the same tmpfs directory and are wiped on every
	# boot, so the page and its data files have to be put back on each start.
	sbm_mount_ui
	sbm_export_ui
	# cron lives in /var/spool (tmpfs) and is wiped by every reboot, so the
	# watchdog, geo and subscription jobs have to be re-registered on each start.
	sbm_cron_install
	[ "$(sbm_json_get "$SBM_SETTINGS" '.general.enabled' false)" = "true" ] || {
		sbm_info "disabled in settings — not starting"
		sbm_write_status
		return 0
	}
	sbm_generate || return 1
	sbm_core_start || return 1
	sbm_firewall_up >/dev/null
	sbm_dnsmasq_apply
	sbm_write_status
	return 0
}

sbm_cmd_stop() {
	sbm_firewall_down
	sbm_core_stop
	sbm_dnsmasq_apply
	sbm_write_status
	return 0
}

# Rebuild everything from the current settings. sing-box has no config reload,
# so this restarts the core — existing connections drop. The config is validated
# first, so a bad edit never takes the running service down.
sbm_cmd_apply() {
	sbm_require_jq
	sbm_settings_init
	sbm_import_custom_settings
	# Publish what the user just saved straight away. Everything below can take a
	# minute (rule-set downloads, core restart) and the page refetches settings
	# meanwhile — without this it would read the pre-save file and show the
	# changes as lost, then save that stale state back on the next apply.
	sbm_export_ui
	sbm_apply_state running
	sbm_cron_install
	# Rules may reference catalogue rule-sets (geosite:youtube) that are not
	# registered or downloaded yet; resolve and fetch them before generating.
	sbm_geo_autoregister >/dev/null
	sbm_geo_ensure >/dev/null
	if [ "$(sbm_json_get "$SBM_SETTINGS" '.general.enabled' false)" != "true" ]; then
		sbm_cmd_stop
		sbm_export_ui
		sbm_apply_state done
		return 0
	fi
	sbm_generate || { sbm_export_ui; sbm_apply_state failed; return 1; }
	sbm_core_stop
	sbm_core_start || { sbm_export_ui; sbm_apply_state failed; return 1; }
	sbm_firewall_up >/dev/null
	sbm_dnsmasq_apply
	sbm_export_ui
	sbm_write_status
	sbm_apply_state done
	return 0
}

# Progress marker the WebUI polls, so it knows when to reload instead of
# guessing with a fixed timeout.
sbm_apply_state() {
	mkdir -p "$SBM_EXT_DIR" 2>/dev/null
	"$SBM_JQ" -n --arg s "$1" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" 		'{state: $s, updated: $ts}' > "$SBM_EXT_DIR/apply.json" 2>/dev/null
	return 0
}

# dnsmasq must be restarted for postconf changes to take effect.
sbm_dnsmasq_apply() {
	service restart_dnsmasq >/dev/null 2>&1
	sbm_dnsmasq_verify
	return 0
}

# --- install / uninstall -----------------------------------------------------
sbm_cmd_install() {
	sbm_info "installing sbmerlin $SBM_VERSION"
	[ -d /opt/bin ] || sbm_die "Entware not found — install it from amtm first"
	for _p in jq curl ca-bundle; do
		[ -x "/opt/bin/$_p" ] || [ "$_p" = "ca-bundle" ] || {
			echo "installing $_p ..."
			opkg update >/dev/null 2>&1
			opkg install "$_p" >/dev/null 2>&1
		}
	done
	sbm_require_jq
	sbm_mkdirs
	sbm_settings_init
	sbm_install_core || return 1
	sbm_hooks_install
	sbm_cron_install
	sbm_mount_ui
	sbm_export_ui
	sbm_write_status
	echo "sbmerlin installed. Open the router WebUI -> Addons -> sing-box."
	return 0
}

sbm_cmd_uninstall() {
	sbm_cmd_stop
	sbm_firewall_purge
	sbm_hooks_remove
	sbm_cron_remove
	sbm_unmount_ui
	for _s in $SBM_SECTIONS; do sbm_clear_setting "sbm_$_s"; done
	rm -rf "$SBM_EXT_DIR"
	echo "Remove settings and geo data in $SBM_DATA_DIR? [y/N]"
	read -r _ans
	case "$_ans" in
		y|Y|yes) rm -rf "$SBM_DATA_DIR"; rm -f "$SBM_BIN"; echo "removed" ;;
		*) echo "kept $SBM_DATA_DIR and $SBM_BIN" ;;
	esac
	rm -rf "$SBM_ADDON_DIR"
	echo "sbmerlin uninstalled."
	return 0
}

# Download the sing-box core matching this router's architecture.
sbm_install_core() {
	_arch=$(sbm_arch)
	[ "$_arch" = "unsupported" ] && { sbm_error "unsupported architecture: $(uname -m)"; return 1; }
	if [ -x "$SBM_BIN" ] && [ -z "$SBM_FORCE_CORE" ]; then
		sbm_info "core already installed: $("$SBM_BIN" version 2>/dev/null | head -1)"
		return 0
	fi
	_tmp="/opt/tmp/sbm-core.$$"
	mkdir -p /opt/tmp
	echo "downloading sing-box for $_arch ..."
	sbm_fetch "https://api.github.com/repos/SagerNet/sing-box/releases/latest" "$_tmp.json" || {
		sbm_error "cannot reach GitHub"; rm -f "$_tmp.json"; return 1; }
	# The musl build is self-contained; the glibc one clashes with the firmware libc.
	_q=".assets[] | select(.name | contains(\"$_arch-musl.tar.gz\"))"
	_url=$("$SBM_JQ" -r "$_q | .browser_download_url" "$_tmp.json")
	_digest=$("$SBM_JQ" -r "$_q | .digest // \"\"" "$_tmp.json")
	_ver=$("$SBM_JQ" -r '.tag_name' "$_tmp.json")
	rm -f "$_tmp.json"
	[ -n "$_url" ] || { sbm_error "no musl build for $_arch in the latest release"; return 1; }

	sbm_fetch "$_url" "$_tmp.tar.gz" || { sbm_error "download failed"; return 1; }
	_got=$(sbm_sha256 "$_tmp.tar.gz")
	case "$_digest" in
		sha256:*)
			[ "${_digest#sha256:}" = "$_got" ] || {
				sbm_error "checksum mismatch for $_ver — aborting"
				rm -f "$_tmp.tar.gz"; return 1; }
			;;
		*) sbm_warn "release published no checksum; continuing" ;;
	esac
	tar xzf "$_tmp.tar.gz" -C /opt/tmp || { rm -f "$_tmp.tar.gz"; return 1; }
	_bin=$(ls -d /opt/tmp/sing-box-*/sing-box 2>/dev/null | head -1)
	[ -n "$_bin" ] || { sbm_error "archive layout unexpected"; return 1; }
	cp "$_bin" "$SBM_BIN.new" && chmod 755 "$SBM_BIN.new" && mv -f "$SBM_BIN.new" "$SBM_BIN"
	rm -rf "$_tmp.tar.gz" /opt/tmp/sing-box-*
	sbm_info "core installed: $("$SBM_BIN" version 2>/dev/null | head -1)"
	return 0
}

# --- firmware hooks ----------------------------------------------------------
sbm_hooks_install() {
	for _h in $SBM_HOOKS; do
		_f="/jffs/scripts/$_h"
		if [ ! -f "$_f" ]; then
			printf '#!/bin/sh\n\n' > "$_f"
			chmod 755 "$_f"
		fi
		grep -q "$SBM_TAG" "$_f" && sed -i "/$(printf '%s' "$SBM_TAG" | sed 's/[#]/\\#/g')\$/d" "$_f"
		case "$_h" in
			services-start)   printf '%s start & %s\n' "$SBM_SELF" "$SBM_TAG" >> "$_f" ;;
			firewall-start)   printf '%s firewall & %s\n' "$SBM_SELF" "$SBM_TAG" >> "$_f" ;;
			service-event)    printf '%s service_event "$1" "$2" & %s\n' "$SBM_SELF" "$SBM_TAG" >> "$_f" ;;
			post-mount)       printf '%s start & %s\n' "$SBM_SELF" "$SBM_TAG" >> "$_f" ;;
			unmount)          printf '%s stop %s\n' "$SBM_SELF" "$SBM_TAG" >> "$_f" ;;
			dnsmasq.postconf) printf '%s dnsmasq "$1" %s\n' "$SBM_SELF" "$SBM_TAG" >> "$_f" ;;
		esac
		chmod 755 "$_f"
	done
	# Merlin only runs user scripts when this is enabled.
	[ "$(nvram get jffs2_scripts)" = "1" ] || {
		nvram set jffs2_scripts=1
		nvram commit
		sbm_warn "enabled jffs2_scripts — a reboot is needed for boot-time start"
	}
	sbm_info "hooks installed"
}

sbm_hooks_remove() {
	for _h in $SBM_HOOKS; do
		_f="/jffs/scripts/$_h"
		[ -f "$_f" ] || continue
		sed -i "/sbmerlin/d" "$_f"
	done
	sbm_info "hooks removed"
}

sbm_cron_install() {
	cru d sbmerlin_watchdog 2>/dev/null
	cru d sbmerlin_geo 2>/dev/null
	cru d sbmerlin_sub 2>/dev/null
	cru a sbmerlin_watchdog "*/2 * * * * $SBM_SELF watchdog"
	cru a sbmerlin_geo "17 4 * * * $SBM_SELF geoupdate"
	cru a sbmerlin_sub "37 */6 * * * $SBM_SELF sub"
	sbm_info "cron installed"
}

sbm_cron_remove() {
	for _j in sbmerlin_watchdog sbmerlin_geo sbmerlin_sub; do cru d "$_j" 2>/dev/null; done
}

# Called from /jffs/scripts/service-event when the WebUI posts a change.
sbm_service_event() {
	case "$2" in
		sbmerlinapply)   sbm_lock || return 1; sbm_cmd_apply; sbm_unlock ;;
		sbmerlinstart)   sbm_lock || return 1; sbm_cmd_start; sbm_unlock ;;
		sbmerlinstop)    sbm_lock || return 1; sbm_cmd_stop;  sbm_unlock ;;
		sbmerlingeo)     sbm_lock || return 1; sbm_cmd_geoupdate; sbm_unlock ;;
		sbmerlinsub)     sbm_lock || return 1; sbm_import_custom_settings; sbm_sub_refresh; sbm_cmd_apply; sbm_unlock ;;
		sbmerlinlinks)   sbm_lock || return 1; sbm_settings_init; sbm_add_links_from_setting; sbm_cmd_apply; sbm_unlock ;;
		sbmerlinstatus)  sbm_write_status ;;
		sbmerlintest)    sbm_cmd_test ;;
	esac
	return 0
}

sbm_cmd_geoupdate() {
	_r=$(sbm_geo_update "$1")
	sbm_export_ui
	if [ "$_r" = "changed" ] && sbm_running; then
		sbm_info "geo data changed — reloading core"
		sbm_generate && { sbm_core_stop; sbm_core_start; }
	fi
	return 0
}

# Probe every group and refresh the status file the WebUI reads.
sbm_cmd_test() {
	sbm_running || { sbm_error "core is not running"; return 1; }
	for _g in $("$SBM_JQ" -r '.groups[]?.id' "$SBM_SETTINGS"); do
		_n=$(sbm_group_alive_count "$_g")
		echo "$_g: $_n node(s) alive"
	done
	sbm_write_status
}

sbm_cmd_status() {
	printf 'sbmerlin %s\n' "$SBM_VERSION"
	if sbm_running; then
		printf 'core:     running (pid %s, RSS %s MiB)\n' "$(sbm_pid)" "$(sbm_rss_mb)"
	else
		printf 'core:     stopped\n'
	fi
	printf 'mode:     %s\n' "$(sbm_effective_mode "$(sbm_json_get "$SBM_SETTINGS" '.general.mode' tproxy)")"
	printf 'nodes:    %s\n' "$(sbm_json_get "$SBM_SETTINGS" '.nodes | length' 0)"
	printf 'groups:   %s\n' "$(sbm_json_get "$SBM_SETTINGS" '[.groups[].id] | join(", ")' '-')"
	printf 'rules:    %s\n' "$(sbm_json_get "$SBM_SETTINGS" '.rules | length' 0)"
	printf 'geo:      %s\n' "$(ls "$SBM_GEO_DIR"/*.srs 2>/dev/null | wc -l) rule-set(s)"
	sbm_running && sbm_cmd_test
	return 0
}

# --- dispatch ----------------------------------------------------------------
case "$1" in
	install)    sbm_cmd_install ;;
	uninstall)  sbm_cmd_uninstall ;;
	start)      sbm_lock || exit 1; sbm_cmd_start; sbm_unlock ;;
	stop)       sbm_lock || exit 1; sbm_cmd_stop;  sbm_unlock ;;
	restart)    sbm_lock || exit 1; sbm_cmd_stop; sbm_cmd_start; sbm_unlock ;;
	apply)      sbm_lock || exit 1; sbm_cmd_apply; sbm_unlock ;;
	gen)        sbm_require_jq; sbm_generate ;;
	firewall)   sbm_running && sbm_firewall_up >/dev/null ;;
	geoupdate)  sbm_lock || exit 1; sbm_cmd_geoupdate "$2"; sbm_unlock ;;
	sub)        sbm_lock || exit 1; sbm_sub_refresh "$2"; sbm_cmd_apply; sbm_unlock ;;
	addnode)    sbm_lock || exit 1; sbm_settings_init; sbm_add_uri "$2" "$3"; sbm_export_ui; sbm_unlock ;;
	addsub)     sbm_lock || exit 1; sbm_settings_init;
	            "$SBM_JQ" --arg u "$2" --arg g "$3" \
	              '.subs += [{id: ("s" + ((.subs | length) + 1 | tostring)), url: $u, group: $g, interval_h: 6}]' \
	              "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS";
	            sbm_sub_refresh; sbm_export_ui; sbm_unlock ;;
	watchdog)   sbm_watchdog ;;
	status)     sbm_cmd_status ;;
	test)       sbm_cmd_test ;;
	dnsmasq)    sbm_dnsmasq_conf "$2" ;;
	service_event) sbm_service_event "$2" "$3" ;;
	mountui)    sbm_mount_ui ;;
	unmountui)  sbm_unmount_ui ;;
	ui)         sbm_export_ui; sbm_write_status ;;
	version)    echo "$SBM_VERSION" ;;
	*)
		cat <<USAGE
sbmerlin $SBM_VERSION — sing-box addon for ASUSWRT-Merlin

  install | uninstall
  start | stop | restart | apply
  status | test
  gen                      regenerate config.json from settings.json
  firewall                 reapply interception rules
  geoupdate [id]           refresh geo rule-sets
  sub [id]                 refresh subscriptions
  addnode <uri> [group]    add one vless:// / vmess:// / ss:// / trojan:// link
  addsub <url> [group]     add a subscription URL
  watchdog                 one health-check pass (cron)
USAGE
		;;
esac

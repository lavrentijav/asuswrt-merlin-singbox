#!/bin/sh
# sbmerlin — geo list download, compilation into .srs, and atomic install.
#
# Only lists referenced by an enabled rule are downloaded, and a list is only
# recompiled when its source actually changed, so a daily cron run is cheap.

# Where a well-known rule-set id comes from. Lets a rule reference
# "geosite:youtube" the way an Xray config does, without the user hunting URLs.
sbm_geo_catalog_url() {
	case "$1" in
		geosite-*) printf 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/%s.srs' "$1" ;;
		geoip-*)   printf 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/%s.srs' "$1" ;;
		*)         printf '' ;;
	esac
}

# Normalise "geosite:youtube" / "geoip:ru" to the file-safe id used everywhere else.
sbm_geo_normalize_id() {
	case "$1" in
		geosite:*) printf 'geosite-%s' "${1#geosite:}" ;;
		geoip:*)   printf 'geoip-%s' "${1#geoip:}" ;;
		*)         printf '%s' "$1" ;;
	esac
}

# Any rule-set a rule references but that has no geo entry yet is added from the
# catalogue, so writing a rule is all the user has to do.
sbm_geo_autoregister() {
	_added=0
	for _raw in $("$SBM_JQ" -r '[.rules[]? | (.match.rule_set // [])[]] | unique | .[]' "$SBM_SETTINGS" 2>/dev/null); do
		_id=$(sbm_geo_normalize_id "$_raw")
		_known=$("$SBM_JQ" -r --arg i "$_id" '[.geo[]? | select(.id == $i)] | length' "$SBM_SETTINGS")
		if [ "$_raw" != "$_id" ]; then
			# Rewrite the shorthand in the rule itself so config and files agree.
			"$SBM_JQ" --arg old "$_raw" --arg new "$_id" '
				.rules = [.rules[]? | .match.rule_set = [(.match.rule_set // [])[]
					| if . == $old then $new else . end]]
			' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
		fi
		[ "$_known" = "0" ] || continue
		_url=$(sbm_geo_catalog_url "$_id")
		[ -n "$_url" ] || { sbm_warn "rule-set $_id is unknown and has no URL — rule will be ignored"; continue; }
		"$SBM_JQ" --arg i "$_id" --arg u "$_url" '
			.geo += [{ id: $i, name: $i, url: $u, format: "srs", target: "srs",
			           interval_h: 168, enabled: true, auto: true }]
		' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
		sbm_info "registered rule-set $_id from the catalogue"
		_added=1
	done
	[ "$_added" = 1 ] && echo added
	return 0
}

# sbm_geo_update [id] — refresh one list or every enabled one.
# Prints "changed" when at least one rule-set was replaced.
sbm_geo_update() {
	_only="$1"
	_changed=0
	_ids=$("$SBM_JQ" -r --arg only "$_only" '
		[.geo[]? | select((.enabled // false) and ($only == "" or .id == $only)) | .id] | .[]' \
		"$SBM_SETTINGS" 2>/dev/null)
	[ -n "$_ids" ] || { sbm_info "no geo lists enabled"; return 0; }

	mkdir -p "$SBM_GEO_DIR"
	for _id in $_ids; do
		_url=$("$SBM_JQ" -r --arg i "$_id" '.geo[] | select(.id == $i) | .url' "$SBM_SETTINGS")
		_fmt=$("$SBM_JQ" -r --arg i "$_id" '.geo[] | select(.id == $i) | .format // "plain-domain"' "$SBM_SETTINGS")
		_tgt=$("$SBM_JQ" -r --arg i "$_id" '.geo[] | select(.id == $i) | .target // "srs"' "$SBM_SETTINGS")
		_iv=$("$SBM_JQ" -r --arg i "$_id" '.geo[] | select(.id == $i) | .interval_h // 24' "$SBM_SETTINGS")

		if [ -z "$_only" ] && ! sbm_geo_is_due "$_id" "$_iv"; then
			continue
		fi

		_raw="$SBM_RUN_DIR/sbm_geo_$_id.raw"
		# A list may be assembled from several sources (Telegram, for one, lives in
		# three separate ASNs); .urls wins over .url and the parts are concatenated.
		_urls=$("$SBM_JQ" -r --arg i "$_id" '.geo[] | select(.id == $i) | (.urls // [])[]' "$SBM_SETTINGS")
		if [ -n "$_urls" ]; then
			: > "$_raw"
			_ok=0
			for _u in $_urls; do
				if sbm_fetch "$_u" "$_raw.part"; then
					cat "$_raw.part" >> "$_raw"
					_ok=1
				else
					sbm_warn "geo $_id: part failed: $_u"
				fi
				rm -f "$_raw.part"
			done
			[ "$_ok" = "1" ] || { sbm_warn "geo $_id: every source failed"; rm -f "$_raw"; continue; }
		elif ! sbm_fetch "$_url" "$_raw"; then
			sbm_warn "geo $_id: download failed"
			rm -f "$_raw"
			continue
		fi
		if [ ! -s "$_raw" ]; then
			sbm_warn "geo $_id: empty response"
			rm -f "$_raw"
			continue
		fi

		_hash=$(sbm_sha256 "$_raw")
		_stamp="$SBM_GEO_DIR/$_id.hash"
		if [ -f "$_stamp" ] && [ "$_hash" = "$(cat "$_stamp")" ] && sbm_geo_present "$_id" "$_tgt"; then
			sbm_geo_touch "$_id"
			rm -f "$_raw"
			continue
		fi

		if sbm_geo_install "$_id" "$_fmt" "$_tgt" "$_raw"; then
			printf '%s' "$_hash" > "$_stamp"
			sbm_geo_touch "$_id"
			_changed=1
		fi
		rm -f "$_raw"
	done

	[ "$_changed" = 1 ] && echo changed
	return 0
}

# Download any enabled list whose file is not on disk yet, ignoring the interval:
# a rule that references a missing rule-set would otherwise be silently dropped.
sbm_geo_ensure() {
	_missing=0
	for _id in $("$SBM_JQ" -r '[.geo[]? | select(.enabled // false) | .id] | .[]' "$SBM_SETTINGS" 2>/dev/null); do
		_tgt=$("$SBM_JQ" -r --arg i "$_id" '.geo[] | select(.id == $i) | .target // "srs"' "$SBM_SETTINGS")
		sbm_geo_present "$_id" "$_tgt" && continue
		sbm_geo_update "$_id" >/dev/null
		_missing=1
	done
	[ "$_missing" = 1 ] && echo changed
	return 0
}

sbm_geo_present() {
	case "$2" in
		ipset) [ -f "$SBM_GEO_DIR/direct-nets.lst" ] ;;
		*)     [ -f "$SBM_GEO_DIR/$1.srs" ] ;;
	esac
}

# Skip a list whose interval has not elapsed yet.
sbm_geo_is_due() {
	_f="$SBM_GEO_DIR/$1.time"
	[ -f "$_f" ] || return 0
	_last=$(cat "$_f" 2>/dev/null)
	_now=$(date +%s)
	[ $(( _now - ${_last:-0} )) -ge $(( ${2:-24} * 3600 )) ]
}

sbm_geo_touch() { date +%s > "$SBM_GEO_DIR/$1.time"; }

# sbm_geo_install <id> <format> <target> <raw_file>
sbm_geo_install() {
	_id="$1"; _fmt="$2"; _tgt="$3"; _raw="$4"
	_dst="$SBM_GEO_DIR/$_id.srs"
	_tmp="$SBM_RUN_DIR/sbm_geo_$_id.srs"

	case "$_fmt" in
		srs)
			# Already compiled: sanity-check it before trusting it.
			cp -f "$_raw" "$_tmp" || return 1
			if ! "$SBM_BIN" rule-set decompile --output /dev/null "$_tmp" >/dev/null 2>&1; then
				sbm_warn "geo $_id: not a valid .srs file"
				rm -f "$_tmp"
				return 1
			fi
			;;
		plain-domain)
			sbm_geo_json_domains "$_raw" > "$_tmp.json" || return 1
			"$SBM_BIN" rule-set compile --output "$_tmp" "$_tmp.json" >/dev/null 2>&1 || {
				sbm_warn "geo $_id: compile failed"
				rm -f "$_tmp.json"
				return 1
			}
			rm -f "$_tmp.json"
			;;
		plain-ip)
			if [ "$_tgt" = "ipset" ]; then
				sbm_geo_install_ipset "$_id" "$_raw"
				return $?
			fi
			sbm_geo_json_ips "$_raw" > "$_tmp.json" || return 1
			"$SBM_BIN" rule-set compile --output "$_tmp" "$_tmp.json" >/dev/null 2>&1 || {
				sbm_warn "geo $_id: compile failed"
				rm -f "$_tmp.json"
				return 1
			}
			rm -f "$_tmp.json"
			;;
		*)
			sbm_warn "geo $_id: unknown format $_fmt"
			return 1
			;;
	esac

	mv -f "$_tmp" "$_dst" || return 1
	sbm_info "geo $_id: updated ($(sbm_filesize "$_dst") bytes)"
	return 0
}

# Domains -> sing-box source rule-set. Comments and blank lines are dropped;
# a leading "*." or "." is trimmed so the entry works as a suffix match.
sbm_geo_json_domains() {
	sed -e 's/\r$//' -e 's/#.*$//' -e 's/^[ \t]*//' -e 's/[ \t]*$//' \
	    -e 's/^\*\.//' -e 's/^\.//' "$1" \
		| grep -E '^[A-Za-z0-9_.-]+\.[A-Za-z]{2,}$' \
		| sort -u \
		| "$SBM_JQ" -R -n '{ version: 3, rules: [ { domain_suffix: [inputs] } ] }'
}

# CIDRs (or bare addresses) -> sing-box source rule-set.
sbm_geo_json_ips() {
	sed -e 's/\r$//' -e 's/#.*$//' -e 's/[ \t]//g' "$1" \
		| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' \
		| sed -e 's|^\([0-9.]*\)$|\1/32|' \
		| sort -u \
		| "$SBM_JQ" -R -n '{ version: 3, rules: [ { ip_cidr: [inputs] } ] }'
}

# IP list destined for the kernel ipset rather than for sing-box.
sbm_geo_install_ipset() {
	_id="$1"; _raw="$2"
	_dst="$SBM_GEO_DIR/direct-nets.lst"
	sed -e 's/\r$//' -e 's/#.*$//' -e 's/[ \t]//g' "$_raw" \
		| grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' \
		| sort -u > "$_dst.tmp" || return 1
	_n=$(wc -l < "$_dst.tmp")
	[ "$_n" -gt 0 ] || { rm -f "$_dst.tmp"; sbm_warn "geo $_id: no usable networks"; return 1; }
	mv -f "$_dst.tmp" "$_dst"
	sbm_info "geo $_id: $_n networks -> kernel ipset"
	sbm_ipset_load_direct
	return 0
}

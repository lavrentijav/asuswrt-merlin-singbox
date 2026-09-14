#!/bin/sh
# sbmerlin — settings.json lifecycle: defaults, WebUI import/export, subscriptions.

SBM_CUSTOM_SETTINGS="${SBM_CUSTOM_SETTINGS:-/jffs/addons/custom_settings.txt}"
SBM_EXT_DIR="${SBM_EXT_DIR:-/www/ext/sbmerlin}"

# Sections the WebUI may write. Each arrives base64-encoded, optionally split
# across sbm_<section>_1..n because a single custom_settings value is size-capped.
SBM_SECTIONS="general groups nodes subs rules clients geo"

sbm_settings_init() {
	sbm_mkdirs
	if [ ! -f "$SBM_SETTINGS" ]; then
		cp "$SBM_TEMPLATE_DIR/default-settings.json" "$SBM_SETTINGS" || return 1
		sbm_info "created default settings"
	fi
	sbm_settings_migrate
}

# Bring an older settings file up to the current schema. Each step is idempotent.
sbm_settings_migrate() {
	_v=$(sbm_json_get "$SBM_SETTINGS" '.schema' 0)
	[ "$_v" = "$SBM_SCHEMA_VERSION" ] && return 0
	sbm_info "migrating settings schema $_v -> $SBM_SCHEMA_VERSION"
	"$SBM_JQ" --argjson v "$SBM_SCHEMA_VERSION" '
		.schema = $v
		| .general //= {} | .groups //= [] | .nodes //= [] | .subs //= []
		| .rules //= [] | .clients //= [] | .geo //= []
	' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
}

# --- WebUI -> settings -------------------------------------------------------
# Values written by the page land in custom_settings.txt; decode and merge them.
sbm_import_custom_settings() {
	[ -f "$SBM_CUSTOM_SETTINGS" ] || return 0
	_changed=0
	for _sec in $SBM_SECTIONS; do
		_b64=$(sbm_collect_setting "sbm_$_sec")
		[ -n "$_b64" ] || continue
		_json=$(printf '%s' "$_b64" | sbm_b64d)
		if ! printf '%s' "$_json" | "$SBM_JQ" -e . >/dev/null 2>&1; then
			sbm_warn "section $_sec: invalid JSON from WebUI, ignored"
			continue
		fi
		printf '%s' "$_json" > "$SBM_RUN_DIR/sbm_sec.$$"
		if "$SBM_JQ" --arg k "$_sec" --slurpfile v "$SBM_RUN_DIR/sbm_sec.$$" \
			'.[$k] = $v[0]' "$SBM_SETTINGS" > "$SBM_SETTINGS.new"; then
			mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
			_changed=1
		fi
		rm -f "$SBM_RUN_DIR/sbm_sec.$$"
		sbm_clear_setting "sbm_$_sec"
	done
	[ "$_changed" = 1 ] && sbm_info "settings updated from WebUI"
	return 0
}

# Join sbm_<name> or its numbered chunks into one string.
# The firmware stores settings as "key value" (space separated), see helper.sh.
# The page sends a section over several requests (the firmware refuses a single
# amng_custom above 8 KB) and adds sbm_<name>_n with the chunk count; a section
# whose chunks have not all landed yet is left alone for the next apply.
sbm_collect_setting() {
	_key="$1"
	_single=$(grep -E "^${_key} " "$SBM_CUSTOM_SETTINGS" 2>/dev/null | head -1 | cut -f2- -d ' ')
	if [ -n "$_single" ]; then printf '%s' "$_single"; return 0; fi
	_want=$(grep -E "^${_key}_n " "$SBM_CUSTOM_SETTINGS" 2>/dev/null | head -1 | cut -f2- -d ' ')
	_n=1
	_acc=""
	while :; do
		_part=$(grep -E "^${_key}_${_n} " "$SBM_CUSTOM_SETTINGS" 2>/dev/null | head -1 | cut -f2- -d ' ')
		[ -n "$_part" ] || break
		_acc="$_acc$_part"
		_n=$((_n + 1))
	done
	case "$_want" in
		''|*[!0-9]*) : ;;
		*)
			if [ $((_n - 1)) -ne "$_want" ]; then
				sbm_warn "$_key: $((_n - 1)) of $_want chunks arrived, keeping it for the next apply"
				return 1
			fi
			;;
	esac
	printf '%s' "$_acc"
}

sbm_clear_setting() {
	_key="$1"
	[ -f "$SBM_CUSTOM_SETTINGS" ] || return 0
	grep -vE "^${_key} " "$SBM_CUSTOM_SETTINGS" 2>/dev/null | grep -vE "^${_key}_([0-9]+|n) " \
		> "$SBM_CUSTOM_SETTINGS.new" && mv -f "$SBM_CUSTOM_SETTINGS.new" "$SBM_CUSTOM_SETTINGS"
}

# --- settings -> WebUI -------------------------------------------------------
# The page reads settings over plain HTTP from /www/ext, which keeps large node
# lists out of custom_settings.txt entirely.
sbm_export_ui() {
	mkdir -p "$SBM_EXT_DIR" 2>/dev/null
	[ -f "$SBM_SETTINGS" ] || return 0
	"$SBM_JQ" -c . "$SBM_SETTINGS" > "$SBM_EXT_DIR/settings.json" 2>/dev/null
	# The Logs tab reads this plain file; keep it small.
	{ tail -120 "$SBM_LOG" 2>/dev/null; echo "--- sing-box ---"; tail -80 "$SBM_CORE_LOG" 2>/dev/null; } 		| sed 's/\[[0-9;]*m//g' > "$SBM_EXT_DIR/sbmerlin.log" 2>/dev/null
	return 0
}

# Add several share links at once (WebUI "Добавить ссылки").
sbm_add_links_from_setting() {
	_b64=$(sbm_collect_setting sbm_links)
	[ -n "$_b64" ] || return 0
	_txt=$(printf '%s' "$_b64" | sbm_b64d)
	printf '%s
' "$_txt" | while IFS= read -r _l; do
		_l=$(printf '%s' "$_l" | tr -d ' 	')
		[ -n "$_l" ] || continue
		sbm_add_uri "$_l" ""
	done
	sbm_clear_setting sbm_links
	return 0
}

# --- nodes / subscriptions ---------------------------------------------------
# sbm_add_uri <uri> [group] — append one share link as a node.
sbm_add_uri() {
	_uri="$1"; _grp="$2"
	_label=$(sbm_uri_label "$_uri")
	[ -n "$_grp" ] || _grp=$(sbm_guess_country "$_label")
	_idx=$(( $(sbm_json_get "$SBM_SETTINGS" '.nodes | length' 0) + 1 ))
	_tag=$(sbm_tagify "$_label" "$_idx" "$_grp")
	_ob=$(sbm_uri_to_outbound "$_uri" "$_tag") || { sbm_error "unsupported link: ${_uri%%:*}"; return 1; }
	printf '%s' "$_ob" > "$SBM_RUN_DIR/sbm_ob.$$"
	"$SBM_JQ" --arg tag "$_tag" --arg label "$_label" --arg grp "$_grp" \
		--slurpfile ob "$SBM_RUN_DIR/sbm_ob.$$" '
		.nodes += [{ id: $tag, tag: $tag, label: $label, group: $grp,
		             source: "uri", enabled: true, json: $ob[0] }]
	' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
	rm -f "$SBM_RUN_DIR/sbm_ob.$$"
	sbm_ensure_group "$_grp"
	sbm_info "added node $_tag ($_grp)"
}

# Create a group on demand so imported nodes are always routable.
sbm_ensure_group() {
	_g="$1"
	[ -n "$_g" ] || return 0
	_has=$("$SBM_JQ" -r --arg g "$_g" '[.groups[]? | select(.id == $g)] | length' "$SBM_SETTINGS")
	[ "$_has" = "0" ] || return 0
	"$SBM_JQ" --arg g "$_g" '
		.groups += [{ id: $g, name: $g, type: "urltest",
		              url: "https://www.gstatic.com/generate_204",
		              interval_s: 300, tolerance_ms: 150 }]
	' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
}

# sbm_sub_refresh [sub_id] — re-fetch subscriptions and rebuild their nodes.
# Nodes added by hand (source != "sub") are left untouched.
sbm_sub_refresh() {
	_only="$1"
	_ids=$("$SBM_JQ" -r --arg only "$_only" '
		[.subs[]? | select($only == "" or .id == $only) | .id] | .[]' "$SBM_SETTINGS")
	[ -n "$_ids" ] || { sbm_info "no subscriptions configured"; return 0; }

	for _sid in $_ids; do
		_url=$("$SBM_JQ" -r --arg id "$_sid" '.subs[] | select(.id == $id) | .url' "$SBM_SETTINGS")
		_grp=$("$SBM_JQ" -r --arg id "$_sid" '.subs[] | select(.id == $id) | .group // ""' "$SBM_SETTINGS")
		_raw="$SBM_RUN_DIR/sbm_sub_raw.$$"
		if ! sbm_fetch "$_url" "$_raw"; then
			sbm_warn "subscription $_sid: download failed"
			rm -f "$_raw"
			continue
		fi
		_list=$(sbm_parse_list "$_raw")
		rm -f "$_raw"
		_count=$(printf '%s' "$_list" | "$SBM_JQ" 'length')
		if [ "$_count" = "0" ]; then
			sbm_warn "subscription $_sid: no usable nodes"
			continue
		fi

		# Build the replacement node set for this subscription.
		: > "$SBM_RUN_DIR/sbm_nodes.$$"
		_i=0
		printf '%s' "$_list" | "$SBM_JQ" -r '.[] | @base64' | while IFS= read -r _enc; do
			_item=$(printf '%s' "$_enc" | base64 -d)
			_uri=$(printf '%s' "$_item" | "$SBM_JQ" -r '.uri')
			_label=$(printf '%s' "$_item" | "$SBM_JQ" -r '.label')
			_country=$(printf '%s' "$_item" | "$SBM_JQ" -r '.country')
			_i=$((_i + 1))
			_tag=$(sbm_tagify "$_label" "$_sid$_i" "$_country")
			_ob=$(sbm_uri_to_outbound "$_uri" "$_tag") || continue
			[ -n "$_grp" ] && _country="$_grp"
			printf '%s' "$_ob" > "$SBM_RUN_DIR/sbm_ob.$$"
			"$SBM_JQ" -c -n --arg tag "$_tag" --arg label "$_label" --arg grp "$_country" \
				--arg sid "$_sid" --slurpfile ob "$SBM_RUN_DIR/sbm_ob.$$" '
				{ id: $tag, tag: $tag, label: $label, group: $grp,
				  source: "sub", sub_id: $sid, enabled: true, json: $ob[0] }' \
				>> "$SBM_RUN_DIR/sbm_nodes.$$"
			rm -f "$SBM_RUN_DIR/sbm_ob.$$"
		done

		"$SBM_JQ" -s -c '.' "$SBM_RUN_DIR/sbm_nodes.$$" > "$SBM_RUN_DIR/sbm_nodes_arr.$$"
		_new=$("$SBM_JQ" 'length' "$SBM_RUN_DIR/sbm_nodes_arr.$$")
		if [ "$_new" = "0" ]; then
			sbm_warn "subscription $_sid: every node failed to parse, keeping previous set"
		else
			"$SBM_JQ" --arg sid "$_sid" --slurpfile nn "$SBM_RUN_DIR/sbm_nodes_arr.$$" '
				.nodes = ([.nodes[]? | select(.sub_id != $sid)] + $nn[0])
				| .subs = [.subs[]? | if .id == $sid then . + { last_update: (now | todate), count: ($nn[0] | length) } else . end]
			' "$SBM_SETTINGS" > "$SBM_SETTINGS.new" && mv -f "$SBM_SETTINGS.new" "$SBM_SETTINGS"
			sbm_info "subscription $_sid: $_new nodes"
			# Make sure every country discovered in the subscription has a group.
			for _g in $("$SBM_JQ" -r '.[].group' "$SBM_RUN_DIR/sbm_nodes_arr.$$" | sort -u); do
				sbm_ensure_group "$_g"
			done
		fi
		rm -f "$SBM_RUN_DIR/sbm_nodes.$$" "$SBM_RUN_DIR/sbm_nodes_arr.$$"
	done
	return 0
}

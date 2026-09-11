#!/bin/sh
# sbmerlin — build and validate the sing-box config from settings.json.

# sbm_generate [out_file] — writes the config, validates it, and only then
# publishes it. A broken settings file never replaces a working config.
sbm_generate() {
	_out="${1:-$SBM_CONFIG}"
	_tmp="$SBM_RUN_DIR/sbm_config.$$"

	[ -f "$SBM_SETTINGS" ] || { sbm_error "settings not found: $SBM_SETTINGS"; return 1; }
	"$SBM_JQ" -e . "$SBM_SETTINGS" >/dev/null 2>&1 || { sbm_error "settings.json is not valid JSON"; return 1; }

	"$SBM_JQ" -f "$SBM_TEMPLATE_DIR/config.jq" \
		--arg lan_ip "$(sbm_lan_ip)" \
		--arg local_dns "$(sbm_wan_dns)" \
		--arg geo_dir "$SBM_GEO_DIR" \
		--arg cache "$SBM_CACHE" \
		--arg log "$SBM_CORE_LOG" \
		--arg tproxy_port "$SBM_TPROXY_PORT" \
		--arg redir_port "$SBM_REDIR_PORT" \
		--arg mode "$(sbm_effective_mode "$(sbm_json_get "$SBM_SETTINGS" '.general.mode' tproxy)")" \
		--arg dns_port "$SBM_DNS_PORT" \
		--arg api_port "$SBM_API_PORT" \
		"$SBM_SETTINGS" > "$_tmp" 2>"$_tmp.err"
	if [ $? -ne 0 ] || [ ! -s "$_tmp" ]; then
		sbm_error "config generation failed: $(head -3 "$_tmp.err" 2>/dev/null)"
		rm -f "$_tmp" "$_tmp.err"
		return 1
	fi

	# Rule-sets referenced but not yet downloaded would make sing-box refuse to
	# start, so drop those references and warn instead.
	sbm_prune_missing_rulesets "$_tmp"

	if ! "$SBM_BIN" check -c "$_tmp" >"$_tmp.err" 2>&1; then
		sbm_error "sing-box rejected the generated config:"
		sed 's/\x1b\[[0-9;]*m//g' "$_tmp.err" | head -5 >&2
		cp -f "$_tmp" "$SBM_DATA_DIR/config.rejected.json" 2>/dev/null
		rm -f "$_tmp" "$_tmp.err"
		return 1
	fi

	mv -f "$_tmp" "$_out"
	rm -f "$_tmp.err"
	sbm_info "config generated ($(sbm_filesize "$_out") bytes)"
	return 0
}

# Remove route.rule_set entries whose .srs file is missing, and every rule that
# referenced them, so a not-yet-downloaded geo list cannot break the service.
sbm_prune_missing_rulesets() {
	_cfg="$1"
	_missing=""
	for _tag in $("$SBM_JQ" -r '.route.rule_set[]?.tag' "$_cfg" 2>/dev/null); do
		[ -f "$SBM_GEO_DIR/$_tag.srs" ] || _missing="$_missing $_tag"
	done
	[ -n "$_missing" ] || return 0
	sbm_warn "missing rule-sets, ignored for now:$_missing"
	_list=$(printf '%s' "$_missing" | tr ' ' '\n' | "$SBM_JQ" -R -s 'split("\n") | map(select(length > 0))')
	"$SBM_JQ" --argjson miss "$_list" '
		.route.rule_set = [.route.rule_set[]? | select(.tag as $t | $miss | index($t) | not)]
		| .route.rules = [.route.rules[]?
			| select((.rule_set // []) | map(. as $t | $miss | index($t)) | all(. == null))]
		| .dns.rules = [.dns.rules[]?
			| select((.rule_set // []) | map(. as $t | $miss | index($t)) | all(. == null))]
	' "$_cfg" > "$_cfg.pruned" && mv -f "$_cfg.pruned" "$_cfg"
}

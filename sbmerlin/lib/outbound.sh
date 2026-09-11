#!/bin/sh
# sbmerlin — parse share-link URIs and subscriptions into sing-box outbound objects.
# Every function prints one JSON object (or a JSON array) on stdout.

sbm_urldecode() {
	# %XX -> byte, + -> space. printf %b handles the \x escapes.
	printf '%b' "$(printf '%s' "$1" | sed -e 's/+/ /g' -e 's/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')"
}

sbm_b64d() {
	# URL-safe, padding-tolerant base64 decode. Reads $1, or stdin with no argument.
	if [ "$#" -gt 0 ]; then
		_s=$(printf '%s' "$1" | tr -d '\r\n' | tr '_-' '/+')
	else
		_s=$(tr -d '\r\n' | tr '_-' '/+')
	fi
	case $(( ${#_s} % 4 )) in
		2) _s="$_s==" ;;
		3) _s="$_s=" ;;
	esac
	printf '%s' "$_s" | base64 -d 2>/dev/null
}

# --- URI field extraction ----------------------------------------------------
_sbm_uri_frag()  { case "$1" in *\#*) printf '%s' "${1#*#}" ;; *) printf '' ;; esac; }
_sbm_uri_nofrag(){ printf '%s' "${1%%#*}"; }
_sbm_uri_query() { _n=$(_sbm_uri_nofrag "$1"); case "$_n" in *\?*) printf '%s' "${_n#*\?}" ;; *) printf '' ;; esac; }
_sbm_uri_body()  { _n=$(_sbm_uri_nofrag "$1"); printf '%s' "${_n%%\?*}"; }

# _sbm_q <query> <key> — value of one query parameter, url-decoded.
_sbm_q() {
	_v=$(printf '%s&' "$1" | sed -n "s/.*[?&]\{0,1\}${2}=\([^&]*\)&.*/\1/p" | head -1)
	[ -n "$_v" ] && sbm_urldecode "$_v"
}

# _sbm_split_auth <userinfo@host:port> — sets _SBM_USER _SBM_HOST _SBM_PORT
_sbm_split_auth() {
	_a="$1"
	case "$_a" in
		*@*) _SBM_USER="${_a%@*}"; _rest="${_a##*@}" ;;
		*)   _SBM_USER=""; _rest="$_a" ;;
	esac
	case "$_rest" in
		\[*\]:*) _SBM_HOST=$(printf '%s' "$_rest" | sed 's/^\[\(.*\)\]:.*/\1/'); _SBM_PORT="${_rest##*:}" ;;
		*:*)     _SBM_HOST="${_rest%%:*}"; _SBM_PORT="${_rest##*:}" ;;
		*)       _SBM_HOST="$_rest"; _SBM_PORT="443" ;;
	esac
}

# --- shared TLS / transport builders ----------------------------------------
# _sbm_tls_json <query> <fallback_sni> — "null" when TLS is disabled.
_sbm_tls_json() {
	_qs="$1"; _fallback="$2"
	_sec=$(_sbm_q "$_qs" security)
	[ -z "$_sec" ] && _sec=$(_sbm_q "$_qs" tls)
	case "$_sec" in
		tls|reality|xtls|1|true) : ;;
		*) echo null; return 0 ;;
	esac
	_sni=$(_sbm_q "$_qs" sni); [ -z "$_sni" ] && _sni=$(_sbm_q "$_qs" peer)
	[ -z "$_sni" ] && _sni=$(_sbm_q "$_qs" host)
	[ -z "$_sni" ] && _sni="$_fallback"
	_fp=$(_sbm_q "$_qs" fp)
	_alpn=$(_sbm_q "$_qs" alpn)
	_pbk=$(_sbm_q "$_qs" pbk)
	_sid=$(_sbm_q "$_qs" sid)
	_ins=$(_sbm_q "$_qs" allowInsecure); [ -z "$_ins" ] && _ins=$(_sbm_q "$_qs" insecure)

	"$SBM_JQ" -n \
		--arg sni "$_sni" --arg fp "$_fp" --arg alpn "$_alpn" \
		--arg pbk "$_pbk" --arg sid "$_sid" --arg ins "$_ins" '
		{ enabled: true, server_name: $sni,
		  insecure: ($ins == "1" or $ins == "true") }
		+ (if $alpn != "" then { alpn: ($alpn | split(",") | map(select(. != ""))) } else {} end)
		+ (if $fp  != "" then { utls: { enabled: true, fingerprint: $fp } } else {} end)
		+ (if $pbk != "" then { reality: { enabled: true, public_key: $pbk, short_id: $sid } } else {} end)'
}

# _sbm_transport_json <query> — "null" for plain TCP.
_sbm_transport_json() {
	_qs="$1"
	_type=$(_sbm_q "$_qs" type); [ -z "$_type" ] && _type=$(_sbm_q "$_qs" net)
	_path=$(_sbm_q "$_qs" path)
	_host=$(_sbm_q "$_qs" host)
	_sn=$(_sbm_q "$_qs" serviceName); [ -z "$_sn" ] && _sn=$(_sbm_q "$_qs" servicename)
	case "$_type" in
		ws)
			"$SBM_JQ" -n --arg p "${_path:-/}" --arg h "$_host" '
				{ type: "ws", path: $p }
				+ (if $h != "" then { headers: { Host: $h } } else {} end)' ;;
		grpc)
			"$SBM_JQ" -n --arg s "$_sn" '{ type: "grpc", service_name: $s }' ;;
		http|h2)
			"$SBM_JQ" -n --arg p "${_path:-/}" --arg h "$_host" '
				{ type: "http", path: $p }
				+ (if $h != "" then { host: ($h | split(",")) } else {} end)' ;;
		httpupgrade)
			"$SBM_JQ" -n --arg p "${_path:-/}" --arg h "$_host" '
				{ type: "httpupgrade", path: $p }
				+ (if $h != "" then { host: $h } else {} end)' ;;
		*) echo null ;;
	esac
}

# --- per-scheme parsers ------------------------------------------------------
_sbm_parse_vless() {
	_uri="$1"; _tag="$2"
	_body=$(_sbm_uri_body "${_uri#vless://}")
	_qs=$(_sbm_uri_query "$_uri")
	_sbm_split_auth "$_body"
	[ -n "$_SBM_HOST" ] && [ -n "$_SBM_USER" ] || return 1
	_flow=$(_sbm_q "$_qs" flow)
	_tls=$(_sbm_tls_json "$_qs" "$_SBM_HOST")
	_tr=$(_sbm_transport_json "$_qs")
	"$SBM_JQ" -n --arg tag "$_tag" --arg srv "$_SBM_HOST" --argjson port "${_SBM_PORT:-443}" \
		--arg uuid "$_SBM_USER" --arg flow "$_flow" \
		--argjson tls "$_tls" --argjson tr "$_tr" '
		{ type: "vless", tag: $tag, server: $srv, server_port: $port, uuid: $uuid,
		  packet_encoding: "xudp" }
		+ (if $flow != "" then { flow: $flow } else {} end)
		+ (if $tls  != null then { tls: $tls } else {} end)
		+ (if $tr   != null then { transport: $tr } else {} end)'
}

_sbm_parse_trojan() {
	_uri="$1"; _tag="$2"
	_body=$(_sbm_uri_body "${_uri#trojan://}")
	_qs=$(_sbm_uri_query "$_uri")
	_sbm_split_auth "$_body"
	[ -n "$_SBM_HOST" ] && [ -n "$_SBM_USER" ] || return 1
	# trojan is TLS by default even when `security` is absent.
	_tls=$(_sbm_tls_json "$_qs" "$_SBM_HOST")
	if [ "$_tls" = "null" ]; then
		_tls=$("$SBM_JQ" -n --arg sni "$(_sbm_q "$_qs" sni)" --arg h "$_SBM_HOST" \
			'{ enabled: true, server_name: (if $sni != "" then $sni else $h end), insecure: false }')
	fi
	_tr=$(_sbm_transport_json "$_qs")
	"$SBM_JQ" -n --arg tag "$_tag" --arg srv "$_SBM_HOST" --argjson port "${_SBM_PORT:-443}" \
		--arg pw "$(sbm_urldecode "$_SBM_USER")" --argjson tls "$_tls" --argjson tr "$_tr" '
		{ type: "trojan", tag: $tag, server: $srv, server_port: $port, password: $pw, tls: $tls }
		+ (if $tr != null then { transport: $tr } else {} end)'
}

_sbm_parse_ss() {
	_uri="$1"; _tag="$2"
	_body=$(_sbm_uri_body "${_uri#ss://}")
	case "$_body" in
		*@*)
			_userpart="${_body%@*}"
			_dec=$(sbm_b64d "$_userpart")
			case "$_dec" in *:*) _userpart="$_dec" ;; *) _userpart=$(sbm_urldecode "$_userpart") ;; esac
			_sbm_split_auth "x@${_body##*@}"
			_method="${_userpart%%:*}"; _pass="${_userpart#*:}"
			;;
		*)
			_dec=$(sbm_b64d "$_body")
			[ -n "$_dec" ] || return 1
			_sbm_split_auth "$_dec"
			_method="${_SBM_USER%%:*}"; _pass="${_SBM_USER#*:}"
			;;
	esac
	[ -n "$_SBM_HOST" ] && [ -n "$_method" ] || return 1
	"$SBM_JQ" -n --arg tag "$_tag" --arg srv "$_SBM_HOST" --argjson port "${_SBM_PORT:-443}" \
		--arg m "$_method" --arg pw "$_pass" \
		'{ type: "shadowsocks", tag: $tag, server: $srv, server_port: $port, method: $m, password: $pw }'
}

_sbm_parse_vmess() {
	_uri="$1"; _tag="$2"
	_json=$(sbm_b64d "${_uri#vmess://}")
	printf '%s' "$_json" | "$SBM_JQ" -e . >/dev/null 2>&1 || return 1
	printf '%s' "$_json" | "$SBM_JQ" --arg tag "$_tag" '
		(.port | tonumber) as $port |
		{ type: "vmess", tag: $tag, server: .add, server_port: $port, uuid: .id,
		  security: (if (.scy // "") != "" then .scy else "auto" end),
		  alter_id: ((.aid // 0) | tonumber), packet_encoding: "xudp" }
		+ (if ((.tls // "") | test("tls|reality"))
		   then { tls: ({ enabled: true,
		                  server_name: (if (.sni // "") != "" then .sni
		                                elif (.host // "") != "" then .host else .add end),
		                  insecure: false }
		                + (if (.alpn // "") != "" then { alpn: (.alpn | split(",")) } else {} end)
		                + (if (.fp // "") != "" then { utls: { enabled: true, fingerprint: .fp } } else {} end)) }
		   else {} end)
		+ (if (.net // "tcp") == "ws"
		   then { transport: ({ type: "ws", path: (if (.path // "") != "" then .path else "/" end) }
		                      + (if (.host // "") != "" then { headers: { Host: .host } } else {} end)) }
		   elif (.net // "") == "grpc"
		   then { transport: { type: "grpc", service_name: (.path // "") } }
		   else {} end)'
}

# --- public API --------------------------------------------------------------
# sbm_uri_label <uri> — human name from the URI fragment (falls back to host).
sbm_uri_label() {
	_frag=$(_sbm_uri_frag "$1")
	if [ -n "$_frag" ]; then
		sbm_urldecode "$_frag"
	else
		_b=$(_sbm_uri_body "${1#*://}")
		_sbm_split_auth "$_b"
		printf '%s' "$_SBM_HOST"
	fi
}

# sbm_uri_to_outbound <uri> <tag> — one sing-box outbound object on stdout.
sbm_uri_to_outbound() {
	_u=$(printf '%s' "$1" | tr -d '\r\n \t'); _t="$2"
	case "$_u" in
		vless://*)  _sbm_parse_vless  "$_u" "$_t" ;;
		trojan://*) _sbm_parse_trojan "$_u" "$_t" ;;
		ss://*)     _sbm_parse_ss     "$_u" "$_t" ;;
		vmess://*)  _sbm_parse_vmess  "$_u" "$_t" ;;
		*) return 1 ;;
	esac
}

# Guess a country/group label from a node name: flag emoji, Russian or English
# country names, or an `xx1` style suffix. Used to pre-sort subscription nodes.
sbm_guess_country() {
	_n="$1"
	case "$_n" in
		*[Гг]ермани*|*Germany*|*[Ff]rankfurt*|*de1*|*de2*|*de3*) echo DE; return ;;
		*[Фф]инлянд*|*Finland*|*[Hh]elsinki*|*fi1*|*fi2*|*fi3*) echo FI; return ;;
		*[Нн]идерланд*|*Netherlands*|*[Aa]msterdam*|*nl1*|*nl2*|*nl3*) echo NL; return ;;
		*[Пп]ольш*|*Poland*|*[Ww]arsaw*|*pl1*|*pl2*|*pl3*) echo PL; return ;;
		*США*|*USA*|*[Uu]nited?States*|*us1*|*us2*) echo US; return ;;
		*[Аа]нгли*|*[Бб]ритан*|*[Ll]ondon*|*uk1*|*uk2*) echo UK; return ;;
		*[Шш]веци*|*Sweden*|*[Ss]tockholm*|*se1*|*se2*) echo SE; return ;;
		*[Тт]урц*|*Turkey*|*[Ii]stanbul*|*tr1*|*tr2*) echo TR; return ;;
		*[Фф]ранц*|*France*|*[Pp]aris*|*fr1*|*fr2*) echo FR; return ;;
		*[Яя]пони*|*Japan*|*[Tt]okyo*|*jp1*|*jp2*) echo JP; return ;;
		*) echo OTHER ;;
	esac
}

# sbm_tagify <label> <index> [fallback] — a stable, config-safe outbound tag.
# Labels are often pure emoji/Cyrillic ("🇩🇪 Германия Франкфурт"), which slugify to
# nothing useful, so fall back to the detected country code instead of "node".
sbm_tagify() {
	_slug=$(printf '%s' "$1" \
		| sed -e 's/[^A-Za-z0-9._-][^A-Za-z0-9._-]*/-/g' -e 's/^[-.]*//' -e 's/[-.]*$//' \
		| cut -c1-24)
	case "$_slug" in
		?|'') _slug="" ;;
	esac
	[ -z "$_slug" ] && _slug="${3:-node}"
	printf '%s-%s' "$_slug" "$2"
}

# sbm_parse_list <file> — JSON array of {uri,label,country} for every proxy line.
# Accepts plain or base64-wrapped subscription bodies; non-proxy lines are dropped.
sbm_parse_list() {
	_src="$1"
	_tmp="$SBM_RUN_DIR/sbm_sub.$$"
	if grep -qE '^[a-z][a-z0-9]*://' "$_src" 2>/dev/null; then
		cp "$_src" "$_tmp"
	else
		tr -d '\r\n' < "$_src" | sbm_b64d > "$_tmp" 2>/dev/null
	fi
	: > "$_tmp.json"
	while IFS= read -r _line; do
		_line=$(printf '%s' "$_line" | tr -d '\r')
		case "$_line" in
			vless://*|vmess://*|ss://*|trojan://*) : ;;
			*) continue ;;
		esac
		_label=$(sbm_uri_label "$_line")
		_country=$(sbm_guess_country "$_label")
		"$SBM_JQ" -n -c --arg uri "$_line" --arg label "$_label" --arg c "$_country" \
			'{uri: $uri, label: $label, country: $c}' >> "$_tmp.json"
	done < "$_tmp"
	"$SBM_JQ" -s -c '.' "$_tmp.json"
	rm -f "$_tmp" "$_tmp.json"
}

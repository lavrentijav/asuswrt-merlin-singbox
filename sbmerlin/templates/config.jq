# sbmerlin — settings.json -> sing-box config.json
#
# Invoked as:  jq -f config.jq --arg lan_ip .. --arg geo_dir .. --arg cache .. \
#                 --arg log .. --arg tproxy_port .. --arg dns_port .. --arg api_port .. settings.json
#
# NOTE: Entware's jq is built without oniguruma, so test/match/gsub/capture are
# unavailable here. Only literal string functions may be used.

def enabled_nodes: [.nodes[]? | select((.enabled // true) and ((.tag // "") != ""))];

# Groups that actually have at least one node — an empty urltest is rejected by sing-box.
def live_groups($nodes): [.groups[]? | . as $g
	| select([$nodes[] | select(.group == $g.id)] | length > 0)];

def active_rules: [.rules[]? | select(.enabled // true)];

# Outbound tag a rule routes to. "direct"/"block" are handled by the caller.
def rule_target($r):
	if ($r.action // "") == "direct" then "direct"
	elif ($r.action // "") | startswith("group:") then
		(($r.action | ltrimstr("group:")) as $g
		 | if ($r.on_fail // "block") == "direct" then "sel-" + $g + "-direct" else "grp-" + $g end)
	elif ($r.action // "") | startswith("node:") then ($r.action | ltrimstr("node:"))
	else "direct" end;

. as $s
| enabled_nodes as $nodes
| live_groups($nodes) as $groups
| ($groups | map(.id)) as $gids
| active_rules as $rules
| [$s.clients[]? | select((.mode // "rules") | startswith("force:"))
   | (.mode | ltrimstr("force:"))] as $forced_raw
| ($forced_raw | map(select(. as $x | $gids | index($x))) | unique) as $forced
| [$rules[] | select(((.action // "") | startswith("group:")) and ((.on_fail // "block") == "direct"))
   | (.action | ltrimstr("group:"))] as $failover_raw
| ($failover_raw | map(select(. as $x | $gids | index($x))) | unique) as $failover_groups
# Rule-sets referenced by any rule or DNS rule, so we only load what is used.
| ([$rules[] | (.match.rule_set // [])[]]
   + [$s.geo[]? | select((.direct // false) and (.enabled // false)) | .id] | unique) as $used_sets
| [$s.geo[]? | select((.enabled // false) and ((.target // "srs") == "srs") and (.id as $i | $used_sets | index($i)))] as $geo_sets

| {
  log: {
    level: ($s.general.log_level // "warn"),
    output: $log,
    timestamp: true
  },

  dns: {
    servers: (
      [ { type: "udp", tag: "dns-local",
          server: (if ($s.general.dns.local // "auto") == "auto" then $local_dns else $s.general.dns.local end) } ]
      + [ { type: "https", tag: "dns-remote",
            server: (($s.general.dns.remote // "https://1.1.1.1/dns-query")
                     | ltrimstr("https://") | split("/") | .[0]),
            path: (($s.general.dns.remote // "https://1.1.1.1/dns-query")
                     | ltrimstr("https://") | split("/")
                     | (if length > 1 then "/" + (.[1:] | join("/")) else "/dns-query" end)),
            detour: (if (($s.general.dns.remote_outbound // "auto") != "auto")
                        and (($s.general.dns.remote_outbound // "") | startswith("group:"))
                        and (($s.general.dns.remote_outbound | ltrimstr("group:")) as $g | $gids | index($g))
                     then "grp-" + ($s.general.dns.remote_outbound | ltrimstr("group:"))
                     elif ($gids | length) > 0 then "grp-" + $gids[0]
                     else "direct" end) } ]
    ),
    rules: (
      # Domains that must resolve through the local resolver: anything marked
      # "direct" in the geo list, plus the proxy servers themselves.
      [ $geo_sets[] | select(.direct // false)
        | { rule_set: [.id], server: "dns-local" } ]
      + ( [$nodes[] | .json.server // empty] | unique
          | if length > 0 then [ { domain: ., server: "dns-local" } ] else [] end )
      + [ $rules[] | select((.action // "") == "direct")
          | { } + (if (.match.domain_suffix // []) | length > 0
                   then { domain_suffix: .match.domain_suffix } else {} end)
                + (if (.match.domain // []) | length > 0
                   then { domain: .match.domain } else {} end)
                + { server: "dns-local" }
          | select((.domain_suffix // .domain) != null) ]
    ),
    final: "dns-remote",
    strategy: ($s.general.dns.strategy // "prefer_ipv4")
  },

  inbounds: (
    # $mode is the *effective* mode: "redirect" when the kernel has no xt_TPROXY.
    (if $mode == "redirect" then "redirect" else "tproxy" end) as $itype
    | (if $mode == "redirect" then ($redir_port | tonumber) else ($tproxy_port | tonumber) end) as $base
    | [ { type: $itype, tag: "tproxy-in", listen: "::", listen_port: $base } ]
    + [ $forced[] | . as $g
        | { type: $itype, tag: ("tproxy-" + $g), listen: "::",
            listen_port: ($base + 1 + ($forced | index($g))) } ]
    + [ { type: "direct", tag: "dns-in", listen: "127.0.0.1",
          listen_port: ($dns_port | tonumber) } ]
    # Optional loopback SOCKS/HTTP inbound: lets you verify from the router which
    # outbound a domain actually takes, without touching client traffic.
    + (if (($s.general.debug_port // 0) | tonumber) > 0
       then [ { type: "mixed", tag: "debug-in", listen: "127.0.0.1",
                listen_port: ($s.general.debug_port | tonumber) } ]
       else [] end)
  ),

  outbounds: (
    [ { type: "direct", tag: "direct" } ]
    + [ $nodes[] | .json + { tag: .tag } ]
    + [ $groups[] | . as $g
        | { type: "urltest", tag: ("grp-" + $g.id),
            outbounds: [$nodes[] | select(.group == $g.id) | .tag],
            url: ($g.url // "http://cp.cloudflare.com/generate_204"),
            interval: (((($g.interval_s // 300) | tostring)) + "s"),
            tolerance: ($g.tolerance_ms // 150),
            idle_timeout: "30m" } ]
    + [ $failover_groups[] | . as $g
        | { type: "selector", tag: ("sel-" + $g + "-direct"),
            outbounds: [("grp-" + $g), "direct"],
            default: ("grp-" + $g),
            interrupt_exist_connections: false } ]
  ),

  route: {
    rules: (
      [ { action: "sniff", timeout: "300ms" },
        { inbound: "dns-in", action: "hijack-dns" },
        { protocol: "dns", action: "hijack-dns" },
        { ip_is_private: true, outbound: "direct" } ]
      # Clients pinned to one group enter through their own inbound.
      + [ $forced[] | { inbound: ("tproxy-" + .), outbound: ("grp-" + .) } ]
      # Lists flagged "always direct" (RU sites, gov sites) win over user rules:
      # sending those abroad is what gets accounts blocked.
      + ( [ $geo_sets[] | select(.direct // false) | .id ]
          | if length > 0 then [ { rule_set: ., outbound: "direct" } ] else [] end )
      + [ $rules[] | . as $r
          | ( {}
              + (if (($r.match.rule_set // []) | length) > 0 then { rule_set: $r.match.rule_set } else {} end)
              + (if (($r.match.domain // []) | length) > 0 then { domain: $r.match.domain } else {} end)
              + (if (($r.match.domain_suffix // []) | length) > 0 then { domain_suffix: $r.match.domain_suffix } else {} end)
              + (if (($r.match.domain_keyword // []) | length) > 0 then { domain_keyword: $r.match.domain_keyword } else {} end)
              + (if (($r.match.ip_cidr // []) | length) > 0 then { ip_cidr: $r.match.ip_cidr } else {} end)
              + (if (($r.match.port // []) | length) > 0 then { port: $r.match.port } else {} end)
              + (if (($r.match.source_ip_cidr // []) | length) > 0 then { source_ip_cidr: $r.match.source_ip_cidr } else {} end)
            ) as $m
          | select(($m | length) > 0)
          | if ($r.action // "") == "block"
            then $m + { action: "reject" }
            else $m + { outbound: rule_target($r) } end ]
    ),
    rule_set: [ $geo_sets[] | { type: "local", tag: .id, format: "binary",
                                path: ($geo_dir + "/" + .id + ".srs") } ],
    final: (if (($s.general.final // "direct") | startswith("group:"))
               and (($s.general.final | ltrimstr("group:")) as $g | $gids | index($g))
            then "grp-" + ($s.general.final | ltrimstr("group:"))
            else "direct" end),
    auto_detect_interface: true,
    default_domain_resolver: { server: "dns-local" }
  },

  experimental: {
    clash_api: { external_controller: ("127.0.0.1:" + $api_port) },
    cache_file: { enabled: true, path: $cache }
  }
}

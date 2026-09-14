/* sbmerlin — WebUI logic.
 *
 * Reads state from /ext/sbmerlin/{settings,status}.json (plain files written by
 * the backend) and writes changes back through the firmware's own applyapp.cgi:
 * each section is base64-encoded and split into sbm_<section>_<n> chunks so a
 * long node list cannot overflow a single custom_settings value.
 */

var S = null;          /* settings */
var ST = null;         /* status */
var CHUNK = 1400;
var SECTIONS = ['general', 'groups', 'nodes', 'subs', 'rules', 'clients', 'geo'];

function sbmInit() {
	show_menu();
	$('#sbm .sbm-tab').on('click', function () {
		$('#sbm .sbm-tab').removeClass('active');
		$(this).addClass('active');
		$('#sbm .sbm-panel').removeClass('active');
		$('#panel-' + $(this).data('panel')).addClass('active');
	});
	sbmLoadSettings(function () { sbmLoadStatus(); });
	setInterval(sbmTick, 15000);
}

/* ---------- loading ---------- */
function sbmLoadSettings(done) {
	$.ajax({ url: '/ext/sbmerlin/settings.json?t=' + Date.now(), dataType: 'json', cache: false })
		.done(function (d) {
			S = d;
			sbmSnapshot();
			sbmRenderAll();
			if (done) done();
		})
		.fail(function () {
			$('#sbm-version').text(' — настройки не найдены, выполните установку заново');
		});
}

function sbmLoadStatus() {
	$.ajax({ url: '/ext/sbmerlin/status.json?t=' + Date.now(), dataType: 'json', cache: false })
		.done(function (d) { ST = d; sbmRenderStatus(); });
}

/* The 15-second refresh must not redraw tables the user is in the middle of
 * editing, and must not resurrect pre-save data while an apply is running. */
function sbmTick() {
	if (APPLYING || EDITING >= 0) return;
	sbmLoadStatus();
}

function sbmLoadLog() {
	$.ajax({ url: '/ext/sbmerlin/sbmerlin.log?t=' + Date.now(), dataType: 'text', cache: false })
		.done(function (t) { $('#log-body').text(t || '(пусто)'); })
		.fail(function () { $('#log-body').text('лог недоступен'); });
}

/* ---------- rendering ---------- */
function sbmRenderAll() {
	sbmRenderSettings();
	sbmRenderServers();
	sbmRenderRules();
	sbmRenderClients();
	sbmRenderGeo();
}

function sbmRenderStatus() {
	if (!ST) return;
	$('#sbm-version').text(' v' + (ST.version || '') );
	$('#st-running').html(ST.running
		? '<span class="sbm-pill ok">работает</span> <span class="sbm-muted">pid ' + ST.pid + '</span>'
		: '<span class="sbm-pill bad">остановлен</span>');
	var modeTxt = ST.mode === 'tproxy'
		? 'TPROXY — TCP и UDP'
		: 'REDIRECT — только TCP (в ядре нет xt_TPROXY, UDP/QUIC идёт мимо прокси)';
	$('#st-mode').text(modeTxt);
	$('#st-rss').text((ST.rss_mb || 0) + ' МБ');
	$('#st-uptime').text(ST.running ? sbmDuration(ST.uptime_s || 0) : '—');
	$('#st-core').text(ST.core || '—');
	$('#st-updated').text(ST.updated || '—');

	var tb = $('#st-groups tbody').empty();
	(ST.groups || []).forEach(function (g) {
		var nodes = (g.nodes || []).map(function (n) {
			var cls = n.delay > 0 ? 'ok' : 'bad';
			var txt = n.delay > 0 ? n.delay + ' мс' : 'нет';
			return '<span class="sbm-pill ' + cls + '" title="' + n.tag + '">' + n.tag + ': ' + txt + '</span>';
		}).join(' ');
		var alive = (g.nodes || []).filter(function (n) { return n.delay > 0; }).length;
		tb.append('<tr><td><b>' + g.name + '</b><br/><span class="sbm-muted">' +
			alive + ' из ' + (g.nodes || []).length + ' живых</span></td>' +
			'<td>' + (g.selected || '<span class="sbm-pill bad">нет</span>') + '</td>' +
			'<td style="line-height:1.9">' + (nodes || '<span class="sbm-muted">нет узлов</span>') + '</td></tr>');
	});
}

/* Human-readable uptime: the core restarting on its own is the first symptom
 * worth noticing, so it is shown rather than hidden behind the log. */
function sbmDuration(sec) {
	sec = parseInt(sec) || 0;
	if (sec <= 0) return '—';
	var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600);
	var m = Math.floor(sec % 3600 / 60);
	if (d) return d + ' ' + sbmPlural(d, 'день', 'дня', 'дней') + ' ' + h + ' ч';
	if (h) return h + ' ч ' + m + ' мин';
	return m + ' мин';
}

function sbmRenderSettings() {
	var g = S.general || {};
	$('#set-enabled').prop('checked', !!g.enabled);
	$('#set-mode').val(g.mode || 'tproxy');
	$('#set-mem').val(g.mem_limit_mb || 48);
	$('#set-rss').val((g.watchdog && g.watchdog.rss_limit_mb) || 96);
	$('#set-dnshijack').prop('checked', !(g.dns && g.dns.hijack === false));
	$('#set-dnslocal').val((g.dns && g.dns.local) || 'auto');
	$('#set-dnsremote').val((g.dns && g.dns.remote) || 'https://1.1.1.1/dns-query');
	$('#set-loglevel').val(g.log_level || 'warn');
	$('#set-debugport').val(g.debug_port || 0);
	$('#set-socksport').val(g.socks_port || 0);
	$('#set-socksuser').val(g.socks_user || '');
	$('#set-sockspass').val(g.socks_pass || '');
	$('#set-hint').html('SOCKS5/HTTP прокси доступен устройствам сети по адресу роутера на указанном порту ' +
		'(0 — выключен); в приложении укажите SOCKS5 или HTTP, один и тот же порт понимает оба. ' +
		'«auto» для локального DNS означает резолвер провайдера из настроек WAN. ' +
		'Отладочный порт открывает HTTP/SOCKS прокси на 127.0.0.1 — удобно проверить, ' +
		'куда уходит конкретный домен, командой <code>curl -x http://127.0.0.1:ПОРТ https://ipinfo.io/ip</code>.');
}

function groupOptions(sel, extra) {
	var out = '';
	(extra || []).forEach(function (e) {
		out += '<option value="' + e[0] + '"' + (sel === e[0] ? ' selected' : '') + '>' + e[1] + '</option>';
	});
	(S.groups || []).forEach(function (g) {
		var v = 'group:' + g.id;
		out += '<option value="' + v + '"' + (sel === v ? ' selected' : '') + '>' + (g.name || g.id) + '</option>';
	});
	return out;
}

function sbmRenderServers() {
	var tb = $('#sv-subs tbody').empty();
	(S.subs || []).forEach(function (s, i) {
		tb.append('<tr><td class="sbm-muted" style="word-break:break-all">' + s.url + '</td>' +
			'<td>' + (s.group || 'авто') + '</td><td>' + (s.count || 0) + '</td>' +
			'<td class="sbm-muted">' + (s.last_update || '—') + '</td>' +
			'<td><span class="sbm-del" onclick="sbmDel(\'subs\',' + i + ')">✕</span></td></tr>');
	});

	var tn = $('#sv-nodes tbody').empty();
	(S.nodes || []).forEach(function (n, i) {
		var gs = (S.groups || []).map(function (g) {
			return '<option value="' + g.id + '"' + (n.group === g.id ? ' selected' : '') + '>' + (g.name || g.id) + '</option>';
		}).join('');
		tn.append('<tr><td>' + (n.label || n.tag) + '<br/><span class="sbm-muted">' + n.tag + '</span></td>' +
			'<td><select onchange="sbmSet(\'nodes\',' + i + ',\'group\',this.value)">' + gs + '</select></td>' +
			'<td class="sbm-muted">' + ((n.json && n.json.type) || '?') + '</td>' +
			'<td><input type="checkbox"' + (n.enabled !== false ? ' checked' : '') +
			' onchange="sbmSet(\'nodes\',' + i + ',\'enabled\',this.checked)"/></td>' +
			'<td><span class="sbm-del" onclick="sbmDel(\'nodes\',' + i + ')">✕</span></td></tr>');
	});
}

var PROTOCOLS = ['http', 'tls', 'quic', 'bittorrent', 'dns', 'stun', 'ssh'];
var INBOUNDS = [
	['lan', 'перехват LAN'],
	['socks', 'SOCKS-прокси'],
	['pinned', 'привязанные устройства']
];
var EDITING = -1;
var APPLYING = false;

/* The table shows every parameter of a rule except the lists themselves, which
 * are only counted here and edited in the dialog. */
function sbmRenderRules() {
	var tb = $('#rl-table tbody').empty();
	(S.rules || []).forEach(function (r, i) {
		var m = r.match || {};
		var chips = [];
		var ns = (m.rule_set || []).length;
		var nd = (m.domain || []).length + (m.domain_suffix || []).length + (m.domain_keyword || []).length;
		var ni = (m.ip_cidr || []).length;
		if (ns) chips.push('<span class="sbm-chip set">' + ns + ' ' + sbmPlural(ns, 'список', 'списка', 'списков') + '</span>');
		if (nd) chips.push('<span class="sbm-chip dom">' + nd + ' ' + sbmPlural(nd, 'домен', 'домена', 'доменов') + '</span>');
		if (ni) chips.push('<span class="sbm-chip ip">' + ni + ' IP</span>');
		if (m.network) chips.push('<span class="sbm-chip">' + m.network + '</span>');
		(m.protocol || []).forEach(function (p) { chips.push('<span class="sbm-chip">' + p + '</span>'); });
		var ports = (m.port || []).concat((m.port_range || []).map(function (x) { return x.replace(':', '-'); }));
		if (ports.length) chips.push('<span class="sbm-chip">порт ' + ports.join(', ') + '</span>');
		(m.inbound || []).forEach(function (k) {
			chips.push('<span class="sbm-chip">из: ' + sbmInboundLabel([k]) + '</span>');
		});
		if (!chips.length) chips.push('<span class="sbm-chip">пусто — правило ничего не ловит</span>');

		chips.push('<span class="sbm-chip">при отказе: ' +
			(r.on_fail === 'direct' ? 'напрямую' : 'блок') + '</span>');
		var dim = r.enabled === false ? ' style="opacity:.45"' : '';
		tb.append('<tr' + dim + '>' +
			'<td><div class="sbm-order">' +
				'<span onclick="sbmMove(' + i + ',-1)" title="выше">▲</span>' +
				'<span onclick="sbmMove(' + i + ',1)" title="ниже">▼</span></div></td>' +
			'<td><div class="sbm-rule-name">' + (r.name || 'без имени') + '</div>' +
				'<div class="sbm-chips">' + chips.join('') + '</div></td>' +
			'<td class="sbm-out">' + sbmActionLabel(r.action) + '</td>' +
			'<td><input type="checkbox"' + (r.enabled !== false ? ' checked' : '') +
				' onchange="sbmSet(\'rules\',' + i + ',\'enabled\',this.checked); sbmRenderRules();"/></td>' +
			'<td class="sbm-acts"><button type="button" class="sbm-btn" onclick="sbmEditOpen(' + i + ')">⚙ Правка</button> ' +
				'<button type="button" class="sbm-btn danger" onclick="sbmDel(\'rules\',' + i + ')">✕</button></td>' +
			'</tr>');
	});
	$('#rl-final').html(groupOptions((S.general && S.general.final) || 'direct', [['direct', 'Напрямую']]))
		.off('change').on('change', function () { S.general.final = this.value; });
}

function sbmPlural(n, one, few, many) {
	var a = n % 10, b = n % 100;
	if (a === 1 && b !== 11) return one;
	if (a >= 2 && a <= 4 && (b < 10 || b >= 20)) return few;
	return many;
}

function sbmActionLabel(a) {
	if (a === 'direct') return 'Напрямую';
	if (a === 'block') return 'Блокировать';
	if ((a || '').indexOf('group:') === 0) {
		var id = a.slice(6);
		var g = (S.groups || []).filter(function (x) { return x.id === id; })[0];
		return g ? (g.name || g.id) : id;
	}
	return a || '—';
}

function sbmInboundLabel(list) {
	if (!list || !list.length) return 'любой';
	return list.map(function (k) {
		var f = INBOUNDS.filter(function (x) { return x[0] === k; })[0];
		return f ? f[1] : k;
	}).join(', ');
}

/* ---------- rule editor ---------- */
function sbmEditOpen(idx) {
	EDITING = idx;
	var r = S.rules[idx];
	var m = r.match || {};

	$('#ed-name').val(r.name || '');
	$('#ed-action').html(groupOptions(r.action, [['direct', 'Напрямую'], ['block', 'Блокировать']]));
	$('#ed-onfail').val(r.on_fail === 'direct' ? 'direct' : 'block');
	$('#ed-network').val(m.network || '');
	$('#ed-ports').val((m.port || []).concat(m.port_range || []).join(', '));

	$('#ed-proto').html(PROTOCOLS.map(function (p) {
		var on = (m.protocol || []).indexOf(p) >= 0;
		return '<label><input type="checkbox" class="ed-proto-cb" value="' + p + '"' +
			(on ? ' checked' : '') + '/>' + p + '</label>';
	}).join(''));

	$('#ed-inbound').html(INBOUNDS.map(function (p) {
		var on = (m.inbound || []).indexOf(p[0]) >= 0;
		return '<label><input type="checkbox" class="ed-in-cb" value="' + p[0] + '"' +
			(on ? ' checked' : '') + '/>' + p[1] + '</label>';
	}).join(''));

	$('#ed-domains').val([]
		.concat(m.domain || [])
		.concat((m.domain_suffix || []).map(function (d) { return '*.' + d; }))
		.concat((m.domain_keyword || []).map(function (d) { return '*' + d + '*'; }))
		.join('\n'));
	$('#ed-ips').val((m.ip_cidr || []).join('\n'));
	$('#ed-sets').val((m.rule_set || []).join('\n'));

	$('#rl-editor').addClass('open');
}

function sbmEditClose() {
	$('#rl-editor').removeClass('open');
	EDITING = -1;
}

function sbmEditSave() {
	if (EDITING < 0) return;
	var r = S.rules[EDITING];
	var m = { domain: [], domain_suffix: [], domain_keyword: [], ip_cidr: [],
		rule_set: [], port: [], port_range: [], protocol: [], inbound: [] };

	r.name = $('#ed-name').val() || 'без имени';
	r.action = $('#ed-action').val();
	r.on_fail = $('#ed-onfail').val();

	var net = $('#ed-network').val();
	if (net) m.network = net;

	$('#ed-ports').val().split(/[,\s]+/).forEach(function (p) {
		p = p.trim();
		if (!p) return;
		/* sing-box writes a range as 100:200, people write it as 100-200 */
		if (p.indexOf('-') > 0) m.port_range.push(p.replace('-', ':'));
		else if (p.indexOf(':') > 0) m.port_range.push(p);
		else m.port.push(p);
	});

	$('.ed-proto-cb:checked').each(function () { m.protocol.push(this.value); });
	$('.ed-in-cb:checked').each(function () { m.inbound.push(this.value); });

	$('#ed-domains').val().split(/[\n,]+/).forEach(function (d) {
		d = d.trim();
		if (!d) return;
		if (d.charAt(0) === '*' && d.charAt(d.length - 1) === '*') m.domain_keyword.push(d.slice(1, -1));
		else if (d.indexOf('*.') === 0) m.domain_suffix.push(d.slice(2));
		else if (d.charAt(0) === '.') m.domain_suffix.push(d.slice(1));
		else m.domain.push(d);
	});
	$('#ed-ips').val().split(/[\n,\s]+/).forEach(function (d) {
		d = d.trim();
		if (!d) return;
		m.ip_cidr.push(d.indexOf('/') > 0 ? d : (d.indexOf(':') > 0 ? d + '/128' : d + '/32'));
	});
	$('#ed-sets').val().split(/[\n,\s]+/).forEach(function (d) {
		d = d.trim();
		if (d) m.rule_set.push(d);
	});

	Object.keys(m).forEach(function (k) {
		if (Array.isArray(m[k]) && !m[k].length) delete m[k];
	});
	r.match = m;
	sbmEditClose();
	sbmRenderRules();
}

function sbmRenderClients() {
	var tb = $('#cl-table tbody').empty();
	(S.clients || []).forEach(function (c, i) {
		tb.append('<tr>' +
			'<td><input type="text" size="18" value="' + (c.mac || '') + '" ' +
				'onchange="sbmSet(\'clients\',' + i + ',\'mac\',this.value)" placeholder="AA:BB:CC:DD:EE:FF"/></td>' +
			'<td><input type="text" size="14" value="' + (c.ip || '') + '" ' +
				'onchange="sbmSet(\'clients\',' + i + ',\'ip\',this.value)" placeholder="192.168.2.50"/></td>' +
			'<td><input type="text" size="14" value="' + (c.name || '') + '" ' +
				'onchange="sbmSet(\'clients\',' + i + ',\'name\',this.value)"/></td>' +
			'<td><select onchange="sbmSet(\'clients\',' + i + ',\'mode\',this.value)">' +
				'<option value="rules"' + ((c.mode || 'rules') === 'rules' ? ' selected' : '') + '>Общие правила</option>' +
				'<option value="bypass"' + (c.mode === 'bypass' ? ' selected' : '') + '>Мимо прокси</option>' +
				(S.groups || []).map(function (g) {
					var v = 'force:' + g.id;
					return '<option value="' + v + '"' + (c.mode === v ? ' selected' : '') +
						'>Вся в ' + (g.name || g.id) + '</option>';
				}).join('') + '</select></td>' +
			'<td><span class="sbm-del" onclick="sbmDel(\'clients\',' + i + ')">✕</span></td></tr>');
	});
}

function sbmRenderGeo() {
	var tb = $('#geo-table tbody').empty();
	(S.geo || []).forEach(function (g, i) {
		tb.append('<tr>' +
			'<td>' + (g.name || g.id) + '<br/><span class="sbm-muted" style="word-break:break-all">' + g.url + '</span></td>' +
			'<td class="sbm-muted">' + (g.format || '') + '</td>' +
			'<td class="sbm-muted">' + (g.target || 'srs') + '</td>' +
			'<td><input type="text" size="4" value="' + (g.interval_h || 24) + '" ' +
				'onchange="sbmSet(\'geo\',' + i + ',\'interval_h\',parseInt(this.value)||24)"/></td>' +
			'<td><input type="checkbox"' + (g.enabled ? ' checked' : '') +
				' onchange="sbmSet(\'geo\',' + i + ',\'enabled\',this.checked)"/></td>' +
			'<td><span class="sbm-del" onclick="sbmDel(\'geo\',' + i + ')">✕</span></td></tr>');
	});
}

/* ---------- editing ---------- */
function sbmSet(section, idx, key, val) { S[section][idx][key] = val; }
function sbmDel(section, idx) { S[section].splice(idx, 1); sbmRenderAll(); }

function sbmMove(idx, dir) {
	var t = idx + dir;
	if (t < 0 || t >= S.rules.length) return;
	var tmp = S.rules[idx];
	S.rules[idx] = S.rules[t];
	S.rules[t] = tmp;
	sbmRenderRules();
}

/* Free-form matcher field -> the structured match object the backend expects.
 * Accepts the shorthands an Xray user already knows: geosite:youtube, geoip:ru,
 * protocol:bittorrent, udp, port:443, port:50000-65535. */
function sbmSetMatch(idx, text) {
	var m = { rule_set: [], domain: [], domain_suffix: [], domain_keyword: [],
		ip_cidr: [], port: [], port_range: [], protocol: [] };
	var network = '';
	text.split(/[,|]/).forEach(function (raw) {
		var t = raw.trim();
		if (!t) return;
		if (t.indexOf('список:') === 0) t = t.slice(7).trim();
		else if (t.indexOf('rule_set:') === 0) t = t.slice(9).trim();

		if (t.indexOf('geosite:') === 0 || t.indexOf('geoip:') === 0) m.rule_set.push(t);
		else if (t.indexOf('geosite-') === 0 || t.indexOf('geoip-') === 0) m.rule_set.push(t);
		else if (t.indexOf('protocol:') === 0) m.protocol.push(t.slice(9).trim());
		else if (t === 'bittorrent' || t === 'quic' || t === 'dtls' || t === 'stun') m.protocol.push(t);
		else if (t === 'udp' || t === 'tcp') network = t;
		else if (t.indexOf('port:') === 0) {
			t.slice(5).split(/\s+/).forEach(function (p) {
				if (p.indexOf('-') > 0) m.port_range.push(p); else if (p) m.port.push(p);
			});
		}
		else if (/^[0-9.]+\/[0-9]+$/.test(t)) m.ip_cidr.push(t);
		else if (/^[0-9.]+$/.test(t)) m.ip_cidr.push(t + '/32');
		else if (t.charAt(0) === '*' && t.charAt(t.length - 1) === '*') m.domain_keyword.push(t.slice(1, -1));
		else if (t.indexOf('*.') === 0) m.domain_suffix.push(t.slice(2));
		else m.domain_suffix.push(t.replace(/^\./, ''));
	});
	Object.keys(m).forEach(function (k) { if (!m[k].length) delete m[k]; });
	if (network) m.network = network;
	S.rules[idx].match = m;
}

/* The structured match object rendered back into that same free-form text. */
function sbmMatchText(m) {
	m = m || {};
	return []
		.concat(m.rule_set || [])
		.concat((m.protocol || []).map(function (x) { return 'protocol:' + x; }))
		.concat(m.network ? [m.network] : [])
		.concat((m.port || []).map(function (x) { return 'port:' + x; }))
		.concat((m.port_range || []).map(function (x) { return 'port:' + x; }))
		.concat(m.domain_suffix || [])
		.concat(m.domain || [])
		.concat((m.domain_keyword || []).map(function (x) { return '*' + x + '*'; }))
		.concat(m.ip_cidr || [])
		.join(', ');
}

function sbmAddRule() {
	S.rules = S.rules || [];
	S.rules.push({ id: 'r' + Date.now(), name: 'Новое правило', enabled: true,
		match: {}, action: 'direct', on_fail: 'block' });
	sbmRenderRules();
	sbmEditOpen(S.rules.length - 1);
}

function sbmAddClient() {
	S.clients = S.clients || [];
	S.clients.push({ mac: '', ip: '', name: '', mode: 'rules' });
	sbmRenderClients();
}

function sbmAddGeo() {
	var url = prompt('URL списка (домены или IP, по одному в строке, либо готовый .srs):', '');
	if (!url) return;
	var name = prompt('Название списка:', 'Мой список') || 'Мой список';
	var fmt = url.slice(-4) === '.srs' ? 'srs'
		: (confirm('Это список IP-адресов? OK — IP, Отмена — домены') ? 'plain-ip' : 'plain-domain');
	var tgt = (fmt === 'plain-ip' && confirm('Обрабатывать в ядре Linux (ipset, всегда direct)? ' +
		'OK — ipset, Отмена — обычный список для правил')) ? 'ipset' : 'srs';
	S.geo = S.geo || [];
	S.geo.push({ id: 'g' + Date.now(), name: name, url: url, format: fmt, target: tgt,
		interval_h: 24, enabled: true });
	sbmRenderGeo();
}

/* ---------- links and subscriptions ---------- */
function sbmAddLinks() {
	var text = $('#sv-input').val().trim();
	if (!text) { alert('Вставьте хотя бы одну ссылку'); return; }
	var links = text.split(/\s+/).filter(function (l) { return /^(vless|vmess|ss|trojan):\/\//.test(l); });
	if (!links.length) { alert('Не найдено ссылок vless:// vmess:// ss:// trojan://'); return; }
	sbmSend(sbmChunkPairs('sbm_links', sbmB64(links.join('\n'))), 'start_sbmerlinlinks',
		'Добавляю ' + links.length + ' ссыл(ку/ки)…', true);
	$('#sv-input').val('');
}

function sbmAddSub() {
	var url = $('#sv-input').val().trim();
	if (!/^https?:\/\//.test(url)) { alert('Вставьте адрес подписки (http:// или https://)'); return; }
	S.subs = S.subs || [];
	S.subs.push({ id: 's' + Date.now(), url: url, group: '', interval_h: 6 });
	$('#sv-input').val('');
	sbmRenderServers();
	sbmApply('sub');
}

/* ---------- saving ---------- */
function sbmB64(str) { return btoa(unescape(encodeURIComponent(str))); }

function sbmCollectSettings() {
	S.general = S.general || {};
	S.general.enabled = $('#set-enabled').prop('checked');
	S.general.mode = $('#set-mode').val();
	S.general.mem_limit_mb = parseInt($('#set-mem').val()) || 48;
	S.general.log_level = $('#set-loglevel').val();
	S.general.debug_port = parseInt($('#set-debugport').val()) || 0;
	// Remember the previous port so the firewall can withdraw its old ACCEPT rule.
	S.general.socks_port_prev = S.general.socks_port || 0;
	S.general.socks_port = parseInt($('#set-socksport').val()) || 0;
	S.general.socks_user = $('#set-socksuser').val() || '';
	S.general.socks_pass = $('#set-sockspass').val() || '';
	S.general.watchdog = S.general.watchdog || {};
	S.general.watchdog.enabled = true;
	S.general.watchdog.rss_limit_mb = parseInt($('#set-rss').val()) || 96;
	S.general.dns = S.general.dns || {};
	S.general.dns.hijack = $('#set-dnshijack').prop('checked');
	S.general.dns.local = $('#set-dnslocal').val() || 'auto';
	S.general.dns.remote = $('#set-dnsremote').val() || 'https://1.1.1.1/dns-query';
}

/* ---------- sending ---------- */
/* The firmware rejects any amng_custom value over 8192 bytes ("nvram_check fail:
 * amng_custom over length") and drops the whole save with nothing the page can
 * see — which is how settings used to vanish. So only sections that changed are
 * sent, split across several small requests; the last one starts the apply. */
var POST_BUDGET = 6000;
var SNAP = {};
var APPLY_MARK = '';

function sbmSnapshot() {
	SNAP = {};
	SECTIONS.forEach(function (sec) { SNAP[sec] = JSON.stringify(S[sec]); });
}

/* A value split into numbered chunks plus a count marker: the backend imports
 * it only once every piece has arrived. */
function sbmChunkPairs(key, b64) {
	var pairs = [];
	for (var i = 0, n = 1; i < b64.length; i += CHUNK, n++) pairs.push([key + '_' + n, b64.substr(i, CHUNK)]);
	pairs.push([key + '_n', String(pairs.length)]);
	return pairs;
}

function sbmApply(extraService) {
	sbmCollectSettings();
	var pairs = [];
	SECTIONS.forEach(function (sec) {
		var v = S[sec] === undefined ? (sec === 'general' ? {} : []) : S[sec];
		if (JSON.stringify(v) === SNAP[sec]) return;
		pairs = pairs.concat(sbmChunkPairs('sbm_' + sec, sbmB64(JSON.stringify(v))));
	});
	sbmSend(pairs, 'start_sbmerlin' + (extraService || 'apply'), 'Применяю настройки…', true);
}

function sbmService(what) {
	var map = { start: 'start_sbmerlinstart', stop: 'start_sbmerlinstop',
		apply: 'start_sbmerlinapply', sub: 'start_sbmerlinsub',
		geo: 'start_sbmerlingeo', test: 'start_sbmerlintest' };
	if (what === 'apply' || what === 'sub') { sbmApply(what === 'sub' ? 'sub' : 'apply'); return; }
	sbmSend([], map[what], 'Выполняю…', false);
}

function sbmPost(obj, service) {
	return $.ajax({
		url: '/applyapp.cgi', type: 'POST', timeout: 20000,
		data: {
			productid: document.form.productid.value,
			current_page: '', next_page: '', modified: '0',
			action_mode: 'apply', action_script: service, action_wait: '1',
			first_time: '', preferred_lang: document.form.preferred_lang.value,
			firmver: document.form.firmver.value,
			amng_custom: JSON.stringify(obj)
		}
	});
}

function sbmSend(pairs, service, message, waitApply) {
	var batches = [], cur = {}, size = 2;
	pairs.forEach(function (p) {
		var add = p[0].length + p[1].length + 6;
		if (size + add > POST_BUDGET && Object.keys(cur).length) { batches.push(cur); cur = {}; size = 2; }
		cur[p[0]] = p[1];
		size += add;
	});
	batches.push(cur);

	var total = batches.length;
	APPLYING = true;
	/* Remember the last finished apply, so its stale "done" is not mistaken for
	 * this one finishing before the backend has even started. */
	$.ajax({ url: '/ext/sbmerlin/apply.json?t=' + Date.now(), dataType: 'json', cache: false })
		.always(function (d) {
			APPLY_MARK = (d && d.updated) || '';
			step(0);
		});

	function step(i) {
		var last = i === total - 1;
		$('#sbm-saved').text((message || 'Выполняю…') +
			(total > 1 ? ' — часть ' + (i + 1) + ' из ' + total : ''));
		/* Intermediate parts use a service name the backend ignores: they only
		 * need to land in custom_settings.txt. */
		sbmPost(batches[i], last ? service : 'start_sbmerlinstage')
			.done(function () {
				if (!last) { step(i + 1); return; }
				if (waitApply) { sbmWaitApply(0); return; }
				setTimeout(function () {
					APPLYING = false;
					sbmLoadStatus();
					$('#sbm-saved').text('Готово');
				}, 6000);
			})
			.fail(function () {
				APPLYING = false;
				$('#sbm-saved').text('Роутер не принял часть ' + (i + 1) + ' из ' + total +
					' — настройки не применены, попробуйте ещё раз');
			});
	}
}

/* Applying restarts the core and may download rule-sets, which takes far longer
 * than any fixed timeout: poll the state the backend writes and only reload the
 * page data once this apply has finished. */
function sbmWaitApply(tries) {
	if (tries > 120) {
		APPLYING = false;
		$('#sbm-saved').text('Применение занимает дольше обычного — проверьте вкладку Логи');
		return;
	}
	$.ajax({ url: '/ext/sbmerlin/apply.json?t=' + Date.now(), dataType: 'json', cache: false })
		.done(function (d) {
			var fresh = d && d.updated && d.updated !== APPLY_MARK;
			if (!fresh || d.state === 'running') {
				$('#sbm-saved').text('Применяю настройки… ' + (tries * 2) + ' с');
				setTimeout(function () { sbmWaitApply(tries + 1); }, 2000);
				return;
			}
			APPLYING = false;
			sbmLoadSettings(function () { sbmLoadStatus(); });
			$('#sbm-saved').text(d.state === 'failed'
				? 'Ошибка применения — смотрите вкладку Логи'
				: 'Готово, настройки применены');
		})
		.fail(function () {
			setTimeout(function () { sbmWaitApply(tries + 1); }, 2000);
		});
}

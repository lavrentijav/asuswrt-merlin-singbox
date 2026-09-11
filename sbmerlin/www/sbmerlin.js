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
	setInterval(sbmLoadStatus, 15000);
}

/* ---------- loading ---------- */
function sbmLoadSettings(done) {
	$.ajax({ url: '/ext/sbmerlin/settings.json?t=' + Date.now(), dataType: 'json', cache: false })
		.done(function (d) {
			S = d;
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
	$('#set-hint').html('«auto» для локального DNS означает резолвер провайдера из настроек WAN. ' +
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

function sbmRenderRules() {
	var tb = $('#rl-table tbody').empty();
	(S.rules || []).forEach(function (r, i) {
		var m = r.match || {};
		var matchText = [
			(m.rule_set || []).map(function (x) { return 'список:' + x; }).join(', '),
			(m.domain_suffix || []).join(', '),
			(m.domain || []).join(', '),
			(m.domain_keyword || []).map(function (x) { return '*' + x + '*'; }).join(', '),
			(m.ip_cidr || []).join(', ')
		].filter(function (x) { return x; }).join(' | ');
		tb.append('<tr>' +
			'<td><input type="text" size="16" value="' + (r.name || '') + '" ' +
				'onchange="sbmSet(\'rules\',' + i + ',\'name\',this.value)"/></td>' +
			'<td><input type="text" style="width:98%" value="' + matchText.replace(/"/g, '&quot;') + '" ' +
				'onchange="sbmSetMatch(' + i + ',this.value)" ' +
				'placeholder="example.com, *keyword*, 1.2.3.0/24, список:rkn-domains"/></td>' +
			'<td><select onchange="sbmSet(\'rules\',' + i + ',\'action\',this.value)">' +
				groupOptions(r.action, [['direct', 'Напрямую'], ['block', 'Блокировать']]) + '</select></td>' +
			'<td><select onchange="sbmSet(\'rules\',' + i + ',\'on_fail\',this.value)">' +
				'<option value="block"' + (r.on_fail !== 'direct' ? ' selected' : '') + '>Блокировать</option>' +
				'<option value="direct"' + (r.on_fail === 'direct' ? ' selected' : '') + '>Пустить напрямую</option>' +
				'</select></td>' +
			'<td><input type="checkbox"' + (r.enabled !== false ? ' checked' : '') +
				' onchange="sbmSet(\'rules\',' + i + ',\'enabled\',this.checked)"/></td>' +
			'<td><span class="sbm-del" onclick="sbmMove(' + i + ',-1)">↑</span> ' +
				'<span class="sbm-del" onclick="sbmMove(' + i + ',1)">↓</span> ' +
				'<span class="sbm-del" onclick="sbmDel(\'rules\',' + i + ')">✕</span></td></tr>');
	});
	$('#rl-final').html(groupOptions((S.general && S.general.final) || 'direct', [['direct', 'Напрямую']]))
		.off('change').on('change', function () { S.general.final = this.value; });
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

/* Free-form matcher field -> the structured match object the backend expects. */
function sbmSetMatch(idx, text) {
	var m = { rule_set: [], domain: [], domain_suffix: [], domain_keyword: [], ip_cidr: [] };
	text.split(/[,|]/).forEach(function (raw) {
		var t = raw.trim();
		if (!t) return;
		if (t.indexOf('список:') === 0) m.rule_set.push(t.slice(7).trim());
		else if (t.indexOf('rule_set:') === 0) m.rule_set.push(t.slice(9).trim());
		else if (t.indexOf('/') > 0 && /^[0-9.]+\/[0-9]+$/.test(t)) m.ip_cidr.push(t);
		else if (t.charAt(0) === '*' && t.charAt(t.length - 1) === '*') m.domain_keyword.push(t.slice(1, -1));
		else m.domain_suffix.push(t.replace(/^\./, ''));
	});
	Object.keys(m).forEach(function (k) { if (!m[k].length) delete m[k]; });
	S.rules[idx].match = m;
}

function sbmAddRule() {
	S.rules = S.rules || [];
	S.rules.push({ id: 'r' + Date.now(), name: 'Новое правило', enabled: true,
		match: { domain_suffix: [] }, action: 'direct', on_fail: 'block' });
	sbmRenderRules();
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
	sbmRun('start_sbmerlinlinks', { sbm_links: sbmB64(links.join('\n')) },
		'Добавляю ' + links.length + ' ссыл(ку/ки)…');
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
	S.general.watchdog = S.general.watchdog || {};
	S.general.watchdog.enabled = true;
	S.general.watchdog.rss_limit_mb = parseInt($('#set-rss').val()) || 96;
	S.general.dns = S.general.dns || {};
	S.general.dns.hijack = $('#set-dnshijack').prop('checked');
	S.general.dns.local = $('#set-dnslocal').val() || 'auto';
	S.general.dns.remote = $('#set-dnsremote').val() || 'https://1.1.1.1/dns-query';
}

/* Split one section into numbered chunks; the backend joins them back. */
function sbmChunk(payload, key, out) {
	var b = sbmB64(JSON.stringify(payload));
	if (b.length <= CHUNK) { out[key] = b; return; }
	for (var i = 0, n = 1; i < b.length; i += CHUNK, n++) out[key + '_' + n] = b.substr(i, CHUNK);
}

function sbmApply(extraService) {
	sbmCollectSettings();
	var payload = {};
	SECTIONS.forEach(function (sec) { sbmChunk(S[sec] || (sec === 'general' ? {} : []), 'sbm_' + sec, payload); });
	sbmRun('start_sbmerlin' + (extraService || 'apply'), payload, 'Применяю настройки…');
}

function sbmService(what) {
	var map = { start: 'start_sbmerlinstart', stop: 'start_sbmerlinstop',
		apply: 'start_sbmerlinapply', sub: 'start_sbmerlinsub',
		geo: 'start_sbmerlingeo', test: 'start_sbmerlintest' };
	if (what === 'apply' || what === 'sub') { sbmApply(what === 'sub' ? 'sub' : 'apply'); return; }
	sbmRun(map[what], {}, 'Выполняю…');
}

/* Hand the work to the firmware: it writes custom_settings.txt and fires
 * service-event, which our backend script handles. */
function sbmRun(service, extraSettings, message) {
	Object.keys(extraSettings || {}).forEach(function (k) { custom_settings[k] = extraSettings[k]; });
	$('#sbm-saved').text(message || 'Выполняю…');
	document.form.action_script.value = service;
	document.form.action_mode.value = 'apply';
	document.form.action_wait.value = '10';
	document.form.amng_custom.value = JSON.stringify(custom_settings);
	document.form.action = '/applyapp.cgi';
	document.form.target = 'hidden_frame';
	document.form.submit();
	setTimeout(function () {
		sbmLoadSettings(function () { sbmLoadStatus(); });
		$('#sbm-saved').text('Готово — состояние обновлено');
	}, 12000);
}

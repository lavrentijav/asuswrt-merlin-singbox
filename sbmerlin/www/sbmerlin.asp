<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
<meta HTTP-EQUIV="Pragma" CONTENT="no-cache"/>
<meta HTTP-EQUIV="Expires" CONTENT="-1"/>
<link rel="shortcut icon" href="images/favicon.png"/>
<title>sing-box</title>
<link rel="stylesheet" type="text/css" href="index_style.css"/>
<link rel="stylesheet" type="text/css" href="form_style.css"/>
<script language="JavaScript" type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<style>
#sbm .sbm-tabs { display:flex; gap:4px; margin:0 0 12px 0; flex-wrap:wrap; }
#sbm .sbm-tab { padding:7px 14px; cursor:pointer; background:#2f3e44; color:#a9c0c9;
	border-radius:4px 4px 0 0; font-weight:bold; user-select:none; }
#sbm .sbm-tab.active { background:#4d595d; color:#fff; }
#sbm .sbm-panel { display:none; }
#sbm .sbm-panel.active { display:block; }
#sbm table.sbm-grid { width:100%; border-collapse:collapse; }
#sbm table.sbm-grid th { background:#2f3e44; color:#fff; text-align:left; padding:6px 8px; font-size:12px; }
#sbm table.sbm-grid td { padding:5px 8px; border-bottom:1px solid #3a4b50; vertical-align:middle; }
#sbm table.sbm-grid tr:hover td { background:#3f4f54; }
#sbm input[type=text], #sbm select, #sbm textarea {
	background:#475a5f; color:#fff; border:1px solid #222; border-radius:3px; padding:4px; }
#sbm textarea { width:98%; font-family:monospace; font-size:12px; }
#sbm .sbm-pill { display:inline-block; padding:1px 8px; border-radius:9px; font-size:11px; font-weight:bold; }
#sbm .ok   { background:#1f6f3f; color:#c9f7d8; }
#sbm .bad  { background:#7a2222; color:#ffd6d6; }
#sbm .warn { background:#7a5a12; color:#ffe9b8; }
#sbm .sbm-muted { color:#8fa3ab; font-size:11px; }
#sbm .sbm-actions { margin:10px 0; display:flex; gap:6px; flex-wrap:wrap; }
#sbm .sbm-kv { display:grid; grid-template-columns:190px 1fr; gap:6px 10px; align-items:center; max-width:760px; }
#sbm pre.sbm-log { background:#1b2528; color:#cfe3ea; padding:10px; max-height:420px;
	overflow:auto; font-size:11px; line-height:1.35; border-radius:4px; }
#sbm .sbm-del { color:#ff9b9b; cursor:pointer; font-weight:bold; }
#sbm .sbm-note { background:#3f4f54; border-left:3px solid #6aa5b8; padding:8px 10px; margin:8px 0; font-size:12px; }
#sbm .sbm-link { color:#8fd0e8; cursor:pointer; text-decoration:underline dotted; }
#sbm .sbm-rule-name { font-weight:bold; color:#fff; font-size:13px; }
#sbm .sbm-chips { margin-top:3px; display:flex; gap:5px; flex-wrap:wrap; }
#sbm .sbm-chip { background:#3f4f54; color:#bcd3da; border-radius:3px; padding:1px 7px; font-size:11px; white-space:nowrap; }
#sbm .sbm-chip.set { background:#2b4d5c; color:#cfe9f5; }
#sbm .sbm-chip.dom { background:#2f4d3a; color:#d2f0dd; }
#sbm .sbm-chip.ip  { background:#4d432b; color:#f2e5c8; }
#sbm .sbm-order { display:flex; flex-direction:column; line-height:1; }
#sbm .sbm-order span { cursor:pointer; color:#9fb7bf; padding:1px 0; }
#sbm .sbm-order span:hover { color:#fff; }
#sbm .sbm-btn { background:#3f4f54; color:#fff; border:1px solid #223; border-radius:4px;
	padding:3px 8px; cursor:pointer; font-size:12px; white-space:nowrap; }
#sbm .sbm-btn:hover { background:#56696f; }
#sbm .sbm-btn.danger { background:#5c2b2b; padding:3px 7px; }
#sbm td.sbm-acts { white-space:nowrap; }
#sbm td.sbm-out { font-weight:bold; }
#sbm .sbm-modal { display:none; position:fixed; inset:0; background:rgba(0,0,0,.6); z-index:999; }
#sbm .sbm-modal.open { display:block; }
#sbm .sbm-modal-box { position:absolute; top:4%; left:50%; transform:translateX(-50%);
	width:1010px; max-width:96vw; max-height:92vh; overflow:auto;
	background:#2f3e44; border:1px solid #1b2528; border-radius:6px; box-shadow:0 10px 40px rgba(0,0,0,.6); }
#sbm .sbm-modal-head { background:#1f6f5c; color:#fff; padding:8px 12px; font-weight:bold;
	display:flex; justify-content:space-between; align-items:center; }
#sbm .sbm-close { cursor:pointer; font-weight:bold; }
#sbm .sbm-modal-body { padding:12px; }
#sbm .sbm-modal-foot { padding:10px 12px; border-top:1px solid #24343a; display:flex; gap:8px; align-items:center; }
#sbm .sbm-form { display:grid; grid-template-columns:190px 1fr; gap:8px 10px; align-items:center; margin-bottom:12px; }
#sbm .sbm-form label { color:#a9c0c9; }
#sbm .sbm-checks { display:flex; gap:14px; flex-wrap:wrap; }
#sbm .sbm-checks label { display:flex; align-items:center; gap:5px; background:#3f4f54;
	padding:4px 10px; border-radius:4px; cursor:pointer; color:#dfe9ec; }
#sbm .sbm-cols { display:grid; grid-template-columns:1fr 1fr 1fr; gap:10px; }
#sbm .sbm-col-title { margin-bottom:4px; color:#a9c0c9; font-weight:bold; font-size:12px; }
#sbm .sbm-cols textarea { width:97%; }
</style>
<script>
var custom_settings = <% get_custom_settings(); %>;
</script>
<script language="JavaScript" type="text/javascript" src="/ext/sbmerlin/sbmerlin.js"></script>
</head>

<body onload="sbmInit();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="about:blank" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" id="form" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="productid" value="<% nvram_get('productid'); %>"/>
<input type="hidden" name="current_page" value=""/>
<input type="hidden" name="next_page" value=""/>
<input type="hidden" name="modified" value="0"/>
<input type="hidden" name="action_mode" value="apply"/>
<input type="hidden" name="action_script" value=""/>
<input type="hidden" name="action_wait" value="5"/>
<input type="hidden" name="first_time" value=""/>
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get('preferred_lang'); %>"/>
<input type="hidden" name="firmver" value="<% nvram_get('firmver'); %>"/>
<input type="hidden" name="amng_custom" id="amng_custom" value=""/>

<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
	<td width="17">&nbsp;</td>
	<td valign="top" width="202">
		<div id="mainMenu"></div>
		<div id="subMenu"></div>
	</td>
	<td valign="top">
		<div id="tabMenu" class="submenuBlock"></div>
		<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
		<tr>
			<td valign="top">
				<table width="100%" border="0" cellpadding="4" cellspacing="0" class="FormTitle" id="FormTitle">
				<tbody><tr><td bgcolor="#4D595D" colspan="3" valign="top">
				<div id="sbm">
					<div style="margin:5px 0 10px 5px;">
						<span class="formfonttitle">sing-box</span>
						<span class="sbm-muted" id="sbm-version"></span>
						<div style="margin:8px 0 10px 0;" class="splitLine"></div>
						<span class="formfontdesc">Прокси и VPN на роутере: маршрутизация по сайтам, странам и устройствам.</span>
					</div>

					<div class="sbm-tabs">
						<div class="sbm-tab active" data-panel="status">Статус</div>
						<div class="sbm-tab" data-panel="servers">Серверы</div>
						<div class="sbm-tab" data-panel="rules">Правила</div>
						<div class="sbm-tab" data-panel="clients">Клиенты</div>
						<div class="sbm-tab" data-panel="geo">Geo-списки</div>
						<div class="sbm-tab" data-panel="settings">Настройки</div>
						<div class="sbm-tab" data-panel="logs">Логи</div>
					</div>

					<!-- STATUS -->
					<div class="sbm-panel active" id="panel-status">
						<div class="sbm-kv">
							<span>Состояние</span><span id="st-running">—</span>
							<span>Режим перехвата</span><span id="st-mode">—</span>
							<span>Память ядра</span><span id="st-rss">—</span>
							<span>Версия ядра</span><span id="st-core">—</span>
							<span>Обновлено</span><span id="st-updated">—</span>
						</div>
						<div class="sbm-actions">
							<input class="button_gen" type="button" value="Запустить" onclick="sbmService('start')"/>
							<input class="button_gen" type="button" value="Остановить" onclick="sbmService('stop')"/>
							<input class="button_gen" type="button" value="Перезапустить" onclick="sbmService('apply')"/>
							<input class="button_gen" type="button" value="Проверить узлы" onclick="sbmService('test')"/>
						</div>
						<table class="sbm-grid" id="st-groups"><thead><tr>
							<th style="width:130px">Группа</th><th style="width:150px">Выбранный узел</th><th>Узлы и задержки</th>
						</tr></thead><tbody></tbody></table>
					</div>

					<!-- SERVERS -->
					<div class="sbm-panel" id="panel-servers">
						<div class="sbm-note">Вставьте ссылки <b>vless:// vmess:// ss:// trojan://</b> (по одной в строке)
							или адрес подписки. Страна определяется по названию узла, группу можно поменять в таблице.</div>
						<textarea id="sv-input" rows="4" placeholder="vless://...&#10;https://example.com/sub"></textarea>
						<div class="sbm-actions">
							<input class="button_gen" type="button" value="Добавить ссылки" onclick="sbmAddLinks()"/>
							<input class="button_gen" type="button" value="Добавить подписку" onclick="sbmAddSub()"/>
							<input class="button_gen" type="button" value="Обновить подписки" onclick="sbmService('sub')"/>
						</div>
						<table class="sbm-grid" id="sv-subs"><thead><tr>
							<th>Подписка</th><th style="width:90px">Группа</th><th style="width:70px">Узлов</th>
							<th style="width:140px">Обновлена</th><th style="width:30px"></th>
						</tr></thead><tbody></tbody></table>
						<br/>
						<table class="sbm-grid" id="sv-nodes"><thead><tr>
							<th>Узел</th><th style="width:110px">Группа</th><th style="width:70px">Тип</th>
							<th style="width:60px">Вкл</th><th style="width:30px"></th>
						</tr></thead><tbody></tbody></table>
					</div>

					<!-- RULES -->
					<div class="sbm-panel" id="panel-rules">
						<div class="sbm-note">Правила применяются сверху вниз — первое совпадение выигрывает.
							Кнопка <b>Настроить</b> открывает все параметры правила; стрелками слева меняется порядок.</div>
						<table class="sbm-grid" id="rl-table"><thead><tr>
							<th style="width:26px"></th>
							<th>Правило</th>
							<th style="width:104px">Куда</th>
							<th style="width:40px">Вкл</th>
							<th style="width:104px"></th>
						</tr></thead><tbody></tbody></table>
						<div class="sbm-actions">
							<input class="button_gen" type="button" value="Добавить правило" onclick="sbmAddRule()"/>
						</div>
						<div class="sbm-kv">
							<span>Остальной трафик</span>
							<select id="rl-final"></select>
						</div>
					</div>

					<!-- CLIENTS -->
					<div class="sbm-panel" id="panel-clients">
						<div class="sbm-note">Режим устройства: <b>общие правила</b> — как у всех, <b>мимо прокси</b> —
							трафик не трогаем, <b>вся в группу</b> — весь трафик устройства идёт через выбранную страну.</div>
						<table class="sbm-grid" id="cl-table"><thead><tr>
							<th style="width:160px">MAC</th><th style="width:140px">IP</th><th>Имя</th>
							<th style="width:190px">Режим</th><th style="width:30px"></th>
						</tr></thead><tbody></tbody></table>
						<div class="sbm-actions">
							<input class="button_gen" type="button" value="Добавить устройство" onclick="sbmAddClient()"/>
						</div>
					</div>

					<!-- GEO -->
					<div class="sbm-panel" id="panel-geo">
						<div class="sbm-note">Списки скачиваются по расписанию и компилируются в компактные
							<b>.srs</b>. Списки с целью <b>ipset</b> обрабатываются ядром Linux и вообще не занимают память sing-box.</div>
						<table class="sbm-grid" id="geo-table"><thead><tr>
							<th>Список</th><th style="width:110px">Формат</th><th style="width:90px">Куда</th>
							<th style="width:90px">Период, ч</th><th style="width:60px">Вкл</th><th style="width:30px"></th>
						</tr></thead><tbody></tbody></table>
						<div class="sbm-actions">
							<input class="button_gen" type="button" value="Добавить список" onclick="sbmAddGeo()"/>
							<input class="button_gen" type="button" value="Обновить сейчас" onclick="sbmService('geo')"/>
						</div>
					</div>

					<!-- SETTINGS -->
					<div class="sbm-panel" id="panel-settings">
						<div class="sbm-kv">
							<span>Включить sing-box</span><span><input type="checkbox" id="set-enabled"/></span>
							<span>Режим перехвата</span>
							<select id="set-mode">
								<option value="tproxy">TPROXY (TCP + UDP)</option>
								<option value="redirect">REDIRECT (только TCP)</option>
							</select>
							<span>Лимит памяти ядра, МБ</span><input type="text" id="set-mem" size="6"/>
							<span>Перезапуск при RSS выше, МБ</span><input type="text" id="set-rss" size="6"/>
							<span>Перехватывать DNS</span><span><input type="checkbox" id="set-dnshijack"/></span>
							<span>Локальный DNS</span><input type="text" id="set-dnslocal" size="24"/>
							<span>Внешний DNS (DoH)</span><input type="text" id="set-dnsremote" size="34"/>
							<span>Уровень лога</span>
							<select id="set-loglevel">
								<option value="error">error</option><option value="warn">warn</option>
								<option value="info">info</option><option value="debug">debug</option>
							</select>
							<span>SOCKS5/HTTP прокси для устройств, порт</span><input type="text" id="set-socksport" size="6"/>
							<span>Логин к прокси (не обязательно)</span><input type="text" id="set-socksuser" size="16"/>
							<span>Пароль к прокси</span><input type="text" id="set-sockspass" size="16"/>
							<span>Отладочный HTTP-прокси, порт</span><input type="text" id="set-debugport" size="6"/>
						</div>
						<div class="sbm-note" id="set-hint"></div>
					</div>

					<!-- LOGS -->
					<div class="sbm-panel" id="panel-logs">
						<div class="sbm-actions">
							<input class="button_gen" type="button" value="Обновить" onclick="sbmLoadLog()"/>
						</div>
						<pre class="sbm-log" id="log-body">—</pre>
					</div>

					<!-- RULE EDITOR -->
					<div class="sbm-modal" id="rl-editor">
						<div class="sbm-modal-box">
							<div class="sbm-modal-head">
								<span>Детальные настройки правила маршрутизации</span>
								<span class="sbm-close" onclick="sbmEditClose()">✕</span>
							</div>
							<div class="sbm-modal-body">
								<div class="sbm-form">
									<label>Псевдоним</label>
									<div><input type="text" id="ed-name" style="width:97%"/></div>

									<label>Куда (outbound)</label>
									<div>
										<select id="ed-action" style="width:220px"></select>
										<span class="sbm-muted" style="margin-left:8px">направление или страна из вкладки «Серверы»</span>
									</div>

									<label>Если группа недоступна</label>
									<div>
										<select id="ed-onfail" style="width:220px">
											<option value="block">Блокировать (kill switch)</option>
											<option value="direct">Пустить напрямую</option>
										</select>
									</div>

									<label>Порты</label>
									<div>
										<input type="text" id="ed-ports" style="width:220px" placeholder="443, 50000-65535"/>
										<span class="sbm-muted" style="margin-left:8px">через запятую, диапазон через дефис</span>
									</div>

									<label>Протокол</label>
									<div id="ed-proto" class="sbm-checks"></div>

									<label>Сеть</label>
									<div>
										<select id="ed-network" style="width:220px">
											<option value="">любая</option>
											<option value="tcp">tcp</option>
											<option value="udp">udp</option>
										</select>
									</div>

									<label>Откуда (inbound)</label>
									<div id="ed-inbound" class="sbm-checks"></div>
								</div>

								<div class="sbm-cols">
									<div>
										<div class="sbm-col-title">Домены <span class="sbm-muted">по одному в строке</span></div>
										<textarea id="ed-domains" rows="9" placeholder="example.com&#10;*.example.org&#10;*keyword*"></textarea>
									</div>
									<div>
										<div class="sbm-col-title">IP-адрес или сеть CIDR</div>
										<textarea id="ed-ips" rows="9" placeholder="1.2.3.4&#10;91.108.56.0/22&#10;2001:b28:f23d::/48"></textarea>
									</div>
									<div>
										<div class="sbm-col-title">Списки <span class="sbm-muted">geosite:/geoip:/свои</span></div>
										<textarea id="ed-sets" rows="9" placeholder="geosite:youtube&#10;geoip:ru&#10;rkn-domains"></textarea>
									</div>
								</div>
							</div>
							<div class="sbm-modal-foot">
								<input class="button_gen" type="button" value="Сохранить правило" onclick="sbmEditSave()"/>
								<input class="button_gen" type="button" value="Отмена" onclick="sbmEditClose()"/>
								<span class="sbm-muted">Изменения попадут на роутер после кнопки «Применить настройки»</span>
							</div>
						</div>
					</div>

					<div style="margin-top:16px; text-align:center;">
						<input class="button_gen" type="button" value="Применить настройки" onclick="sbmApply()"/>
						<span class="sbm-muted" id="sbm-saved"></span>
					</div>
				</div>
				</td></tr></tbody></table>
			</td>
		</tr>
		</table>
	</td>
	<td width="10" align="center" valign="top"></td>
</tr>
</table>
<div id="footer"></div>
</form>
</body>
</html>

'use strict';
'require view';
'require form';
'require rpc';
'require ui';

// LuCI 21.02 has no dom/poll modules: L.dom and L.Poll live in luci.js.
function appendOne(node, child) {
	if (child instanceof Node)
		node.appendChild(child);
	else if (child !== null && child !== undefined && child !== '')
		node.appendChild(document.createTextNode(String(child)));
}

function setContent(node, children) {
	while (node.firstChild)
		node.removeChild(node.firstChild);
	if (Array.isArray(children))
		children.forEach(function (child) { appendOne(node, child); });
	else
		appendOne(node, children);
}

const callStatus = rpc.declare({ object: 'campus_redial', method: 'status', expect: {} });
const callLogs = rpc.declare({ object: 'campus_redial', method: 'logs', params: [ 'lines' ], expect: {} });
const callStart = rpc.declare({ object: 'campus_redial', method: 'start', expect: {} });
const callStop = rpc.declare({ object: 'campus_redial', method: 'stop', expect: {} });
const callTest = rpc.declare({ object: 'campus_redial', method: 'test', expect: {} });
const callRedial = rpc.declare({ object: 'campus_redial', method: 'redial_once', expect: {} });
const callClear = rpc.declare({ object: 'campus_redial', method: 'clear_stats', expect: {} });
const callZapretStatus = rpc.declare({ object: 'campus_redial', method: 'zapret_status', expect: {} });
const callZapretHostlistGet = rpc.declare({ object: 'campus_redial', method: 'zapret_hostlist_get', expect: {} });
const callZapretHostlistSet = rpc.declare({ object: 'campus_redial', method: 'zapret_hostlist_set', params: [ 'hostlist' ], expect: {} });
const callZapretService = rpc.declare({ object: 'campus_redial', method: 'zapret_service', params: [ 'action' ], expect: {} });
/* 开机自启：只改开机行为（/etc/rc.d/S21zapret 软链），不动当前进程。
 * 参数用字符串 '1'/'0'——LuCI 21.02 的 rpc.js 按位置传参，布尔在某些后端会被拒。 */
const callZapretAutostart = rpc.declare({ object: 'campus_redial', method: 'zapret_autostart', params: [ 'enable' ], expect: {} });

const stateNames = {
	idle: _('空闲'), unavailable: _('后台未启动'), starting: _('正在启动'),
	waiting_network: _('等待网络'), dialing: _('正在拨号'), testing: _('正在检测'),
	redialing: _('正在重拨'), success: _('成功'), failed: _('失败'),
	stopped: _('已停止'), error: _('错误'), up: _('在线'), down: _('离线'),
	busy: _('流量繁忙，检测已挂起')
};

const resultNames = {
	disabled: _('未启用'), waiting: _('等待'), testing: _('检测中'),
	success: _('成功'), failure: _('失败'), failed: _('失败'), unknown: _('未知')
};

const dialNames = {
	 down: _('未连接'), dialing: _('拨号中'), up: _('已连接')
};

const detectionNames = {
	 waiting: _('待检测'), testing: _('检测中'), queued: _('等待检测'),
	 passed: _('检测通过'), failed: _('检测未通过')
};

function text(value, fallback) {
	return value === null || value === undefined || value === '' ? (fallback || '-') : String(value);
}

/* DynamicList hands the empty "add a new item" input to validate() as '',
 * and may pass the whole list joined by whitespace, so accept empties and
 * check each token instead of the raw string. */
function httpListValidator(sid, value) {
	if (value === null || value === undefined || value === '')
		return true;
	const items = String(value).split(/\s+/).filter(v => v !== '');
	if (items.length === 0)
		return true;
	return items.every(item => /^https?:\/\//.test(item)) || _('必须是 HTTP 或 HTTPS 地址');
}

function statusClass(value) {
	if (value === 'success') return 'label notice-success';
	if (value === 'failed' || value === 'failure' || value === 'error') return 'label notice-error';
	if (value === 'testing' || value === 'dialing' || value === 'redialing' || value === 'starting' || value === 'busy') return 'label notice-warning';
	return 'label';
}

function badge(value, names) {
	return E('span', { 'class': statusClass(value) }, text(names[value], value));
}

function metric(label, value) {
	return E('div', { 'style': 'min-width:10rem;padding:.45rem 0' }, [
		E('div', { 'style': 'color:var(--text-color-medium,#666);font-size:.85em' }, label),
		E('strong', { 'style': 'font-size:1.15em' }, text(value, '0'))
	]);
}

/* LuCI 21.02 form.js places the initial `hidden` marker for options with
 * `depends` on the outer <td class="cbi-value-field">, but its own
 * setActive()/isActive() only ever toggle the inner [data-field] div.
 * The stale td.hidden is therefore never removed, so table-section options
 * whose dependency IS satisfied (pool entry details when 启用 is checked)
 * stay invisible in wide layouts; mobile only works because the theme
 * re-lays tables out there. Normalize the marker onto the inner div right
 * before every dependency pass so the stock toggle logic can see and clear
 * it consistently in every layout. */
function fixTableSectionDepends(map) {
	const origCheck = map.checkDepends;
	map.checkDepends = function (ev, depth) {
		const root = this.root || document;
		root.querySelectorAll('td.cbi-value-field.hidden').forEach(td => {
			const holder = td.querySelector('[data-field]');
			if (holder && !holder.classList.contains('hidden')) {
				td.classList.remove('hidden');
				holder.classList.add('hidden');
			}
		});
		return origCheck.call(this, ev, depth);
	};
}

/* SNI desync panel state helpers -------------------------------------- */

const zapretModeNames = {
	tpws: _('tpws（用户态透明代理）'),
	nfqws: _('nfqws（内核队列）'),
	none: _('未安装'),
	unknown: _('未知')
};

function zapretRunningBadge(s) {
	if (!s.installed) return E('span', { 'class': 'label' }, _('未安装'));
	/* s.redirect = 当前模式下流量是否确实被接管：
	 *   nfqws → mangle 上有 NFQUEUE 规则；tpws → nat 上有到 127.0.0.127:988 的跳转。
	 * 旧版后端没有这个字段时按“与 running 一致”处理，避免误报。 */
	const redirect = (s.redirect === undefined) ? !!s.running : !!s.redirect;
	if (s.running && redirect) return E('span', { 'class': 'label notice-success' }, _('运行中'));
	if (s.running) return E('span', { 'class': 'label notice-warning' }, _('运行中（未接管流量）'));
	if (redirect) {
		/* nfqws 的规则带 --queue-bypass，进程没了也不会黑洞；
		 * tpws 的 nat 跳转残留则会让所有网页 connection refused。 */
		if (s.mode === 'nfqws')
			return E('span', { 'class': 'label notice-warning' }, _('已停止（规则残留，不影响上网）'));
		return E('span', { 'class': 'label notice-error', 'style': 'color:#c0392b' }, _('异常：跳转残留'));
	}
	return E('span', { 'class': 'label notice-warning' }, _('已停止（直连）'));
}

function fmtBytes(v) {
	const n = Number(v || 0);
	if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
	if (n >= 1048576) return (n / 1048576).toFixed(2) + ' MB';
	if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
	return String(n) + ' B';
}

return view.extend({
	load() {
		return Promise.all([ callStatus(), callLogs(80), callZapretStatus(), callZapretHostlistGet() ]);
	},

	updateStatus(status, logs) {
		status = status || {};
		logs = logs || {};
		const stats = status.stats || {};
		const last = status.last_run || {};
		setContent(this.overallNode, badge(status.state || 'unavailable', stateNames));
		setContent(this.normalNode, badge(status.normal || 'unknown', resultNames));
		setContent(this.speedNode, [ badge(status.mbps200 || 'unknown', resultNames), ' ', E('span', {}, text(status.speed_mbps, '0') + ' Mbps') ]);
		setContent(this.poolCountNode, [
			_('已连接 %s / %s；检测通过 %s / %s').format(
				text(status.connected_count, '0'), text(status.pool_size, '1'),
				text(status.verified_count, '0'), text(status.pool_size, '1')),
			E('div', { 'style': 'color:var(--text-color-medium,#666);font-size:.9em' },
				_('已连接但尚未通过检测的会话仍可参与分流'))
		]);
		setContent(this.errorNode, text(status.last_error, _('无')));
		setContent(this.updatedNode, text(status.updated_at));
		setContent(this.currentStatsNode, [
			metric(_('拨号尝试'), status.dial_attempts),
			metric(_('失败后重拨'), status.redial_count),
			metric(_('本次成功'), status.run_success),
			metric(_('本次失败'), status.run_failure)
		]);
		setContent(this.lastStatsNode, [
			metric(_('结果'), resultNames[last.result] || last.result),
			metric(_('拨号尝试'), last.dial_attempts),
			metric(_('重拨次数'), last.redial_count),
			metric(_('测速'), text(last.speed_mbps, '0') + ' Mbps')
		]);
		setContent(this.totalStatsNode, [
			metric(_('累计拨号'), stats.dial_attempts),
			metric(_('累计重拨'), stats.redial_count),
			metric(_('成功任务'), stats.success_count),
			metric(_('失败任务'), stats.failure_count),
			metric(_('过点模式通过'), stats.normal_pass_count),
			metric(_('高宽模式通过'), stats.mbps200_pass_count)
		]);
		setContent(this.logNode, text(logs.logs, _('暂无日志')));
		// Per-session table (connection pool): one row per session with its
		// own state, speed and error badge.
		const sessions = Array.isArray(status.sessions) ? status.sessions : [];
		const rows = [];
		(sessions.length ? sessions : []).forEach(s => {
			const accountName = text(s.account_label || s.account, _('未分配'));
			const accountId = s.account ? String(s.account) : '';
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, text(s.name)),
				E('td', { 'class': 'td left' }, accountId && accountId !== accountName ? accountName + ' (' + accountId + ')' : accountName),
				E('td', { 'class': 'td left' }, badge(s.state, stateNames)),
				E('td', { 'class': 'td left' }, badge(s.dial_state, dialNames)),
				E('td', { 'class': 'td left' }, badge(s.detection_state, detectionNames)),
				E('td', { 'class': 'td left' }, badge(s.normal, resultNames)),
				E('td', { 'class': 'td left' }, badge(s.mbps200, resultNames)),
				E('td', { 'class': 'td left' }, text(s.speed_mbps, '0') + ' Mbps'),
				E('td', { 'class': 'td left' }, [
					E('div', {}, _('下行：%s Mbps').format(text(s.rx_mbps, '0'))),
					E('div', {}, _('上行：%s Mbps').format(text(s.tx_mbps, '0'))),
					E('div', {}, _('连接数：%s').format(text(s.connections, '0')))
				]),
				E('td', { 'class': 'td left' }, [
					E('div', {}, _('收：%s MB').format((Number(s.rx_bytes || 0) / 1048576).toFixed(2))),
					E('div', {}, _('发：%s MB').format((Number(s.tx_bytes || 0) / 1048576).toFixed(2)))
				]),
				E('td', { 'class': 'td left' }, [
					E('div', {}, _('拨号/重拨：%s / %s').format(text(s.dial_attempts, '0'), text(s.redial_count, '0'))),
					E('div', {}, _('成功/失败：%s / %s').format(text(s.success_count, '0'), text(s.failure_count, '0'))),
					E('div', {}, _('过点/高宽 通过：%s / %s').format(text(s.normal_pass_count, '0'), text(s.mbps200_pass_count, '0')))
				]),
				E('td', { 'class': 'td left' }, text(s.error, ''))
			]));
		});
		setContent(this.sessionBody, rows);
		if (!status.sessions || !status.sessions.length)
			setContent(this.sessionEmptyNode, E('em', {}, _('后台尚未建立会话')));
		else
			setContent(this.sessionEmptyNode, E('span'));
		this.startButton.disabled = !!status.running;
		this.testButton.disabled = !!status.running;
		this.redialButton.disabled = !!status.running;
		this.stopButton.disabled = !status.running;
	},

	refresh() {
		return Promise.all([ callStatus(), callLogs(80), callZapretStatus() ])
			.then(data => {
				this.updateStatus(data[0], data[1]);
				this.updateZapret(data[2]);
			})
			.catch(err => setContent(this.errorNode, _('无法连接后台：%s').format(err.message)));
	},

	updateZapret(s) {
		s = s || {};
		if (!s.installed) {
			setContent(this.zapretStateNode, E('span', { 'class': 'label' }, _('未安装')));
			setContent(this.zapretHintNode, E('em', {}, _('检测到本机未安装 zapret（/opt/zapret 缺失）。在 PC 上执行 tools/install-sni-desync.sh 可启用 SNI 分流。')));
			if (this.zapretActionsNode) this.zapretActionsNode.style.display = 'none';
			if (this.zapretEditorWrap) this.zapretEditorWrap.style.display = 'none';
			if (this.zapretAutostartRow) this.zapretAutostartRow.style.display = 'none';
			return;
		}
		if (this.zapretAutostartRow) this.zapretAutostartRow.style.display = '';
		/* 开机自启复选框：以服务端返回的 enabled 为准（不要用本地点击后的乐观值，
		 * 否则 rpcd 失败时面板会显示一个“看起来生效其实没生效”的勾）。 */
		if (this.zapretAutostartInput) {
			this.zapretAutostartInput.checked = !!s.enabled;
			this.zapretAutostartInput.disabled = !!this.zapretAutostartBusy;
		}
		if (this.zapretAutostartHintNode) {
			setContent(this.zapretAutostartHintNode, s.enabled
				? _('重启后自动启动；取消勾选不影响当前运行状态')
				: _('重启后不再启动；要立刻停用请点“停止”'));
		}
		const redirect = (s.redirect === undefined) ? !!s.running : !!s.redirect;
		if (this.zapretActionsNode) this.zapretActionsNode.style.display = '';
		if (this.zapretEditorWrap) this.zapretEditorWrap.style.display = '';
		setContent(this.zapretStateNode, [
			zapretRunningBadge(s), ' ',
			E('span', { 'style': 'color:var(--text-color-medium,#666)' },
				_('模式：%s；开机自启：%s；流量接管：%s').format(
					text(zapretModeNames[s.mode], s.mode),
					s.enabled ? _('是') : _('否'),
					redirect ? _('是') : _('否')))
		]);
		const nfqws = (s.mode === 'nfqws');
		const hitPkts  = (s.hit_pkts  !== undefined) ? s.hit_pkts  : s.redirect_pkts;
		const hitBytes = (s.hit_bytes !== undefined) ? s.hit_bytes : s.redirect_bytes;
		const trafficMetrics = [
			metric(nfqws ? _('NFQUEUE 命中包数') : _('DNAT 命中包数'), text(hitPkts, '0')),
			metric(nfqws ? _('NFQUEUE 命中流量') : _('DNAT 命中流量'), fmtBytes(hitBytes)),
			/* 名单为空 = 匹配所有主机（实测语义），不是“没生效” */
			s.hostlist_all
				? metric(_('名单域名数'), _('%s（空 = 全部域名）').format(text(s.hostlist_count, '0')))
				: metric(_('名单域名数'), text(s.hostlist_count, '0'))
		];
		if (nfqws)
			trafficMetrics.push(metric(_('NFQUEUE 规则数'), text(s.nfqueue_rules, '0')));
		setContent(this.zapretTrafficNode, trafficMetrics);
		/* “停止”必须同时停进程和摘掉接管规则，所以只要两者之一还在就该可用。 */
		if (!s.running && redirect) {
			if (nfqws)
				setContent(this.zapretHintNode, E('em', { 'style': 'color:#b8860b' },
					_('nfqws 未运行，但 NFQUEUE 规则还在。规则带 --queue-bypass，不会断网；点“启动”即可恢复。')));
			else
				setContent(this.zapretHintNode, E('em', { 'style': 'color:#c0392b' },
					_('异常：tpws 未运行，但 nat 跳转仍在——所有网页会 connection refused（本面板也会打不开）。点“停止”可立刻摘除跳转、恢复直连。')));
		} else if (!s.running) {
			setContent(this.zapretHintNode, E('em', {},
				s.enabled
					? _('SNI 分流已停止：流量直连，不受分流影响。“停止”只影响本次运行，重启后会按“开机自启”设置恢复。')
					: _('SNI 分流已停止：流量直连，不受分流影响。开机自启也已关闭，重启后不会再启动。')));
		} else if (!redirect) {
			setContent(this.zapretHintNode, E('em', { 'style': 'color:#b8860b' },
				nfqws
					? _('nfqws 在运行，但 mangle 里没有 NFQUEUE 规则——流量没有被接管。点“重启”可重新接管。')
					: _('tpws 在运行但未接管流量（nat 跳转缺失）。点“重启”可重新接管。')));
		} else if (s.hostlist_all) {
			setContent(this.zapretHintNode, E('em', {},
				_('分流已接管 80/443 流量；名单为空时对全部域名生效（每连接只有前几个包进用户态）。')));
		} else {
			setContent(this.zapretHintNode, E('span'));
		}
		this.zapretRestartButton.disabled = false;
		this.zapretStopButton.disabled = !(s.running || redirect);
		this.zapretStartButton.disabled = !!(s.running && redirect);
	},

	saveZapretHostlist() {
		const content = this.zapretEditor.value || '';
		/* LuCI 21.02 rpc.js: declared params are positional — call fn(value),
		 * not fn({key: value}); an object would nest and fail ubus type check. */
		return callZapretHostlistSet(content).then(res => {
			if (res && res.error)
				ui.addNotification(null, E('p', _('保存失败：%s').format(res.error)), 'error');
			else {
				ui.addNotification(null, E('p', _('名单已保存并重启 SNI 分流服务（%s 条域名）').format(text(res.count, '0'))));
				return this.refresh();
			}
		}).catch(err => ui.addNotification(null, E('p', _('保存失败：%s').format(err.message)), 'error'));
	},

	zapretService(action, doneText) {
		return callZapretService(action).then(res => {
			if (res && res.error)
				ui.addNotification(null, E('p', _('操作失败：%s').format(res.error)), 'error');
			else {
				ui.addNotification(null, E('p', doneText));
				/* 后端把“停进程 / 摘 nat 跳转 / 改开机自启”整条序列放到后台执行
				 * （约 1-3s：init 脚本会 fork、还要动 iptables/ipset），所以分两次
				 * 轮询状态，避免只刷一次却读到中间态。 */
				const poll = ms => new Promise(r => window.setTimeout(r, ms)).then(() => this.refresh());
				return poll(1200).then(() => poll(2000));
			}
		}).catch(err => ui.addNotification(null, E('p', _('操作失败：%s').format(err.message)), 'error'));
	},

	/* 开机自启开关。语义与“启动/停止”分离：
	 *   勾选/取消 = 只改 /etc/rc.d/S21zapret（下次开机行为），不动当前进程；
	 *   失败时把复选框状态退回原值，避免显示“已生效”的假象。 */
	setZapretAutostart(enable) {
		if (this.zapretAutostartBusy)
			return Promise.resolve();
		this.zapretAutostartBusy = true;
		if (this.zapretAutostartInput)
			this.zapretAutostartInput.disabled = true;

		const revert = () => {
			this.zapretAutostartBusy = false;
			if (this.zapretAutostartInput) {
				this.zapretAutostartInput.disabled = false;
				this.zapretAutostartInput.checked = !enable;
			}
		};

		return callZapretAutostart(enable ? '1' : '0').then(res => {
			if (res && res.error) {
				revert();
				ui.addNotification(null, E('p', _('设置失败：%s').format(res.error)), 'error');
				return this.refresh();
			}
			this.zapretAutostartBusy = false;
			ui.addNotification(null, E('p', enable
				? _('已设置开机自启：下次开机自动启动 SNI 分流（当前运行状态不变）')
				: _('已取消开机自启：重启后不再自动启动（当前运行状态不变）')));
			return this.refresh();
		}).catch(err => {
			revert();
			ui.addNotification(null, E('p', _('设置失败：%s').format(err.message)), 'error');
		});
	},

	runAction(call, successText) {
		return call().then(() => {
			ui.addNotification(null, E('p', successText));
			return new Promise(resolve => window.setTimeout(resolve, 350)).then(() => this.refresh());
		}).catch(err => ui.addNotification(null, E('p', _('操作失败：%s').format(err.message))));
	},

	render(data) {
		this.overallNode = E('span');
		this.normalNode = E('span');
		this.speedNode = E('span');
		this.poolCountNode = E('span');
		this.errorNode = E('span');
		this.updatedNode = E('span');
		this.currentStatsNode = E('div', { 'style': 'display:flex;gap:2rem;flex-wrap:wrap' });
		this.lastStatsNode = E('div', { 'style': 'display:flex;gap:2rem;flex-wrap:wrap' });
		this.totalStatsNode = E('div', { 'style': 'display:flex;gap:2rem;flex-wrap:wrap' });
		this.logNode = E('pre', { 'style': 'max-height:18rem;overflow:auto;white-space:pre-wrap' });
		this.sessionBody = E('tbody');
		this.sessionEmptyNode = E('span');

		// SNI desync (zapret) panel nodes
		this.zapretStateNode = E('span');
		this.zapretHintNode = E('div', { 'style': 'margin:.3rem 0' });
		this.zapretTrafficNode = E('div', { 'style': 'display:flex;gap:2rem;flex-wrap:wrap' });
		this.zapretEditor = E('textarea', {
			'rows': 8,
			'style': 'width:100%;max-width:36rem;font-family:monospace',
			'placeholder': _('每行一个域名，支持 .example.com 后缀形式；# 开头为注释')
		});
		this.zapretEditor.value = (data && data[3] && data[3].hostlist) ? data[3].hostlist : '';
		this.zapretEditorWrap = E('div', {});
		this.zapretRestartButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => this.zapretService('restart', _('SNI 分流服务已重启')))
		}, _('重启服务'));
		this.zapretStopButton = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(this, () => this.zapretService('stop', _('SNI 分流服务已停止')))
		}, _('停止'));
		this.zapretStartButton = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(this, () => this.zapretService('start', _('SNI 分流服务已启动')))
		}, _('启动'));
		const zapretSaveButton = E('button', {
			'class': 'cbi-button cbi-button-important',
			'click': ui.createHandlerFn(this, () => this.saveZapretHostlist())
		}, _('保存名单并生效'));
		/* 开机自启：与“启动/停止”刻意分离——只决定下次开机是否自动拉起，
		 * 不动当前进程。改的是一个软链，很快，所以即时生效，不走“保存名单”流程。 */
		this.zapretAutostartInput = E('input', {
			'id': 'cr-zapret-autostart',
			'type': 'checkbox',
			'change': ui.createHandlerFn(this, ev => this.setZapretAutostart(ev.target.checked))
		});
		this.zapretAutostartHintNode = E('span', {
			'style': 'margin-left:.6rem;color:var(--text-color-medium,#666);font-size:90%'
		});
		this.zapretAutostartCell = E('span', {}, [
			E('label', { 'for': 'cr-zapret-autostart', 'style': 'cursor:pointer;user-select:none' },
				[ this.zapretAutostartInput, ' ', _('开机自动启动 SNI 分流') ]),
			this.zapretAutostartHintNode
		]);
		this.zapretActionsNode = E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;flex-wrap:wrap' }, [
			this.zapretStartButton, this.zapretStopButton, this.zapretRestartButton, zapretSaveButton
		]);

		this.startButton = E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, () => this.runAction(callStart, _('自动重拨已启动'))) }, _('启动'));
		this.stopButton = E('button', { 'class': 'cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, () => this.runAction(callStop, _('已请求停止'))) }, _('停止'));
		this.testButton = E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, () => this.runAction(callTest, _('当前出口检测已启动'))) }, _('测试当前出口'));
		this.redialButton = E('button', { 'class': 'cbi-button cbi-button-positive', 'click': ui.createHandlerFn(this, () => this.runAction(callRedial, _('单次重拨已启动'))) }, _('立即重拨一次'));
		const clearButton = E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, () => this.runAction(callClear, _('累计统计已清空'))) }, _('清空统计'));

		const statusPanel = E('div', {}, [
			E('h2', _('运行状态')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '25%' }, _('进程')), E('td', { 'class': 'td left' }, this.overallNode) ]),
				E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('过点模式')), E('td', { 'class': 'td left' }, this.normalNode) ]),
				E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('高宽模式')), E('td', { 'class': 'td left' }, this.speedNode) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('连接池状态（连接/检测）')), E('td', { 'class': 'td left' }, this.poolCountNode) ]),
				E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('最后错误')), E('td', { 'class': 'td left' }, this.errorNode) ]),
				E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('更新时间')), E('td', { 'class': 'td left' }, this.updatedNode) ])
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5rem;flex-wrap:wrap' }, [ this.startButton, this.stopButton, this.testButton, this.redialButton, clearButton ]),
			E('h3', _('连接池会话')),
			E('p', {}, this.sessionEmptyNode),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, _('会话')),
					E('th', { 'class': 'th left' }, _('认证账号')),
					E('th', { 'class': 'th left' }, _('状态')),
					E('th', { 'class': 'th left' }, _('拨号连接')),
					E('th', { 'class': 'th left' }, _('检测状态')),
					E('th', { 'class': 'th left' }, _('过点模式')),
					E('th', { 'class': 'th left' }, _('高宽')),
					E('th', { 'class': 'th left' }, _('测速')),
					E('th', { 'class': 'th left' }, _('实时流量/连接')),
					E('th', { 'class': 'th left' }, _('累计流量')),
					E('th', { 'class': 'th left' }, _('会话统计')),
					E('th', { 'class': 'th left' }, _('错误'))
				]) ]),
				this.sessionBody
			]),
			E('h3', _('本次运行')), this.currentStatsNode,
			E('h3', _('最近一次任务')), this.lastStatsNode,
			E('h3', _('累计统计')), this.totalStatsNode
		]);

		const zapretPanel = E('div', {}, [
			E('h2', _('SNI 分流（解除域名限速）')),
			E('p', { 'style': 'color:var(--text-color-medium,#666)' },
				_('对名单内域名的 HTTPS 连接做 ClientHello 分片，使校园网 DPI 读不到 SNI，流量回到默认不限速类。名单外流量不受影响。')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '25%' }, _('服务状态')), E('td', { 'class': 'td left' }, this.zapretStateNode) ]),
				this.zapretAutostartRow = E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('开机自启')), E('td', { 'class': 'td left' }, this.zapretAutostartCell) ])
			]),
			this.zapretHintNode,
			this.zapretTrafficNode,
			this.zapretActionsNode,
			E('h3', _('域名名单')),
			this.zapretEditorWrap.appendChild(this.zapretEditor),
			E('p', { 'style': 'color:var(--text-color-medium,#666)' },
				_('保存后自动重启 SNI 分流服务。只影响名单内域名；清空名单等于暂停分流（不拦任何流量）。'))
		]);

		let map = new form.Map('campus-redial', _('配置'));
		fixTableSectionDepends(map);
		let section = map.section(form.NamedSection, 'main', 'campus_redial');
		section.anonymous = true;
		let option = section.option(form.Flag, 'enabled', _('开机自动运行'));
		option.rmempty = false;
		option = section.option(form.Value, 'wan_interface', _('PPPoE 逻辑接口'));
		option.default = 'wan'; option.rmempty = false; option.datatype = 'uciname';
		option = section.option(form.Value, 'wan_device', _('PPPoE 下层设备'));
		option.placeholder = _('留空时读取 network.wan.device');
		option = section.option(form.Value, 'pppoe_username', _('校园网账号'));
		option.rmempty = false;
		option = section.option(form.Value, 'pppoe_password', _('校园网密码'));
		option.password = true; option.rmempty = false;
		option = section.option(form.Value, 'pool_size', _('旧版单账号会话数（多账号时忽略）'));
		option.default = '1'; option.datatype = 'range(1,24)';
		option = section.option(form.Flag, 'pool_keepalive', _('持续维护连接池'));
		option.default = '1'; option.rmempty = false;
		option = section.option(form.Value, 'auth_interval_seconds', _('认证最小间隔（秒，多拨推荐 60）'));
		option.default = '60'; option.datatype = 'range(1,600)';
		option = section.option(form.Value, 'busy_threshold_kbytes', _('大流量挂起阈值（KB/s，0=禁用）'));
		option.default = '0'; option.datatype = 'range(0,100000000)';
		option = section.option(form.Flag, 'normal_enabled', _('过点模式'));
		option.rmempty = false; option.default = '1';
		option = section.option(form.Flag, 'mbps200_enabled', _('高宽模式'));
		option.rmempty = false; option.default = '1';
		option = section.option(form.DynamicList, 'probe_uri', _('过点模式探针'));
		option.rmempty = false;
		option.validate = httpListValidator;
		option = section.option(form.Value, 'timeout_seconds', _('探测超时（秒）'));
		option.default = '4'; option.datatype = 'range(1,60)';
		option = section.option(form.Value, 'probe_count', _('每个探针每轮次数'));
		option.default = '3'; option.datatype = 'range(1,10)';
		option = section.option(form.Value, 'confirm_interval_seconds', _('第一轮确认间隔（秒）'));
		option.default = '12'; option.datatype = 'range(0,300)';
		option = section.option(form.Value, 'third_interval_seconds', _('第三轮确认间隔（秒）'));
		option.default = '30'; option.datatype = 'range(0,600)';
		option = section.option(form.Value, 'bandwidth_test_uri', _('测速地址'));
		option.rmempty = false; option.validate = httpListValidator;
		option = section.option(form.Value, 'bandwidth_test_seconds', _('测速时长（秒）'));
		option.default = '5'; option.datatype = 'range(1,30)';
		option = section.option(form.Value, 'bandwidth_threshold_mbps', _('通过阈值（Mbps）'));
		option.default = '150'; option.datatype = 'ufloat';
		option = section.option(form.Value, 'settle_seconds', _('拨号稳定等待（秒）'));
		option.default = '10'; option.datatype = 'range(0,300)';
		option = section.option(form.Value, 'pause_seconds', _('失败暂停（秒）'));
		option.default = '2'; option.datatype = 'range(1,600)';
		option = section.option(form.Value, 'max_attempts', _('最大拨号次数'));
		option.default = '99'; option.datatype = 'range(1,99)';

		let accounts = map.section(form.TableSection, 'account', _('多账号连接池'));
		accounts.addremove = true;
		accounts.anonymous = false;
		accounts.sortable = true;
		accounts.nodescriptions = true;
		option = accounts.option(form.Flag, 'enabled', _('启用'));
		option.default = '1'; option.rmempty = false;
		option = accounts.option(form.Value, 'label', _('显示名称'));
		option.placeholder = _('例如：主账号');
		option.depends('enabled', '1');
		option = accounts.option(form.Value, 'username', _('PPPoE 账号'));
		option.depends('enabled', '1'); option.rmempty = false;
		option = accounts.option(form.Value, 'password', _('PPPoE 密码'));
		option.password = true; option.depends('enabled', '1'); option.rmempty = false;
		option = accounts.option(form.Value, 'max_connections', _('最大连接数'));
		option.default = '1'; option.datatype = 'range(1,24)'; option.depends('enabled', '1');

		this.updateStatus(data[0], data[1]);
		this.updateZapret(data[2]);
		L.Poll.add(L.bind(this.refresh, this), 2);
		return map.render().then(formNode => E('div', {}, [
			E('h1', _('校园网自动重拨和集流')),
			statusPanel,
			formNode,
			zapretPanel,
			E('h2', _('最近日志')),
			this.logNode
		]));
	}
});

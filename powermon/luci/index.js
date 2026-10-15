'use strict';
'require view';
'require fs';
'require poll';
'require ui';

// 功率监测 (the powermon info screen app): the samples its service writes to
// /tmp/powermon/samples.csv -- time,current_ma,voltage_mv,power_mw,plugged,
// screen,hotspot,saver,battery -- as a chart, averages by state, and CSV.
// Read with fs.read_direct (cgi-download: the file can pass ubus's size limit).

const CSV = '/tmp/powermon/samples.csv';
const HEADER = 'time,current_ma,voltage_mv,power_mw,plugged,screen,hotspot,saver,battery';
const RANGES = [[3600, '1 小时'], [6 * 3600, '6 小时'], [24 * 3600, '24 小时'], [0, '全部']];
const STRIPS = [
	['screen', '屏幕亮', 'rgba(230,180,40,.85)'],
	['hotspot', '热点开', 'rgba(60,140,230,.85)'],
	['saver', '省电', 'rgba(60,180,110,.85)'],
	['plugged', '插电', 'rgba(150,150,150,.85)']
];

function parse(text) {
	const out = [];
	for (const line of (text || '').split('\n')) {
		const f = line.split(',');
		if (f.length < 9 || !/^\d+$/.test(f[0])) continue;
		out.push({ t: +f[0], ma: +f[1], mv: +f[2], mw: +f[3], plugged: f[4] == '1',
			screen: f[5] == '1', hotspot: f[6] == '1', saver: f[7] == '1', battery: f[8] === '' ? null : +f[8] });
	}
	return out;
}

// a sample's weight in seconds: the gap to the next one, at most 3 typical gaps
function weights(s) {
	const gaps = [];
	for (let i = 1; i < s.length; i++) gaps.push(s[i].t - s[i - 1].t);
	const typical = gaps.length ? gaps.slice().sort((a, b) => a - b)[gaps.length >> 1] || 10 : 10;
	return { typical, w: s.map((x, i) => i + 1 < s.length ? Math.min(s[i + 1].t - x.t, typical * 3) : typical) };
}

function stateName(x) {
	return [x.screen ? '亮屏' : '熄屏', x.hotspot ? '热点开' : '热点关', x.saver ? '省电生效' : '省电未生效'].join(' · ');
}

function fmtDur(s) {
	s = Math.round(s);
	if (s < 60) return s + ' 秒';
	if (s < 3600) return Math.round(s / 60) + ' 分钟';
	return (s / 3600).toFixed(1) + ' 小时';
}

function fmtTime(t, withDate) {
	const d = new Date(t * 1000), p = (n) => String(n).padStart(2, '0');
	return (withDate ? (d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' : '') + p(d.getHours()) + ':' + p(d.getMinutes());
}

// now as 20261015-1224, for file names
function stamp() {
	const d = new Date(), p = (n) => String(n).padStart(2, '0');
	return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes());
}

function download(name, text) {
	const a = E('a', { href: URL.createObjectURL(new Blob([text], { type: 'text/csv' })), download: name });
	document.body.appendChild(a);
	a.click();
	setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

return view.extend({
	range: 3600,
	samples: [],
	designMah: null,

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read_direct(CSV, 'text'), ''),
			L.resolveDefault(fs.read('/sys/class/power_supply/battery/charge_full_design'), ''),
			L.resolveDefault(fs.read('/sys/class/power_supply/battery/charge_full'), '')
		]);
	},

	shown: function() {
		if (!this.samples.length) return [];
		const end = this.samples[this.samples.length - 1].t;
		return this.range ? this.samples.filter((x) => x.t > end - this.range) : this.samples;
	},

	drawChart: function() {
		const canvas = this.canvas, s = this.shown();
		const css = getComputedStyle(canvas.parentNode);
		const W = canvas.parentNode.clientWidth || 800, H = 320, dpr = window.devicePixelRatio || 1;
		canvas.width = W * dpr; canvas.height = H * dpr;
		canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
		const g = canvas.getContext('2d');
		g.setTransform(dpr, 0, 0, dpr, 0, 0);
		g.clearRect(0, 0, W, H);
		const ink = css.color || '#888';
		g.font = '12px sans-serif';
		if (s.length < 2) {
			g.fillStyle = ink;
			g.fillText('数据还不够：采样开始后过一会儿再看。', 20, 40);
			this.layout = null;
			return;
		}
		const L0 = 60, R0 = 12, T0 = 10, stripH = 11, stripGap = 5;
		const stripsTop = H - 22 - STRIPS.length * (stripH + stripGap);
		const B0 = stripsTop - 26;
		const t0 = s[0].t, t1 = s[s.length - 1].t;
		const used = s.filter((x) => !x.plugged).map((x) => x.mw).sort((a, b) => a - b);
		const all = s.map((x) => x.mw).sort((a, b) => a - b);
		const ref = used.length ? used : all;
		let top = Math.max(100, ref[Math.min(ref.length - 1, Math.floor(ref.length * 0.99))] * 1.15);
		const step = [50, 100, 200, 250, 500, 1000, 2000, 5000].find((v) => top / v <= 6) || 10000;
		top = Math.ceil(top / step) * step;
		// (plugged samples -- charging, negative -- are drawn clipped: they set no scale)
		const bottom = Math.min(0, Math.floor((used.length ? used[0] : 0) / step) * step);
		const X = (t) => L0 + (t - t0) / Math.max(1, t1 - t0) * (W - L0 - R0);
		const Y = (v) => T0 + (top - Math.max(bottom, Math.min(top, v))) / (top - bottom) * (B0 - T0);
		this.layout = { X, t0, t1, L0, R0, W, s };

		// grid and axes
		g.strokeStyle = 'rgba(128,128,128,.25)'; g.fillStyle = ink; g.lineWidth = 1;
		for (let v = bottom; v <= top; v += step) {
			g.beginPath(); g.moveTo(L0, Y(v) + .5); g.lineTo(W - R0, Y(v) + .5); g.stroke();
			g.fillText(v >= 1000 ? (v / 1000) + ' W' : v + ' mW', 4, Y(v) + 4);
		}
		const span = t1 - t0, withDate = span > 20 * 3600;
		const fit = Math.max(2, Math.floor((W - L0 - R0) / (withDate ? 95 : 55)));
		const tstep = [300, 600, 1800, 3600, 7200, 3 * 3600, 6 * 3600, 12 * 3600, 86400].find((v) => span / v <= fit) || 86400;
		for (let t = Math.ceil(t0 / tstep) * tstep; t <= t1; t += tstep) {
			g.beginPath(); g.moveTo(X(t) + .5, T0); g.lineTo(X(t) + .5, B0); g.stroke();
			const label = fmtTime(t, withDate);
			g.fillText(label, Math.min(W - R0 - g.measureText(label).width, Math.max(L0, X(t) - g.measureText(label).width / 2)), B0 + 16);
		}

		// the state strips under the chart
		const { w, typical } = weights(s);
		STRIPS.forEach(([key, label, color], k) => {
			const y = stripsTop + k * (stripH + stripGap);
			g.fillStyle = 'rgba(128,128,128,.12)'; g.fillRect(L0, y, W - L0 - R0, stripH);
			g.fillStyle = color;
			s.forEach((x, i) => { if (x[key]) g.fillRect(X(x.t), y, Math.max(1, X(x.t + w[i]) - X(x.t)), stripH); });
			g.fillStyle = ink; g.fillText(label, 4, y + stripH - 1);
		});

		// the power line: broken at gaps; plugged samples grey
		g.lineWidth = 1.5;
		let prev = null;
		for (const x of s) {
			if (prev && x.t - prev.t <= typical * 3) {
				g.strokeStyle = (x.plugged || prev.plugged) ? 'rgba(150,150,150,.8)' : 'rgb(220,70,60)';
				g.beginPath(); g.moveTo(X(prev.t), Y(prev.mw)); g.lineTo(X(x.t), Y(x.mw)); g.stroke();
			}
			prev = x;
		}
	},

	pointAt: function(ev) {
		const l = this.layout;
		if (!l) return;
		const r = this.canvas.getBoundingClientRect();
		const t = l.t0 + (ev.clientX - r.left - l.L0) / (l.W - l.L0 - l.R0) * (l.t1 - l.t0);
		let best = null;
		for (const x of l.s) if (!best || Math.abs(x.t - t) < Math.abs(best.t - t)) best = x;
		if (!best) return;
		this.hover.textContent = fmtTime(best.t, true) + '  ' + best.mw + ' mW  ' + best.ma + ' mA  ' +
			(best.mv / 1000).toFixed(2) + ' V  ' + (best.battery != null ? best.battery + '%  ' : '') +
			stateName(best) + (best.plugged ? '  插电' : '');
	},

	renderStats: function() {
		const s = this.shown();
		const { w } = weights(s);
		const groups = {}, total = { sec: 0, mws: 0, mas: 0 };
		s.forEach((x, i) => {
			if (x.plugged) return;
			const k = stateName(x);
			const gr = groups[k] = groups[k] || { sec: 0, mws: 0, mas: 0, min: Infinity, max: -Infinity };
			gr.sec += w[i]; gr.mws += x.mw * w[i]; gr.mas += -x.ma * w[i];
			gr.min = Math.min(gr.min, x.mw); gr.max = Math.max(gr.max, x.mw);
			total.sec += w[i]; total.mws += x.mw * w[i]; total.mas += -x.ma * w[i];
		});
		const life = (ma) => this.designMah && ma > 0 ? (this.designMah / ma).toFixed(1) + ' 小时' : '—';
		const rows = Object.keys(groups).sort((a, b) => groups[a].mws / groups[a].sec - groups[b].mws / groups[b].sec).map((k) => {
			const gr = groups[k], mw = gr.mws / gr.sec, ma = gr.mas / gr.sec;
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, k), E('td', { 'class': 'td' }, fmtDur(gr.sec)),
				E('td', { 'class': 'td' }, E('strong', {}, Math.round(mw) + ' mW')),
				E('td', { 'class': 'td' }, Math.round(ma) + ' mA'),
				E('td', { 'class': 'td' }, gr.min + ' – ' + gr.max + ' mW'),
				E('td', { 'class': 'td' }, life(ma))
			]);
		});
		if (total.sec > 0)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('em', {}, '全部（不含插电）')), E('td', { 'class': 'td' }, fmtDur(total.sec)),
				E('td', { 'class': 'td' }, Math.round(total.mws / total.sec) + ' mW'),
				E('td', { 'class': 'td' }, Math.round(total.mas / total.sec) + ' mA'),
				E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, life(total.mas / total.sec))
			]));
		const head = E('tr', { 'class': 'tr table-titles' }, ['状态', '时长', '平均功率', '平均电流', '范围', '满电可用'].map((h) => E('th', { 'class': 'th' }, h)));
		const table = E('table', { 'class': 'table' }, [head].concat(rows.length ? rows :
			[E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', colspan: 6 }, '这段时间没有未插电的数据：拔掉 USB 线才能测出耗电。'))]));
		this.stats.replaceChildren(table);
	},

	renderNow: function() {
		const x = this.samples[this.samples.length - 1];
		if (!x) { this.now.textContent = '还没有数据：功率监测应用装好后，后台服务每 10 秒采样一次。'; return; }
		const recent = this.samples.filter((y) => y.t > x.t - 300 && !y.plugged);
		const avg = recent.length ? Math.round(recent.reduce((a, y) => a + y.mw, 0) / recent.length) : null;
		this.now.replaceChildren(
			E('strong', { style: 'font-size:1.6em' }, x.mw + ' mW'), '  ',
			x.ma + ' mA · ' + (x.mv / 1000).toFixed(2) + ' V · ' + (x.battery != null ? x.battery + '% · ' : '') +
			stateName(x) + (x.plugged ? ' · 插电（读数是充电减耗电，不代表耗电）' : '') +
			(avg != null ? ' · 最近 5 分钟平均 ' + avg + ' mW' : '') + ' · ' + fmtTime(x.t, true));
	},

	refresh: function() {
		return L.resolveDefault(fs.read_direct(CSV, 'text'), '').then((text) => {
			this.samples = parse(text);
			this.renderNow(); this.drawChart(); this.renderStats();
		});
	},

	render: function(data) {
		this.samples = parse(data[0]);
		const uah = parseInt((data[1] || data[2] || '').trim());
		this.designMah = uah > 0 ? Math.round(uah / 1000) : null;

		this.now = E('div', { style: 'margin:.5em 0 1em' });
		this.canvas = E('canvas', { style: 'display:block;cursor:crosshair' });
		this.hover = E('div', { 'class': 'cbi-value-description', style: 'min-height:1.4em' }, '把鼠标移到曲线上看某一时刻的数值。');
		this.stats = E('div');
		this.canvas.addEventListener('mousemove', (ev) => this.pointAt(ev));

		const buttons = RANGES.map(([sec, label]) => E('button', {
			'class': 'cbi-button' + (sec == this.range ? ' cbi-button-action' : ''),
			click: (ev) => {
				this.range = sec;
				ev.target.parentNode.querySelectorAll('button').forEach((b) => b.classList.remove('cbi-button-action'));
				ev.target.classList.add('cbi-button-action');
				this.drawChart(); this.renderStats();
			}
		}, label));

		const exportRange = E('button', { 'class': 'cbi-button cbi-button-save', click: () => {
			const s = this.shown();
			download('powermon-' + stamp() + '.csv',
				HEADER + '\n' + s.map((x) => [x.t, x.ma, x.mv, x.mw, +x.plugged, +x.screen, +x.hotspot, +x.saver, x.battery ?? ''].join(',')).join('\n') + '\n');
		} }, '导出当前范围 CSV');
		const exportAll = E('button', { 'class': 'cbi-button', click: () => {
			L.resolveDefault(fs.read_direct(CSV, 'text'), '').then((text) => download('powermon-all-' + stamp() + '.csv', HEADER + '\n' + text));
		} }, '导出全部 CSV');
		const clear = E('button', { 'class': 'cbi-button cbi-button-negative', click: () => {
			if (!confirm('清空所有功率记录？')) return;
			fs.write(CSV, '').then(() => this.refresh()).catch((e) => ui.addNotification(null, E('p', e.message)));
		} }, '清空数据');

		window.addEventListener('resize', () => this.drawChart());
		poll.add(() => this.refresh(), 30);
		requestAnimationFrame(() => { this.drawChart(); this.renderStats(); });
		this.renderNow();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '功率监测'),
			E('div', { 'class': 'cbi-map-descr' },
				'电池电量计读出的整机耗电（电流 × 电压），后台每 10 秒记录一次，存在内存里，最多约 3 天，重启后清空。' +
				'插着 USB / 电源时读数是“充电减耗电”，不代表耗电：这些数据在图上为灰色，也不计入平均值——要测耗电请拔掉线。'),
			this.now,
			E('div', { style: 'margin-bottom:.5em' }, buttons),
			E('div', { 'class': 'cbi-section' }, [this.canvas, this.hover]),
			E('h3', {}, '各状态平均功率（所选范围，不含插电）'),
			this.stats,
			E('div', { 'class': 'cbi-value-description' }, this.designMah ?
				'“满电可用”按电池设计容量 ' + this.designMah + ' mAh ÷ 平均电流估算，未计电池老化和低电量截止。' :
				'读不到电池容量，不估算续航。'),
			E('div', { style: 'margin-top:1em' }, [exportRange, ' ', exportAll, ' ', clear])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

// 功率监测 (Power Monitor, id powermon): the app's backend.  The sampling
// runs in the background (service.sh under /etc/init.d/powermon, into
// /tmp/powermon/samples.csv); this installs that service and the LuCI page
// (状态 -> 功率监测: the chart, averages by state, CSV), keeps them installed
// -- an image update brings neither; the notification poll puts them back --
// and serves the app's page on the screen.
//
//   GET  /status          the newest sample, the use and the charge over the
//                         last 30 min, 6 h and 24 h, averages by state, the
//                         charging session
//   GET  /notifications   (none: only the install check, once a minute)
//
// Plugged in, the gauge reads what goes into the battery, not the device's
// use: those samples are not in the averages, they are the charging -- a
// sample's kind (kind()): battery, charging (current in), full (about none),
// drain (plugged, and the battery still giving: the charger short of the use).
//
// Suspended (deep sleep), no samples are taken: the sample after a wake says
// how long (its `sleep`, s), and the use across the gap is what the gauge's
// own charge (`fgu`, 0.1 %: its coulomb counter goes on in suspend) lost --
// one step is 3 mAh, so a short sleep is not measured by itself: the sleeps
// are added up (the averages' 深度休眠), and one gets its own figure from
// SLEEP_OWN s on.  Rows from v1.1 have neither: their gaps stay gaps.

'use strict';

import { readfile, writefile } from 'fs';

const DIR = '/etc/e5-infoscreen/plugins/powermon';
const INIT = '/etc/init.d/powermon';
const CSV = '/tmp/powermon/samples.csv';
const BAT = '/sys/class/power_supply/battery';
// plugged, a current this close to 0 (mA) is a full battery held, not charging
const HOLD_MA = 15;
// a sleep this long (s) is measured by itself; shorter ones get the average of all
const SLEEP_OWN = 1800;
// the sleeps' average is given from this much sleep (s) on
const SLEEP_MIN = 600;
// the charts' ranges (s) and points per range (about the screen's width)
const CHART_SPANS = [ 1800, 6 * 3600, 24 * 3600 ];
const CHART_POINTS = 240;
// the app's file -> where it goes
const FILES = [
	[ 'powermon.init', INIT, true ],
	[ 'luci/index.js', '/www/luci-static/resources/view/powermon/index.js', false ],
	[ 'luci/menu.json', '/usr/share/luci/menu.d/luci-app-powermon.json', false ],
	[ 'luci/acl.json', '/usr/share/rpcd/acl.d/luci-app-powermon.json', false ]
];

return function(ctx) {
	function running() {
		let s = ctx.ubus('service', 'list', { name: 'powermon' })?.['powermon'];
		for (let name, inst in (s?.instances ?? {}))
			if (inst?.running) return true;
		return false;
	}

	// the service and the LuCI page as this version of the app has them
	function ensure_installed() {
		let changed_init = false, changed_luci = false;
		for (let f in FILES) {
			let want = readfile(`${DIR}/${f[0]}`);
			if (want == null) return false;        // not an installed app
			if (readfile(f[1]) == want) continue;
			ctx.run(`mkdir -p "$(dirname '${f[1]}')"`);
			writefile(f[1] + '.new', want);
			ctx.run(`chmod ${f[2] ? 755 : 644} '${f[1]}.new' && mv -f '${f[1]}.new' '${f[1]}'`);
			if (f[2]) changed_init = true; else changed_luci = true;
		}
		if (changed_luci) {
			// (LuCI's menu and the session ACLs are cached)
			ctx.run('rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache; /etc/init.d/rpcd reload >/dev/null 2>&1');
			ctx.log('LuCI page installed: 状态 -> 功率监测');
		}
		if (changed_init) {
			ctx.run(`'${INIT}' enable; '${INIT}' restart >/dev/null 2>&1`);
			ctx.log('sampler installed');
		}
		else if (!running())
			ctx.run(`'${INIT}' enable; '${INIT}' start >/dev/null 2>&1`);
		// (a reinstalled app: service.sh changed under the running one)
		else if (readfile(`${DIR}/service.sh`) != readfile('/var/run/powermon.running'))
			ctx.run(`'${INIT}' restart >/dev/null 2>&1`);
		return running();
	}

	// the samples of the last `span` seconds (the file's tail is enough)
	function samples(span) {
		let text = readfile(CSV) ?? '';
		let lines = split(trim(text), '\n'), out = [];
		if (!length(lines) || lines[0] == '') return out;
		let last = split(lines[length(lines) - 1], ',');
		let end = +last[0];
		for (let i = length(lines) - 1; i >= 0; i--) {
			let f = split(lines[i], ',');
			if (length(f) < 9) continue;
			let t = +f[0];
			if (t <= end - span) break;
			unshift(out, { t, ma: +f[1], mv: +f[2], mw: +f[3], plugged: f[4] == '1',
				screen: f[5] == '1', hotspot: f[6] == '1', saver: f[7] == '1',
				battery: f[8] == '' ? null : +f[8],
				fgu: (f[9] ?? '') == '' ? null : +f[9], sleep: +(f[10] ?? 0) });
		}
		return out;
	}

	function state_key(x) {
		return (x.screen ? 'lit' : 'dark') + '_' + (x.hotspot ? 'on' : 'off') + '_' + (x.saver ? 'saver' : 'plain');
	}

	function kind(x) {
		if (!x.plugged) return 'battery';
		if (x.ma > HOLD_MA) return 'charging';
		if (x.ma < -HOLD_MA) return 'drain';
		return 'full';
	}

	// the battery's capacity, mAh (the gauge's full charge, else its design)
	function capacity_mah() {
		for (let f in [ 'charge_full', 'charge_full_design' ]) {
			let v = +trim(readfile(`${BAT}/${f}`) ?? '');
			if (v > 0) return int(v / 1000);
		}
		return null;
	}

	// the sleeps in `day`: the gaps closed by a sample after a wake (`sleep`
	// > 0) from an unplugged one, with the gauge's charge lost across them
	// (mAh; null without the gauge), and their average.  Each gets an mw: its
	// own from SLEEP_OWN s on, else the average's (null under SLEEP_MIN s).
	// (ucode divides integers as integers: the .0)
	function sleeps(day) {
		let cap = capacity_mah(), out = [], sec = 0, mah = 0, mwh = 0, msec = 0;
		for (let i = 1; i < length(day); i++) {
			let a = day[i - 1], b = day[i];
			if (!(b.sleep > 0) || a.plugged) continue;
			let z = { i, from: a.t, to: b.t, slept: b.sleep, mah: null, mw: null };
			if (cap && a.fgu != null && b.fgu != null) {
				let d = b.t - a.t, v = (a.mv + b.mv) / 2000.0;
				z.mah = (a.fgu - b.fgu) * cap / 1000.0;
				if (d >= SLEEP_OWN) z.mw = max(0, int(z.mah * v * 3600 / d));
				msec += d; mah += z.mah; mwh += z.mah * v;
			}
			sec += b.t - a.t;
			push(out, z);
		}
		let avg = (msec >= SLEEP_MIN) ? { mw: max(0, int(mwh * 3600 / msec)), ma: max(0, int(mah * 3600 / msec)) } : null;
		for (let z in out)
			if (z.mw == null && avg) z.mw = avg.mw;
		return { list: out, sec, msec, avg };
	}

	// the charts of the last `span` s: the time from..to (from the first
	// sample on), the use and the charge in at most CHART_POINTS steps --
	// [ t, mw, plugged, % ]: a step's newest time and %, the mean use of its
	// unplugged samples (null with none), plugged if any was -- and the sleeps,
	// cut to it: [ from, to, mw ].  (The % the status bar has, not the gauge's
	// 0.1 %: v1.1's rows have only that, and the two differ by a % or two.)
	function chart(day, sl, now, span) {
		let start = now.t - span, from = null, pts = [], cur = null, k = -1, sum = 0, cnt = 0;
		let width = span / (CHART_POINTS * 1.0);
		for (let x in day) {
			if (x.t <= start) continue;
			if (from == null) from = x.t;
			let b = int((x.t - start) / width);
			if (b != k) {
				if (cur) cur[1] = cnt ? int(sum / cnt) : null;
				k = b; sum = 0; cnt = 0;
				push(pts, cur = [ x.t, null, false, null ]);
			}
			cur[0] = x.t;
			if (x.plugged) cur[2] = true;
			else { sum += x.mw; cnt++; }
			if (x.battery != null) cur[3] = x.battery;
		}
		if (cur) cur[1] = cnt ? int(sum / cnt) : null;
		let naps = [];
		for (let z in sl.list)
			if (z.to > start) {
				from = min(from ?? z.from, max(z.from, start));
				push(naps, [ max(z.from, start), z.to, z.mw ]);
			}
		return { from: from ?? now.t, to: now.t, width: int(width), pts, naps };
	}

	// the newest run of plugged samples (gaps up to 3 min) in `day`: the one
	// going on, else the last one
	function session(day, now) {
		let n = length(day), i = n - 1;
		while (i >= 0 && !day[i].plugged) i--;
		if (i < 0) return null;
		let end = i, start = i;
		while (start > 0 && day[start - 1].plugged && day[start].t - day[start - 1].t <= 180) start--;
		let sec = 0, mws = 0, mas = 0, csec = 0;
		for (let k = start; k <= end; k++) {
			let x = day[k];
			let w = (k < end) ? min(day[k + 1].t - x.t, 60) : 10;
			sec += w;
			if (kind(x) == 'charging') { csec += w; mws += -x.mw * w; mas += x.ma * w; }
		}
		let a = day[start], b = day[end];
		let r = {
			active: end == n - 1, start: a.t, end: b.t, minutes: int((b.t - a.t) / 60),
			from: a.battery, to: b.battery,
			charging_minutes: int(csec / 60),
			mw: csec ? int(mws / csec) : null, ma: csec ? int(mas / csec) : null,
			pct_per_hour: null, full_minutes: null
		};
		if (a.battery != null && b.battery != null && b.t - a.t >= 600)
			r.pct_per_hour = int((b.battery - a.battery) * 36000.0 / (b.t - a.t)) / 10.0;
		// to full, while charging: what is missing over the last 5 minutes' current
		if (r.active && kind(now) == 'charging' && now.battery != null && now.battery < 100) {
			let cap = capacity_mah(), s5 = 0, n5 = 0;
			for (let k = end; k >= start && day[k].t > now.t - 300; k--)
				if (kind(day[k]) == 'charging') { s5 += day[k].ma; n5++; }
			if (cap && n5 && s5 / n5 > 0)
				r.full_minutes = int((100 - now.battery) / 100.0 * cap / (s5 / n5) * 60);
		}
		return r;
	}

	function status() {
		let day = samples(24 * 3600);
		let n = length(day), now = n ? day[n - 1] : null;
		if (now) {
			now.kind = kind(now);
			// (plugged: what goes into the battery, + while charging)
			now.charge_mw = now.plugged ? -now.mw : null;
		}
		let groups = {}, sum5 = 0, n5 = 0;
		let plugged_now = now?.plugged ?? false;
		// (a sample before a sleep: the gap is the sleep's, not its)
		let sl = sleeps(day), before = {};
		for (let z in sl.list) before[z.i - 1] = true;
		for (let i = 0; i < n; i++) {
			let x = day[i];
			let w = before[i] ? 0 : (i + 1 < n) ? min(day[i + 1].t - x.t, 60) : 10;
			// the 5-minute average of what the newest sample is: the use, or the charging
			if (now && x.t > now.t - 300 && x.plugged == plugged_now) { sum5 += plugged_now ? -x.mw : x.mw; n5++; }
			if (x.plugged || !w) continue;
			let k = state_key(x);
			let g = groups[k];
			if (!g) g = groups[k] = { screen: x.screen, hotspot: x.hotspot, saver: x.saver, sec: 0, mws: 0 };
			g.sec += w; g.mws += x.mw * w;
		}
		let avg = [];
		for (let k, g in groups)
			push(avg, { screen: g.screen, hotspot: g.hotspot, saver: g.saver, minutes: int(g.sec / 60), mw: int(g.mws / g.sec) });
		// deep sleep: its time in full; mw null while there is too little of it
		if (sl.sec)
			push(avg, { sleep: true, screen: false, hotspot: false, saver: true, minutes: int(sl.sec / 60),
				mw: sl.avg?.mw, ma: sl.avg?.ma });
		let charts = {};
		if (now)
			for (let span in CHART_SPANS) charts[span] = chart(day, sl, now, span);
		return { now, avg5: n5 ? int(sum5 / n5) : null, charts, avg, session: session(day, now),
			capacity_mah: capacity_mah(), samples: n, service: running() };
	}

	return {
		'GET /status': function(req) {
			let st = ctx.state_get('installed', 60);
			if (st == null) {
				st = ensure_installed();
				ctx.state_put('installed', st);
			}
			// (the page asks every few seconds: the file is read at most every 10)
			let s = ctx.state_get('status', 10);
			if (s == null) {
				s = status();
				ctx.state_put('status', s);
			}
			return s;
		},
		'GET /notifications': function(req) {
			if (!ctx.state_get('checked', 60)) {
				ctx.state_put('checked', { at: time() });
				ensure_installed();
			}
			return { notifications: [] };
		}
	};
};

// 功率监测 (Power Monitor, id powermon): the app's backend.  The sampling
// runs in the background (service.sh under /etc/init.d/powermon, into
// /tmp/powermon/samples.csv); this installs that service and the LuCI page
// (状态 -> 功率监测: the chart, averages by state, CSV), keeps them installed
// -- an image update brings neither; the notification poll puts them back --
// and serves the app's page on the screen.
//
//   GET  /status          the newest sample, the last 30 min, averages by state
//   GET  /notifications   (none: only the install check, once a minute)

'use strict';

import { readfile, writefile } from 'fs';

const DIR = '/etc/e5-infoscreen/plugins/powermon';
const INIT = '/etc/init.d/powermon';
const CSV = '/tmp/powermon/samples.csv';
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
				battery: f[8] == '' ? null : +f[8] });
		}
		return out;
	}

	function state_key(x) {
		return (x.screen ? 'lit' : 'dark') + '_' + (x.hotspot ? 'on' : 'off') + '_' + (x.saver ? 'saver' : 'plain');
	}

	function status() {
		let day = samples(24 * 3600);
		let n = length(day), now = n ? day[n - 1] : null;
		let groups = {}, recent = [], sum5 = 0, n5 = 0;
		for (let i = 0; i < n; i++) {
			let x = day[i];
			let w = (i + 1 < n) ? min(day[i + 1].t - x.t, 60) : 10;
			if (now && x.t > now.t - 1800) push(recent, [ x.t, x.mw, x.plugged ]);
			if (x.plugged) continue;
			if (now && x.t > now.t - 300) { sum5 += x.mw; n5++; }
			let k = state_key(x);
			let g = groups[k];
			if (!g) g = groups[k] = { screen: x.screen, hotspot: x.hotspot, saver: x.saver, sec: 0, mws: 0 };
			g.sec += w; g.mws += x.mw * w;
		}
		let avg = [];
		for (let k, g in groups)
			push(avg, { screen: g.screen, hotspot: g.hotspot, saver: g.saver, minutes: int(g.sec / 60), mw: int(g.mws / g.sec) });
		return { now, avg5: n5 ? int(sum5 / n5) : null, recent, avg, samples: n, service: running() };
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

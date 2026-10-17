#!/bin/sh
# 功率监测 (Power Monitor) -- the sampler of the powermon info screen app.
#
# Every INTERVAL s (e5-plugin-powermon.settings.interval, 10 by default) one
# line goes to CSV, in RAM (/tmp), and every SAVE_EVERY lines (10 min) the new
# ones are appended to KEEP (/etc/e5/powermon/samples.csv: a reboot and an image
# update -- which keeps /etc/e5 -- start from it), and when the service stops:
#
#   time,current_ma,voltage_mv,power_mw,plugged,screen,hotspot,saver,battery,fgu,sleep,held
#
#   time        Unix time, s
#   current_ma  the fuel gauge's current: + into the battery, - out of it
#               (sc27xx_fgu: current_now in uA)
#   voltage_mv  the battery's voltage (voltage_now in uV)
#   power_mw    what the device draws from the battery: -current x voltage
#   plugged     1 with USB/AC power: the gauge then sees charging minus use,
#               not the use itself -- such samples are kept but not counted;
#               0 with the charger held off (held): the battery runs the device
#   screen      1 with the backlight on
#   hotspot     1 with the hotspot's interface (wlan0) up
#   saver       1 while 热点省电 (hotspotdata) has the radio off or the CPU held
#   battery     the charge, %
#   fgu         the fuel gauge's own charge, 0.1 % (sc27xx-fgu/capacity: its
#               coulomb counter, which goes on counting in suspend)
#   sleep       s the system was suspended since the previous sample, 0 awake
#   held        1 plugged in, and not charging: the charger in HiZ (e5-charge's limit
#               or block, USB 关闭（不充电）), or charging stopped otherwise (full, the
#               charger manager) with the battery giving -- this charger has no
#               power path, so not charging means the battery runs the device and
#               this is the use.  (Charging, with the battery still giving: the USB
#               port gives too little, e.g. a computer's 500 mA; that stays plugged)
#
# Suspended (热点省电's deep sleep), nothing runs and no samples are taken:
# the sample after a wake has `sleep` > 0, and the use over the gap is what
# the gauge's charge (fgu) lost across it -- the backend and the LuCI page
# work that out.  The sleep is measured here, not taken from the app that
# suspends: `sleep INTERVAL` counts CLOCK_MONOTONIC, which stops in suspend,
# while /proc/uptime (CLOCK_BOOTTIME) goes on -- what the uptime moved past
# the interval is the time suspended.  Rows from v1.1 have neither column.
#
# Every read is a shell builtin (no process per sample: a measurement that
# woke the device would measure itself).  The file is kept to MAX_LINES
# (3 days at 10 s); the oldest quarter goes when it is full.
#
# /etc/init.d/powermon runs this; the app's backend installs it.  With the app
# removed, this removes the service, its LuCI page and the data.

DIR=/etc/e5-infoscreen/plugins/powermon
CFG=e5-plugin-powermon
INIT=/etc/init.d/powermon
OUT=/tmp/powermon
CSV=$OUT/samples.csv
KEEP=/etc/e5/powermon
KEEP_CSV=$KEEP/samples.csv
SAVE_EVERY=60
HIZ=/sys/class/power_supply/aw322xx_charger/high_impedance_enable
BAT=/sys/class/power_supply/battery
FGU=/sys/class/power_supply/sc27xx-fgu
MAX_LINES=26000
LUCI_FILES="/www/luci-static/resources/view/powermon/index.js /usr/share/luci/menu.d/luci-app-powermon.json /usr/share/rpcd/acl.d/luci-app-powermon.json"

log() { logger -t powermon -- "$*"; }

interval() {
	local v
	v=$(uci -q get "$CFG.settings.interval")
	case "$v" in ''|*[!0-9]*) v=10 ;; esac
	[ "$v" -ge 2 ] && [ "$v" -le 300 ] || v=10
	echo "$v"
}

# a sysfs value into the named variable, empty when unreadable (builtins)
get() { read -r "$1" < "$2" || eval "$1="; } 2>/dev/null

remove_self() {
	log "app removed: sampler, LuCI page and data removed"
	rm -f $LUCI_FILES
	rmdir /www/luci-static/resources/view/powermon 2>/dev/null
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache "$OUT" "$KEEP"
	/etc/init.d/rpcd reload >/dev/null 2>&1
	"$INIT" disable 2>/dev/null
	rm -f "$INIT"
	ubus call service delete '{"name":"powermon"}'
	exit 0
}

# Unix time from the uptime, without a process: the clock read once, again
# every hour (NTP may set it after boot)
clock_sync() {
	local now up
	now=$(date +%s)
	read -r up _ < /proc/uptime
	up=${up%.*}
	boot=$((now - up))
	sync_at=$((up + 3600))
}

BACKLIGHT=
for b in /sys/class/backlight/*; do
	[ -f "$b/brightness" ] && { BACKLIGHT=$b/brightness; break; }
done

# the kept copy: the new lines appended (pending), all of it after a trim
save() {
	[ "$pending" -gt 0 ] || return 0
	mkdir -p "$KEEP" || return 0
	if [ -n "$rewrite" ] || [ ! -s "$KEEP_CSV" ]; then
		cp "$CSV" "$KEEP_CSV.new" && mv -f "$KEEP_CSV.new" "$KEEP_CSV"
	else
		tail -n "$pending" "$CSV" >> "$KEEP_CSV"
	fi
	pending=0; rewrite=
}
trap 'save; exit 0' TERM INT

mkdir -p "$OUT"
# (after a reboot: the samples from before it)
[ -s "$CSV" ] || { [ -s "$KEEP_CSV" ] && cp "$KEEP_CSV" "$CSV"; }
lines=0; pending=0; rewrite=
[ -f "$CSV" ] && lines=$(wc -l < "$CSV")
INTERVAL=$(interval)
clock_sync
cfg_check=0
prev_up=
cp "$DIR/service.sh" /var/run/powermon.running 2>/dev/null
log "sampling every ${INTERVAL}s into $CSV"

while :; do
	[ -f "$DIR/manifest.json" ] || remove_self
	read -r up _ < /proc/uptime
	up=${up%.*}
	[ "$up" -lt "$sync_at" ] || clock_sync
	# (a round is the work, ms, and the interval: the uptime further on than
	# that was suspended; 2 s of slack for whole seconds and a busy system)
	sl=0
	[ -n "$prev_up" ] && sl=$((up - prev_up - prev_interval))
	[ "$sl" -gt 2 ] || sl=0
	prev_up=$up

	get ua "$BAT/current_now"
	get uv "$BAT/voltage_now"
	get status "$BAT/status"
	get cap "$BAT/capacity"
	get fgu "$FGU/capacity"
	case "$ua" in ''|*[!0-9-]*) ua=0 ;; esac
	case "$uv" in ''|*[!0-9]*) uv=0 ;; esac
	case "$fgu" in *[!0-9]*) fgu= ;; esac

	plugged=0
	get v /sys/class/power_supply/usb/online; [ "$v" = 1 ] && plugged=1
	get v /sys/class/power_supply/ac/online; [ "$v" = 1 ] && plugged=1
	case "$status" in Charging|Full) plugged=1 ;; esac
	held=0
	if [ "$plugged" = 1 ]; then
		get v "$HIZ"
		if [ "$v" = 1 ] || { [ "$status" != Charging ] && [ "$ua" -lt -15000 ]; }; then
			plugged=0; held=1
		fi
	fi

	screen=0
	if [ -n "$BACKLIGHT" ]; then get v "$BACKLIGHT"; [ "${v:-0}" -gt 0 ] 2>/dev/null && screen=1; fi
	hotspot=0
	get v /sys/class/net/wlan0/operstate; [ "$v" = up ] && hotspot=1
	saver=0
	{ [ -f /var/run/hotspotdata.radio-off.0 ] || [ -f /var/run/hotspotdata.radio-off.1 ] ||
		[ -f /var/run/hotspotdata.perf ] || [ -f /var/run/hotspotdata.cores ]; } && saver=1

	ma=$((ua / 1000))
	mv=$((uv / 1000))
	# (uA x mV / 10^6 = mW; up to ~10^10, well inside the shell's 64 bits)
	mw=$(( -ua * mv / 1000000 ))
	echo "$((boot + up)),$ma,$mv,$mw,$plugged,$screen,$hotspot,$saver,${cap:-},$fgu,$sl,$held" >> "$CSV"
	lines=$((lines + 1)); pending=$((pending + 1))
	if [ "$lines" -gt "$MAX_LINES" ]; then
		tail -n $((MAX_LINES * 3 / 4)) "$CSV" > "$CSV.new" && mv -f "$CSV.new" "$CSV"
		lines=$((MAX_LINES * 3 / 4)); rewrite=1
	fi
	[ "$pending" -lt "$SAVE_EVERY" ] || save

	# (the interval setting, once a minute: uci is a process)
	cfg_check=$((cfg_check + INTERVAL))
	if [ "$cfg_check" -ge 60 ]; then
		cfg_check=0
		INTERVAL=$(interval)
	fi
	prev_interval=$INTERVAL
	# (in the background: a stop's TERM is handled at once, and the data kept)
	sleep "$INTERVAL" &
	wait $!
done

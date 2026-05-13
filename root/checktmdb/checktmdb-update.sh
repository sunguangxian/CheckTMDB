#!/bin/sh

BASE_DIR="/root/checktmdb"
UPDATE_BASE="${CHECKTMDB_UPDATE_BASE:-https://raw.githubusercontent.com/sunguangxian/CheckTMDB/refs/heads/main/root/checktmdb}"
COUNTRY="${CHECKTMDB_COUNTRY:-hk}"
INTERVAL="${CHECKTMDB_INTERVAL:-6}"
IPV6="${CHECKTMDB_IPV6:-0}"
CONNECT_TIMEOUT="${CHECKTMDB_TIMEOUT:-1.5}"
DNS_TIMEOUT="${CHECKTMDB_DNS_TIMEOUT:-5}"
WORKERS="${CHECKTMDB_WORKERS:-4}"
OUT="/tmp/checktmdb.hosts"
NEW="/tmp/checktmdb.hosts.new"
LOG="/tmp/checktmdb.log"
LOCK="/tmp/checktmdb.lock"
PID_FILE="$LOCK/pid"
SCRIPT_FILES="check_tmdb.py checktmdb-update.sh install.sh"

log() {
	local msg
	msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
	echo "$msg" >> "$LOG"
	logger -t checktmdb "$*" 2>/dev/null
}

is_running_pid() {
	local pid
	pid="$1"
	[ -n "$pid" ] || return 1
	kill -0 "$pid" >/dev/null 2>&1
}

list_tasks() {
	ps w | grep -E 'check_tmdb\.py|checktmdb-update\.sh' | grep -v grep | grep -v ' ps$'
}

read_lock_pid() {
	[ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null
}

cleanup_lock_if_stale() {
	local pid
	pid="$(read_lock_pid)"

	if [ -d "$LOCK" ] && ! is_running_pid "$pid"; then
		rm -rf "$LOCK"
		rm -f "$NEW"
		log "stale lock removed"
	fi
}

acquire_lock() {
	cleanup_lock_if_stale

	if mkdir "$LOCK" 2>/dev/null; then
		echo "$$" > "$PID_FILE"
		trap 'rm -rf "$LOCK"' EXIT INT TERM
		return 0
	fi

	return 1
}

task_pids() {
	ps w | awk '
		/check_tmdb\.py|checktmdb-update\.sh/ &&
		!/checktmdb-update\.sh (ps|tasks|stop|kill)/ &&
		!/awk/ &&
		!/grep/ &&
		!/ ps/ {
			print $1
		}
	'
}

stop_tasks() {
	local signal pid pids
	signal="$1"
	pids="$(task_pids)"

	if [ -z "$pids" ]; then
		rm -rf "$LOCK"
		rm -f "$NEW"
		log "no running task found"
		return 0
	fi

	for pid in $pids; do
		[ "$pid" = "$$" ] && continue
		kill "-$signal" "$pid" >/dev/null 2>&1
	done

	sleep 1
	if [ "$signal" != "KILL" ]; then
		for pid in $pids; do
			[ "$pid" = "$$" ] && continue
			is_running_pid "$pid" && return 1
		done
	fi

	rm -rf "$LOCK"
	rm -f "$NEW"
	log "running task stopped with $signal"
	return 0
}

download_file() {
	local url dest
	url="$1"
	dest="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time 60 -o "$dest" "$url"
	else
		wget -qO "$dest" "$url"
	fi
}

validate_downloads() {
	local tmp file
	tmp="$1"

	for file in $SCRIPT_FILES; do
		[ -s "$tmp/$file" ] || {
			log "script update failed: empty file $file"
			return 1
		}
	done

	python3 -m py_compile "$tmp/check_tmdb.py" >/dev/null 2>&1 || {
		log "script update failed: check_tmdb.py syntax error"
		return 1
	}

	sh -n "$tmp/checktmdb-update.sh" >/dev/null 2>&1 || {
		log "script update failed: checktmdb-update.sh syntax error"
		return 1
	}

	sh -n "$tmp/install.sh" >/dev/null 2>&1 || {
		log "script update failed: install.sh syntax error"
		return 1
	}
}

self_update() {
	local tmp file url

	mkdir -p "$BASE_DIR"
	tmp="$(mktemp -d /tmp/checktmdb-update.XXXXXX)" || return 1
	log "script update started: $UPDATE_BASE"

	for file in $SCRIPT_FILES; do
		url="$UPDATE_BASE/$file"
		if ! download_file "$url" "$tmp/$file"; then
			rm -rf "$tmp"
			log "script update failed: download $url"
			return 1
		fi
	done

	if ! validate_downloads "$tmp"; then
		rm -rf "$tmp"
		return 1
	fi

	for file in $SCRIPT_FILES; do
		cp "$tmp/$file" "$BASE_DIR/$file"
	done
	chmod +x "$BASE_DIR/check_tmdb.py" "$BASE_DIR/checktmdb-update.sh" "$BASE_DIR/install.sh" 2>/dev/null
	rm -rf "$tmp"
	log "script update finished"
	return 0
}

run_update() {
	local args

	cd "$BASE_DIR" || {
		log "base dir not found: $BASE_DIR"
		return 1
	}

	args="--country $COUNTRY --connect-timeout $CONNECT_TIMEOUT --dns-timeout $DNS_TIMEOUT --workers $WORKERS --output $NEW"
	[ "$IPV6" = "1" ] && args="$args --ipv6"

	log "update started: country=$COUNTRY ipv6=$IPV6 connect_timeout=$CONNECT_TIMEOUT dns_timeout=$DNS_TIMEOUT"
	rm -f "$NEW"

	# shellcheck disable=SC2086
	if python3 check_tmdb.py $args >> "$LOG" 2>&1 && [ -s "$NEW" ]; then
		mv "$NEW" "$OUT"
		/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
		log "TMDB hosts updated: $OUT"
		return 0
	fi

	rm -f "$NEW"
	log "TMDB hosts update failed"
	return 1
}

show_status() {
	echo "country=$COUNTRY"
	echo "interval=$INTERVAL"
	echo "ipv6=$IPV6"
	echo "hosts=$OUT"
	echo "log=$LOG"
	echo "update_base=$UPDATE_BASE"
	grep '^# Update time:' "$OUT" 2>/dev/null | sed 's/^# //'
}

case "$1" in
	run|update|"")
		if acquire_lock; then
			run_update
		else
			log "another update is running"
			echo "another update is running; use '$0 ps' or '$0 stop'" >&2
			exit 1
		fi
		;;
	status)
		show_status
		;;
	hosts)
		cat "$OUT" 2>/dev/null
		;;
	log)
		tail -n 200 "$LOG" 2>/dev/null
		;;
	ps|tasks)
		list_tasks
		;;
	stop)
		if ! stop_tasks TERM; then
			echo "some tasks are still running; use '$0 kill' to force stop" >&2
			exit 1
		fi
		;;
	kill)
		stop_tasks KILL
		;;
	self-update|upgrade)
		if acquire_lock; then
			self_update
		else
			log "another update is running"
			echo "another update is running; use '$0 ps' or '$0 stop'" >&2
			exit 1
		fi
		;;
	*)
		echo "Usage: $0 [run|status|hosts|log|ps|stop|kill|self-update]" >&2
		exit 2
		;;
esac

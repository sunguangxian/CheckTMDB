#!/bin/sh

BASE_DIR="/root/checktmdb"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
UPDATE_BASE="${CHECKTMDB_UPDATE_BASE:-https://raw.githubusercontent.com/sunguangxian/CheckTMDB/refs/heads/main/root/checktmdb}"
CRON_FILE="/etc/crontabs/root"
COUNTRY="${CHECKTMDB_COUNTRY:-hk}"
INTERVAL="${CHECKTMDB_INTERVAL:-6}"
IPV6="${CHECKTMDB_IPV6:-0}"
TIMEOUT="${CHECKTMDB_TIMEOUT:-1.0}"
DNS_CONF_DIR="/tmp/checktmdb.d"

log() {
	echo "[checktmdb] $*"
}

valid_interval() {
	case "$1" in
		6|12|24) return 0 ;;
		*) return 1 ;;
	esac
}

valid_country() {
	case "$1" in
		cn|hk|sg|jp|us) return 0 ;;
		*) return 1 ;;
	esac
}

install_deps() {
	log "install dependencies"
	opkg update
	opkg install python3 python3-requests curl ca-bundle
}

ensure_dnsmasq() {
	local item found

	mkdir -p "$DNS_CONF_DIR"
	uci -q get dhcp.@dnsmasq[0] >/dev/null || {
		log "dnsmasq config not found"
		return 1
	}

	found=0
	for item in $(uci -q get dhcp.@dnsmasq[0].confdir); do
		[ "$item" = "$DNS_CONF_DIR" ] && found=1
	done

	if [ "$found" = "0" ]; then
		uci add_list dhcp.@dnsmasq[0].confdir="$DNS_CONF_DIR"
		log "dnsmasq confdir added: $DNS_CONF_DIR"
	else
		log "dnsmasq confdir already exists"
	fi

	uci commit dhcp
	/etc/init.d/dnsmasq restart
}

install_cron() {
	local cron_line

	valid_interval "$INTERVAL" || INTERVAL=6
	valid_country "$COUNTRY" || COUNTRY=hk

	sed -i '\#/root/checktmdb/checktmdb-update.sh#d' "$CRON_FILE" 2>/dev/null
	case "$INTERVAL" in
		24)
			cron_line="0 0 * * * CHECKTMDB_COUNTRY=$COUNTRY CHECKTMDB_IPV6=$IPV6 CHECKTMDB_TIMEOUT=$TIMEOUT /root/checktmdb/checktmdb-update.sh run"
			;;
		*)
			cron_line="0 */$INTERVAL * * * CHECKTMDB_COUNTRY=$COUNTRY CHECKTMDB_IPV6=$IPV6 CHECKTMDB_TIMEOUT=$TIMEOUT /root/checktmdb/checktmdb-update.sh run"
			;;
	esac

	mkdir -p "$(dirname "$CRON_FILE")"
	echo "$cron_line" >> "$CRON_FILE"
	/etc/init.d/cron enable >/dev/null 2>&1
	/etc/init.d/cron restart
	log "cron installed: every $INTERVAL hour(s)"
}

install_files() {
	mkdir -p "$BASE_DIR"
	if [ "$SCRIPT_DIR" != "$BASE_DIR" ]; then
		cp "$SCRIPT_DIR/check_tmdb.py" "$BASE_DIR/check_tmdb.py"
		cp "$SCRIPT_DIR/checktmdb-update.sh" "$BASE_DIR/checktmdb-update.sh"
		cp "$SCRIPT_DIR/install.sh" "$BASE_DIR/install.sh"
	fi
	chmod +x "$BASE_DIR/check_tmdb.py" "$BASE_DIR/checktmdb-update.sh" "$BASE_DIR/install.sh" 2>/dev/null
}

usage() {
	cat <<EOF
Usage: CHECKTMDB_COUNTRY=hk CHECKTMDB_INTERVAL=6 CHECKTMDB_IPV6=0 CHECKTMDB_TIMEOUT=1.0 sh install.sh

Countries: cn, hk, sg, jp, us
Intervals: 6, 12, 24
IPv6:      0, 1
Timeout:   TCP connect timeout in seconds

Script update:
  CHECKTMDB_UPDATE_BASE=$UPDATE_BASE sh install.sh self-update
EOF
}

case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	self-update|upgrade)
		install_files
		CHECKTMDB_UPDATE_BASE="$UPDATE_BASE" "$BASE_DIR/checktmdb-update.sh" self-update
		exit $?
		;;
esac

install_files
install_deps
ensure_dnsmasq
install_cron

log "run first update"
"$BASE_DIR/checktmdb-update.sh" run

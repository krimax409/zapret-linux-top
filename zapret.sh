#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RUN_DIR="/tmp/zapret-run"
PID_FILE="$RUN_DIR/zapret.pid"
STRATEGY_FILE="$RUN_DIR/zapret.strategy"
IPTABLES_FILE="$RUN_DIR/zapret.iptables"
AUTOSTART_FILE="$SCRIPT_DIR/autostart.conf"
GAME_FILTER_FILE="$SCRIPT_DIR/game-filter.conf"
USER_LISTS_DIR="$SCRIPT_DIR/user-lists"
DATA_BACKUP_DIR="$SCRIPT_DIR/data.previous"
SERVICE_NAME="zapret-diy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO_URL="https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.tar.gz"
ZAPRET_VERSION="${ZAPRET_VERSION:-v72.13}"
ZAPRET_INSTALL_DIR="${ZAPRET_INSTALL_DIR:-$SCRIPT_DIR/.local/zapret}"
ZAPRET_RELEASE_URL="https://github.com/bol-van/zapret/releases/download/${ZAPRET_VERSION}/zapret-${ZAPRET_VERSION}.tar.gz"
QNUM="${ZAPRET_QNUM:-200}"
FWMARK=0x40000000

RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
CYN=$'\033[36m'
GRN=$'\033[32m'
YLW=$'\033[33m'
RED=$'\033[31m'
WHT=$'\033[97m'
BG_SEL=$'\033[44m'
BG_GRN=$'\033[42m'
BG_YLW=$'\033[43m'

die() {
	echo "${RED}[!]${RST} $*" >&2
	exit 1
}
info() { echo "${CYN}[*]${RST} $*"; }
ok() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[~]${RST} $*"; }

cleanup_dir() {
	local dir="$1"
	[ -n "$dir" ] && [ -d "$dir" ] && rm -rf -- "$dir"
}

invoking_uid() {
	if [ -n "${SUDO_UID:-}" ]; then
		echo "$SUDO_UID"
	else
		stat -c %u "$SCRIPT_DIR"
	fi
}

invoking_gid() {
	if [ -n "${SUDO_GID:-}" ]; then
		echo "$SUDO_GID"
	else
		stat -c %g "$SCRIPT_DIR"
	fi
}

fix_invoking_user_ownership() {
	[ "$(id -u)" -eq 0 ] || return 0
	chown -R "$(invoking_uid):$(invoking_gid)" "$@"
}

is_nixos() { [ -f /etc/NIXOS ]; }

local_linux_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) echo linux-x86_64 ;;
	i?86) echo linux-x86 ;;
	aarch64 | arm64) echo linux-arm64 ;;
	armv6l | armv7l | armv8l) echo linux-arm ;;
	ppc | ppc32 | powerpc) echo linux-ppc ;;
	mips64* ) echo linux-mips64 ;;
	mipsel* ) echo linux-mipsel ;;
	mips* ) echo linux-mips ;;
	*) return 1 ;;
	esac
}

install_local_zapret() {
	local arch work archive extracted candidate target
	arch="$(local_linux_arch)" || die "Unsupported Linux architecture: $(uname -m)"
	command -v curl >/dev/null 2>&1 || die "curl is required to install local zapret."
	command -v tar >/dev/null 2>&1 || die "tar is required to install local zapret."

	work="$(mktemp -d "$SCRIPT_DIR/.zapret-download.XXXXXX")"
	archive="$work/zapret.tar.gz"
	extracted="$work/extracted"
	mkdir -p "$extracted"
	info "Downloading zapret ${ZAPRET_VERSION} for ${arch}..." >&2
	if ! curl -fsSL "$ZAPRET_RELEASE_URL" -o "$archive" || ! tar xzf "$archive" -C "$extracted"; then
		cleanup_dir "$work"
		die "Could not download or unpack zapret ${ZAPRET_VERSION}."
	fi
	candidate="$(find "$extracted" -type f -path "*/binaries/${arch}/nfqws" -print -quit)"
	[ -n "$candidate" ] || {
		cleanup_dir "$work"
		die "zapret ${ZAPRET_VERSION} has no nfqws binary for ${arch}."
	}
	target="$ZAPRET_INSTALL_DIR/bin/nfqws"
	mkdir -p "$(dirname "$target")"
	cp "$candidate" "$target"
	chmod 755 "$target"
	printf '%s\n' "$ZAPRET_VERSION" >"$ZAPRET_INSTALL_DIR/version"
	fix_invoking_user_ownership "$ZAPRET_INSTALL_DIR"
	cleanup_dir "$work"
	[ -x "$target" ] || die "Local zapret installation is incomplete: $target"
}

find_nfqws() {
	local local_bin="$ZAPRET_INSTALL_DIR/bin/nfqws"
	if [ -x "$local_bin" ]; then
		echo "$local_bin"
		return 0
	fi
	install_local_zapret
	echo "$local_bin"
}

is_running() {
	local pid
	[ -f "$PID_FILE" ] || return 1
	pid="$(cat "$PID_FILE" 2>/dev/null)"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	if [ -r "/proc/$pid/comm" ]; then
		[ "$(cat "/proc/$pid/comm" 2>/dev/null)" = nfqws ] || return 1
	fi
}

get_active_strategy() {
	[ -f "$STRATEGY_FILE" ] && cat "$STRATEGY_FILE" 2>/dev/null || echo ""
}

is_autostart_enabled() { [ -f "$AUTOSTART_FILE" ]; }

get_autostart_strategy() {
	[ -f "$AUTOSTART_FILE" ] && cat "$AUTOSTART_FILE" 2>/dev/null || echo ""
}

get_game_filter_mode() {
	local mode="disabled"
	[ -f "$GAME_FILTER_FILE" ] && read -r mode <"$GAME_FILTER_FILE"
	case "$mode" in
	disabled | all | tcp | udp) echo "$mode" ;;
	*) echo "disabled" ;;
	esac
}

set_game_filter_mode() {
	local mode="$1"
	case "$mode" in
	disabled | all | tcp | udp) ;;
	*) die "Invalid game filter mode: $mode" ;;
	esac

	local tmp="${GAME_FILTER_FILE}.tmp.$$"
	printf '%s\n' "$mode" >"$tmp"
	mv -f "$tmp" "$GAME_FILTER_FILE"
	fix_invoking_user_ownership "$GAME_FILTER_FILE"
}

cycle_game_filter_mode() {
	local current next
	current="$(get_game_filter_mode)"
	case "$current" in
	disabled) next="all" ;;
	all) next="tcp" ;;
	tcp) next="udp" ;;
	udp) next="disabled" ;;
	esac
	set_game_filter_mode "$next"
	ok "Game filter: $next (applies on next launch)"
}

game_filter_ports() {
	local mode="$1"
	case "$mode" in
	disabled)
		GAME_FILTER=12
		GAME_FILTER_TCP=12
		GAME_FILTER_UDP=12
		;;
	all)
		GAME_FILTER=1024-65535
		GAME_FILTER_TCP=1024-65535
		GAME_FILTER_UDP=1024-65535
		;;
	tcp)
		GAME_FILTER=1024-65535
		GAME_FILTER_TCP=1024-65535
		GAME_FILTER_UDP=12
		;;
	udp)
		GAME_FILTER=1024-65535
		GAME_FILTER_TCP=12
		GAME_FILTER_UDP=1024-65535
		;;
	*) die "Invalid game filter mode: $mode" ;;
	esac
}

get_flowseal_version() {
	local data_dir="${1:-$DATA_DIR}"
	if [ -s "$data_dir/version.txt" ]; then
		tr -d '\r\n' <"$data_dir/version.txt"
	elif [ -s "$data_dir/service.bat" ]; then
		sed -nE 's/^set "LOCAL_VERSION=([^"]+)".*/\1/p' "$data_dir/service.bat" | head -n 1 | tr -d '\r\n'
	else
		echo "unknown"
	fi
}

ensure_user_lists() {
	mkdir -p "$USER_LISTS_DIR"
	if [ ! -e "$USER_LISTS_DIR/list-general-user.txt" ]; then
		printf '%s\n' '# Never leave this file empty' 'domain.example.abc' >"$USER_LISTS_DIR/list-general-user.txt"
	fi
	if [ ! -e "$USER_LISTS_DIR/list-exclude-user.txt" ]; then
		printf '%s\n' 'domain.example.abc' >"$USER_LISTS_DIR/list-exclude-user.txt"
	fi
	if [ ! -e "$USER_LISTS_DIR/ipset-exclude-user.txt" ]; then
		printf '%s\n' '203.0.113.113/32' >"$USER_LISTS_DIR/ipset-exclude-user.txt"
	fi
	fix_invoking_user_ownership "$USER_LISTS_DIR"
	chmod 755 "$USER_LISTS_DIR"
	chmod 644 "$USER_LISTS_DIR"/*.txt
}

populate_user_lists() {
	local target="$1"
	ensure_user_lists
	cp "$USER_LISTS_DIR"/*.txt "$target/"
}

do_stop() {
	local pid
	if is_running; then
		pid="$(cat "$PID_FILE" 2>/dev/null)"
		info "Stopping nfqws (PID $pid)..."
		kill "$pid" 2>/dev/null || true
		sleep 0.3
		kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
	else
		warn "nfqws is not running; cleaning stale runtime state."
	fi
	cleanup_iptables_from_file
	rm -f "$PID_FILE" "$STRATEGY_FILE"
	ok "Stopped."
}

prepare_runtime() {
	local data_dir="${1:-$DATA_DIR}"
	local run_dir="${2:-$RUN_DIR}"
	[ -d "$data_dir/bin" ] || die "Missing directory: $data_dir/bin"
	[ -d "$data_dir/lists" ] || die "Missing directory: $data_dir/lists"

	rm -rf -- "$run_dir"
	mkdir -p "$run_dir/bin" "$run_dir/lists"
	cp "$data_dir"/bin/*.bin "$run_dir/bin/" 2>/dev/null || true
	cp "$data_dir"/lists/* "$run_dir/lists/" 2>/dev/null || true
	populate_user_lists "$run_dir/lists"
	chmod -R a+rX "$run_dir"
}

collect_strategies() {
	STRATEGIES=()
	local names=() file name
	for file in "$DATA_DIR"/general*.bat; do
		[ -f "$file" ] && names+=("$(basename "$file" .bat)")
	done
	while IFS= read -r name; do
		[ -n "$name" ] && STRATEGIES+=("$name")
	done < <(printf '%s\n' "${names[@]}" | sort -t'(' -k1,1 -k2V)
}

normalize_strategy_command() {
	local bat_file="$1"
	tr -d '\r' <"$bat_file" | awk '
        {
            sub(/[[:space:]]+$/, "")
            if ($0 ~ /\^$/) {
                sub(/\^$/, "")
                printf "%s ", $0
            } else {
                print
            }
        }
    '
}

validate_port_list() {
	local list="$1" label="$2" part start end
	local parts=()
	[ -n "$list" ] || die "$label is empty"
	IFS=',' read -ra parts <<<"$list"
	for part in "${parts[@]}"; do
		if [[ "$part" =~ ^[0-9]+$ ]]; then
			start="$part"
			end="$part"
		elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			start="${BASH_REMATCH[1]}"
			end="${BASH_REMATCH[2]}"
		else
			die "$label contains an invalid port entry: $part"
		fi
		[ "$start" -ge 1 ] && [ "$end" -le 65535 ] && [ "$start" -le "$end" ] ||
			die "$label contains an invalid port range: $part"
	done
}

validate_config_files() {
	local config_file="$1" line value path ref
	while IFS= read -r line; do
		case "$line" in
		--hostlist=* | --hostlist-exclude=* | --hostlist-auto=* | --ipset=* | --ipset-exclude=*)
			value="${line#*=}"
			[ -f "$value" ] || die "Referenced list does not exist: $value"
			;;
		esac
		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			path="${ref#*@}"
			[ -f "$path" ] || die "Referenced payload does not exist: $path"
		done < <(printf '%s\n' "$line" | grep -oE '(\+[0-9]+)?@/[^,[:space:]]+' || true)
	done <"$config_file"
}

# parse_bat BAT [daemon|foreground|validate] [runtime] [game-mode] [output]
parse_bat() {
	local bat_file="$1"
	local mode="${2:-daemon}"
	local run_dir="${3:-$RUN_DIR}"
	local game_mode="${4:-$(get_game_filter_mode)}"
	local output_conf="${5:-$run_dir/nfqws.conf}"
	local normalized command_count command cmdline placeholder tcp_count udp_count

	[ -f "$bat_file" ] || die "Strategy file not found: $bat_file"
	case "$mode" in
	daemon | foreground | validate) ;;
	*) die "Invalid parse mode: $mode" ;;
	esac

	normalized="$(normalize_strategy_command "$bat_file")"
	command_count="$(printf '%s\n' "$normalized" | grep -ci 'winws\.exe' || true)"
	[ "$command_count" -eq 1 ] || die "$(basename "$bat_file"): expected one winws.exe command, found $command_count"
	command="$(printf '%s\n' "$normalized" | grep -i 'winws\.exe')"
	cmdline="${command#*winws.exe}"
	cmdline="$(printf '%s\n' "$cmdline" | sed -E 's/^"[[:space:]]*//; s/^[[:space:]]+//')"

	game_filter_ports "$game_mode"
	cmdline="${cmdline//%GameFilterTCP%/$GAME_FILTER_TCP}"
	cmdline="${cmdline//%GameFilterUDP%/$GAME_FILTER_UDP}"
	cmdline="${cmdline//%GameFilter%/$GAME_FILTER}"
	cmdline="$(printf '%s\n' "$cmdline" | sed -E \
		-e "s|\"?%BIN%([^\"[:space:]]+)\"?|@${run_dir}/bin/\1|g" \
		-e "s|\"?%LISTS%([^\"[:space:]]+)\"?|${run_dir}/lists/\1|g" \
		-e 's/\^!/!/g' \
		-e 's/[[:space:]]+/ /g' \
		-e 's/^ //; s/ $//')"

	placeholder="$(printf '%s\n' "$cmdline" | grep -oE '%[^%[:space:]]+%' | head -n 1 || true)"
	[ -z "$placeholder" ] || die "$(basename "$bat_file"): unsupported placeholder $placeholder"
	[[ "$cmdline" != *\\* ]] || die "$(basename "$bat_file"): unresolved Windows path"
	[[ "$cmdline" != *'"'* ]] || die "$(basename "$bat_file"): unresolved quote"
	[[ "$cmdline" != *'^'* ]] || die "$(basename "$bat_file"): unresolved continuation marker"

	tcp_count="$(printf '%s\n' "$cmdline" | grep -oE '(^| )--wf-tcp=[^ ]+' | wc -l)"
	udp_count="$(printf '%s\n' "$cmdline" | grep -oE '(^| )--wf-udp=[^ ]+' | wc -l)"
	[ "$tcp_count" -eq 1 ] || die "$(basename "$bat_file"): expected one --wf-tcp option, found $tcp_count"
	[ "$udp_count" -eq 1 ] || die "$(basename "$bat_file"): expected one --wf-udp option, found $udp_count"

	WF_TCP="$(printf '%s\n' "$cmdline" | grep -oE -- '--wf-tcp=[^ ]+' | cut -d= -f2-)"
	WF_UDP="$(printf '%s\n' "$cmdline" | grep -oE -- '--wf-udp=[^ ]+' | cut -d= -f2-)"
	validate_port_list "$WF_TCP" "--wf-tcp"
	validate_port_list "$WF_UDP" "--wf-udp"

	cmdline="$(printf '%s\n' "$cmdline" | sed -E \
		-e 's/(^| )--wf-tcp=[^ ]+//g' \
		-e 's/(^| )--wf-udp=[^ ]+//g' \
		-e 's/[[:space:]]+/ /g' \
		-e 's/^ //; s/ $//')"

	mkdir -p "$(dirname "$output_conf")"
	NFQWS_CONF="$output_conf"
	{
		[ "$mode" = validate ] && echo "--dry-run"
		echo "--qnum=$QNUM"
		if [ "$mode" = daemon ]; then
			echo "--daemon"
			echo "--pidfile=$PID_FILE"
		fi
		printf '%s\n' "$cmdline" | tr ' ' '\n' | while IFS= read -r argument; do
			[ -n "$argument" ] && echo "$argument"
		done
	} >"$NFQWS_CONF"
	chmod a+r "$NFQWS_CONF"
	validate_config_files "$NFQWS_CONF"
}

validate_dataset() {
	local data_dir="${1:-$DATA_DIR}"
	local quiet="${2:-false}"
	local nfqws validation_dir strategy mode config output count=0
	[ -d "$data_dir" ] || die "Data directory not found: $data_dir"
	[ -d "$data_dir/bin" ] || die "Missing directory: $data_dir/bin"
	[ -d "$data_dir/lists" ] || die "Missing directory: $data_dir/lists"
	[ -f "$data_dir/service.bat" ] || die "Missing file: $data_dir/service.bat"

	nfqws="$(find_nfqws)"
	validation_dir="$(mktemp -d /tmp/zapret-validate.XXXXXX)"
	mkdir -p "$validation_dir/bin" "$validation_dir/lists" "$validation_dir/configs"
	cp "$data_dir"/bin/*.bin "$validation_dir/bin/" 2>/dev/null || true
	cp "$data_dir"/lists/* "$validation_dir/lists/" 2>/dev/null || true
	populate_user_lists "$validation_dir/lists"
	chmod -R a+rX "$validation_dir"

	while IFS= read -r -d '' strategy; do
		count=$((count + 1))
		for mode in disabled all tcp udp; do
			config="$validation_dir/configs/$(basename "$strategy" .bat).${mode}.conf"
			if ! (parse_bat "$strategy" validate "$validation_dir" "$mode" "$config"); then
				cleanup_dir "$validation_dir"
				return 1
			fi
			if ! output="$("$nfqws" "@$config" 2>&1)"; then
				warn "$(basename "$strategy") [$mode]: nfqws rejected the generated configuration"
				printf '%s\n' "$output" >&2
				cleanup_dir "$validation_dir"
				return 1
			fi
			if ! grep -qi 'parameters verified' <<<"$output"; then
				warn "$(basename "$strategy") [$mode]: nfqws did not confirm validation"
				printf '%s\n' "$output" >&2
				cleanup_dir "$validation_dir"
				return 1
			fi
		done
	done < <(find "$data_dir" -maxdepth 1 -type f -name 'general*.bat' -print0 | sort -z)

	if [ "$count" -eq 0 ]; then
		cleanup_dir "$validation_dir"
		die "No general*.bat strategies found in $data_dir"
	fi
	cleanup_dir "$validation_dir"
	[ "$quiet" = true ] || ok "Validated $count strategies in all four game-filter modes."
}

build_candidate_data() {
	local extracted="$1" candidate="$2"
	local strategies=()
	mapfile -d '' strategies < <(find "$extracted" -maxdepth 1 -type f -name 'general*.bat' -print0 | sort -z)
	[ "${#strategies[@]}" -gt 0 ] || return 1
	[ -f "$extracted/service.bat" ] || return 1
	[ -d "$extracted/bin" ] || return 1
	[ -d "$extracted/lists" ] || return 1
	mkdir -p "$candidate"
	cp "${strategies[@]}" "$candidate/"
	cp "$extracted/service.bat" "$candidate/"
	cp -R "$extracted/bin" "$candidate/bin"
	cp -R "$extracted/lists" "$candidate/lists"
	if [ -f "$extracted/.service/version.txt" ]; then
		cp "$extracted/.service/version.txt" "$candidate/version.txt"
	fi
}

activate_candidate_data() {
	local candidate="$1"
	local new_dir="$SCRIPT_DIR/.data.new.$$"
	local old_dir="$SCRIPT_DIR/.data.old.$$"
	rm -rf -- "$new_dir" "$old_dir"
	[ -d "$candidate" ] || die "Candidate data directory not found: $candidate"
	mv "$candidate" "$new_dir"

	if [ -e "$DATA_DIR" ]; then
		mv "$DATA_DIR" "$old_dir"
	fi
	if ! mv "$new_dir" "$DATA_DIR"; then
		[ -e "$old_dir" ] && mv "$old_dir" "$DATA_DIR"
		die "Failed to activate downloaded data; previous data restored."
	fi

	rm -rf -- "$DATA_BACKUP_DIR"
	[ -e "$old_dir" ] && mv "$old_dir" "$DATA_BACKUP_DIR"
	fix_invoking_user_ownership "$DATA_DIR"
}

download_repo() {
	local work extracted candidate
	work="$(mktemp -d "$SCRIPT_DIR/.update.XXXXXX")"
	extracted="$work/extracted"
	candidate="$work/candidate"
	mkdir -p "$extracted"

	info "Downloading Flowseal strategies..."
	if ! curl -fsSL "$REPO_URL" | tar xz -C "$extracted" --strip-components=1; then
		cleanup_dir "$work"
		warn "Download failed; current data was not changed."
		return 1
	fi
	if ! build_candidate_data "$extracted" "$candidate"; then
		cleanup_dir "$work"
		warn "Downloaded archive is incomplete; current data was not changed."
		return 1
	fi

	info "Validating Flowseal $(get_flowseal_version "$candidate") before activation..."
	if ! validate_dataset "$candidate" true; then
		cleanup_dir "$work"
		warn "Update rejected; current data was not changed."
		return 1
	fi

	activate_candidate_data "$candidate"
	cleanup_dir "$work"
	ok "Flowseal $(get_flowseal_version) installed. Active bypass was not restarted."
}

record_iptables_cleanup() {
	printf '%s\n' "$*" >>"$IPTABLES_FILE"
}

run_iptables_rule() {
	local command="$1" i
	shift
	if ! "$command" "$@"; then
		cleanup_iptables_from_file
		return 1
	fi
	local cleanup_args=("$@")
	for i in "${!cleanup_args[@]}"; do
		if [ "${cleanup_args[$i]}" = -I ]; then
			cleanup_args[$i]=-D
			break
		fi
	done
	record_iptables_cleanup "$command" "${cleanup_args[@]}"
}

setup_iptables() {
	local tcp_ports="$1" udp_ports="$2"
	local simple_tcp=() range_tcp=() simple_udp=() range_udp=()
	local parts=() port range dport ports_str command
	modprobe nfnetlink_queue 2>/dev/null || true

	IFS=',' read -ra parts <<<"$tcp_ports"
	for port in "${parts[@]}"; do
		[[ "$port" == *-* ]] && range_tcp+=("$port") || simple_tcp+=("$port")
	done
	IFS=',' read -ra parts <<<"$udp_ports"
	for port in "${parts[@]}"; do
		[[ "$port" == *-* ]] && range_udp+=("$port") || simple_udp+=("$port")
	done

	local mark=(-m mark ! --mark "$FWMARK/$FWMARK")
	local nfq=(-j NFQUEUE --queue-num "$QNUM" --queue-bypass)
	: >"$IPTABLES_FILE"
	chmod 600 "$IPTABLES_FILE"

	if [ "${#simple_tcp[@]}" -gt 0 ]; then
		ports_str="$(
			IFS=','
			echo "${simple_tcp[*]}"
		)"
		for command in iptables ip6tables; do
			run_iptables_rule "$command" -t mangle -I POSTROUTING -p tcp -m multiport --dports "$ports_str" "${mark[@]}" "${nfq[@]}" || return 1
		done
	fi
	for range in "${range_tcp[@]}"; do
		dport="${range/-/:}"
		for command in iptables ip6tables; do
			run_iptables_rule "$command" -t mangle -I POSTROUTING -p tcp --dport "$dport" "${mark[@]}" "${nfq[@]}" || return 1
		done
	done
	if [ "${#simple_udp[@]}" -gt 0 ]; then
		ports_str="$(
			IFS=','
			echo "${simple_udp[*]}"
		)"
		for command in iptables ip6tables; do
			run_iptables_rule "$command" -t mangle -I POSTROUTING -p udp -m multiport --dports "$ports_str" "${mark[@]}" "${nfq[@]}" || return 1
		done
	fi
	for range in "${range_udp[@]}"; do
		dport="${range/-/:}"
		for command in iptables ip6tables; do
			run_iptables_rule "$command" -t mangle -I POSTROUTING -p udp --dport "$dport" "${mark[@]}" "${nfq[@]}" || return 1
		done
	done
}

cleanup_iptables_from_file() {
	if [ -f "$IPTABLES_FILE" ]; then
		info "Removing iptables rules..."
		while read -r -a rule; do
			[ "${#rule[@]}" -gt 0 ] || continue
			case "${rule[0]}" in
			iptables | ip6tables) "${rule[@]}" 2>/dev/null || true ;;
			esac
		done <"$IPTABLES_FILE"
		rm -f "$IPTABLES_FILE"
	fi
}

install_service() {
	local strategy_name="$1"
	if is_nixos; then
		die "Autostart is not supported on NixOS; use a declarative systemd unit."
	fi
	echo "$strategy_name" >"$AUTOSTART_FILE"
	fix_invoking_user_ownership "$AUTOSTART_FILE"

cat >"$SERVICE_FILE" <<UNIT
[Unit]
Description=Zapret DPI bypass ($strategy_name)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/zapret.sh service-start
ExecStopPost=$SCRIPT_DIR/zapret.sh service-stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"
	ok "Autostart enabled: $strategy_name"
}

remove_service() {
	if [ -f "$SERVICE_FILE" ]; then
		systemctl stop "$SERVICE_NAME" 2>/dev/null || true
		systemctl disable "$SERVICE_NAME" 2>/dev/null || true
		rm -f "$SERVICE_FILE"
		systemctl daemon-reload
	fi
	rm -f "$AUTOSTART_FILE"
	ok "Autostart disabled."
}

cmd_service_start() {
	local strategy_name bat_file nfqws
	strategy_name="$(get_autostart_strategy)"
	[ -n "$strategy_name" ] || die "No strategy configured in $AUTOSTART_FILE"
	bat_file="$DATA_DIR/${strategy_name}.bat"
	[ -f "$bat_file" ] || die "Strategy file not found: $bat_file"
	nfqws="$(find_nfqws)"

	prepare_runtime
	parse_bat "$bat_file" foreground "$RUN_DIR" "$(get_game_filter_mode)"
	setup_iptables "$WF_TCP" "$WF_UDP"
	echo "$strategy_name" >"$STRATEGY_FILE"
	echo "$$" >"$PID_FILE"
	exec "$nfqws" "@$NFQWS_CONF"
}

cmd_service_stop() {
	cleanup_iptables_from_file
	rm -f "$PID_FILE" "$STRATEGY_FILE"
}

do_launch() {
	local strategy_name="$1" bat_file nfqws output
	bat_file="$DATA_DIR/${strategy_name}.bat"
	[ "$(id -u)" -eq 0 ] || die "nfqws requires root. Run with sudo."

	if is_running; then
		info "Stopping current instance..."
		do_stop
	fi
	nfqws="$(find_nfqws)"
	ok "nfqws: $nfqws"
	prepare_runtime
	parse_bat "$bat_file" daemon "$RUN_DIR" "$(get_game_filter_mode)"
	ok "Parsed: TCP=$WF_TCP UDP=$WF_UDP"

	local dryconf="$RUN_DIR/nfqws-dry.conf"
	{
		echo "--dry-run"
		grep -vE '^--(daemon|pidfile)' "$NFQWS_CONF"
	} >"$dryconf"
	chmod a+r "$dryconf"
	info "Validating..."
	if ! output="$("$nfqws" "@$dryconf" 2>&1)" || ! grep -qi 'parameters verified' <<<"$output"; then
		printf '%s\n' "$output" >&2
		die "nfqws rejected the generated configuration."
	fi

	info "Setting up iptables..."
	setup_iptables "$WF_TCP" "$WF_UDP"
	ok "iptables rules active."
	info "Starting nfqws [$strategy_name] in background..."
	"$nfqws" "@$NFQWS_CONF"
	sleep 0.5
	if is_running; then
		echo "$strategy_name" >"$STRATEGY_FILE"
		ok "Running in background (PID $(cat "$PID_FILE"))."
	else
		cleanup_iptables_from_file
		die "Failed to start nfqws."
	fi
}

hide_cursor() { printf '\033[?25l'; }
show_cursor() { printf '\033[?25h'; }

draw_menu() {
	local selected="$1" total="${#STRATEGIES[@]}" running=0 active_strategy="" autostart=0 autostart_strategy=""
	local game_mode flowseal_version term_h max_visible scroll_offset=0 visible_end max_w=0 inner_w title border_right
	is_running && running=1 && active_strategy="$(get_active_strategy)"
	is_autostart_enabled && autostart=1 && autostart_strategy="$(get_autostart_strategy)"
	game_mode="$(get_game_filter_mode)"
	flowseal_version="$(get_flowseal_version)"
	term_h="$(tput lines 2>/dev/null || echo 24)"
	max_visible=$((term_h - 14))
	[ "$max_visible" -lt 5 ] && max_visible=5
	[ "$selected" -ge "$max_visible" ] && scroll_offset=$((selected - max_visible + 1))
	visible_end=$((scroll_offset + max_visible))
	[ "$visible_end" -gt "$total" ] && visible_end="$total"
	for strategy in "${STRATEGIES[@]}"; do
		[ "${#strategy}" -gt "$max_w" ] && max_w="${#strategy}"
	done
	inner_w=$((max_w + 6))
	[ "$inner_w" -lt 58 ] && inner_w=58
	clear

	title=" zapret-linux / Flowseal $flowseal_version "
	border_right=$((inner_w - ${#title} - 1))
	printf "  ${DIM}+-%s${RST}${BOLD}${CYN}%s${RST}${DIM}" "-" "$title"
	printf -- '-%.0s' $(seq 1 "$border_right")
	printf '+%s\n' "$RST"

	local text pad prefix i
	if [ "$running" -eq 1 ]; then
		text=" ACTIVE: $active_strategy "
		pad=$((inner_w - ${#text}))
		printf "  ${DIM}|${RST}${BG_GRN}${BOLD}${WHT}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	else
		text=" STOPPED "
		pad=$((inner_w - ${#text}))
		printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	fi
	if [ "$autostart" -eq 1 ]; then
		text=" Autostart: $autostart_strategy "
		pad=$((inner_w - ${#text}))
		printf "  ${DIM}|${RST}${BG_YLW}${BOLD}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	else
		text=" Autostart: off "
		pad=$((inner_w - ${#text}))
		printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	fi
	text=" Game filter: $game_mode "
	pad=$((inner_w - ${#text}))
	printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	printf "  ${DIM}|${RST}%-${inner_w}s${DIM}|${RST}\n" ""

	for ((i = scroll_offset; i < visible_end; i++)); do
		local name="${STRATEGIES[$i]}"
		if [ "$i" -eq "$selected" ]; then
			text=" > $name "
			pad=$((inner_w - ${#text}))
			printf "  ${DIM}|${RST}${BG_SEL}${BOLD}${WHT}%s%-${pad}s${RST}${DIM}|${RST}\n" "$text" ""
		else
			prefix="   "
			[ "$running" -eq 1 ] && [ "$name" = "$active_strategy" ] && prefix=" ${GRN}*${RST} "
			pad=$((inner_w - ${#name} - 3))
			printf "  ${DIM}|${RST}%b%s%-${pad}s${DIM}|${RST}\n" "$prefix" "$name" ""
		fi
	done
	if [ "$total" -gt "$max_visible" ]; then
		text="($((selected + 1))/$total)"
		pad=$((inner_w - ${#text}))
		printf "  ${DIM}|${RST}%-${pad}s%s${DIM}|${RST}\n" "" "$text"
	fi
	printf "  ${DIM}|${RST}%-${inner_w}s${DIM}|${RST}\n" ""
	text=" [Enter] Launch/Switch  [s] Stop  [a] Autostart"
	pad=$((inner_w - ${#text}))
	[ "$pad" -lt 0 ] && pad=0
	printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	text=" [g] Game filter  [u] Update  [q] Quit"
	pad=$((inner_w - ${#text}))
	[ "$pad" -lt 0 ] && pad=0
	printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$text" ""
	printf '  %s+' "$DIM"
	printf -- '-%.0s' $(seq 1 $((inner_w + 1)))
	printf '+%s\n' "$RST"
}

run_tui() {
	local selected=0 total="${#STRATEGIES[@]}" key key2
	hide_cursor
	trap 'show_cursor; stty echo 2>/dev/null' RETURN
	stty -echo 2>/dev/null || true
	while true; do
		draw_menu "$selected"
		IFS= read -rsn1 key
		case "$key" in
		$'\x1b')
			IFS= read -rsn2 -t 0.1 key2 || true
			case "$key2" in
			'[A') ((selected > 0)) && ((selected--)) ;;
			'[B') ((selected < total - 1)) && ((selected++)) ;;
			esac
			;;
		k | K) ((selected > 0)) && ((selected--)) ;;
		j | J) ((selected < total - 1)) && ((selected++)) ;;
		'')
			show_cursor
			stty echo 2>/dev/null || true
			SELECTED_IDX="$selected"
			TUI_ACTION=launch
			return 0
			;;
		s | S)
			if is_running; then
				show_cursor
				stty echo 2>/dev/null || true
				TUI_ACTION=stop
				return 0
			fi
			;;
		a | A)
			show_cursor
			stty echo 2>/dev/null || true
			SELECTED_IDX="$selected"
			TUI_ACTION=autostart
			return 0
			;;
		g | G)
			cycle_game_filter_mode
			sleep 0.5
			;;
		u | U)
			show_cursor
			stty echo 2>/dev/null || true
			if download_repo; then
				collect_strategies
				total="${#STRATEGIES[@]}"
				selected=0
			else
				sleep 2
			fi
			hide_cursor
			stty -echo 2>/dev/null || true
			;;
		q | Q)
			show_cursor
			stty echo 2>/dev/null || true
			return 1
			;;
		esac
	done
}

usage() {
	cat <<USAGE
Usage:
  sudo ./zapret.sh                 Open the interactive launcher
  ./zapret.sh validate [data-dir]  Validate every strategy and game-filter mode
  ./zapret.sh update               Download, validate and activate Flowseal data
  ./zapret.sh game-mode [mode]     Show or set disabled|all|tcp|udp
USAGE
}

main() {
	case "${1:-}" in
	service-start)
		cmd_service_start
		exit 0
		;;
	service-stop)
		cmd_service_stop
		exit 0
		;;
	validate)
		validate_dataset "${2:-$DATA_DIR}"
		exit 0
		;;
	update)
		download_repo
		exit $?
		;;
	game-mode)
		if [ -n "${2:-}" ]; then set_game_filter_mode "$2"; fi
		get_game_filter_mode
		exit 0
		;;
	-h | --help | help)
		usage
		exit 0
		;;
	'') ;;
	*)
		usage >&2
		exit 2
		;;
	esac

	if [ ! -d "$DATA_DIR" ] || [ -z "$(find "$DATA_DIR" -maxdepth 1 -name 'general*.bat' -print -quit 2>/dev/null)" ]; then
		warn "Strategy data not found."
		download_repo || exit 1
	fi
	ensure_user_lists
	collect_strategies
	[ "${#STRATEGIES[@]}" -gt 0 ] || die "No strategies found in $DATA_DIR"

	while true; do
		if ! run_tui; then exit 0; fi
		echo ""
		case "$TUI_ACTION" in
		stop)
			do_stop
			sleep 1
			;;
		launch)
			local strategy_name="${STRATEGIES[$SELECTED_IDX]}"
			info "Selected: $strategy_name"
			do_launch "$strategy_name"
			sleep 1
			;;
		autostart)
			if is_autostart_enabled; then
				info "Disabling autostart..."
				remove_service
			else
				local strategy_name="${STRATEGIES[$SELECTED_IDX]}"
				info "Saving autostart: $strategy_name"
				install_service "$strategy_name"
			fi
			sleep 1
			;;
		esac
	done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi

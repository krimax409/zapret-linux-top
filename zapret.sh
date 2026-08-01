#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
RUN_DIR="/tmp/zapret-run"
PID_FILE="$RUN_DIR/zapret.pid"
STRATEGY_FILE="$RUN_DIR/zapret.strategy"
IPTABLES_FILE="$RUN_DIR/zapret.iptables"
AUTOSTART_FILE="$SCRIPT_DIR/autostart.conf"
NIX_MODULE="$SCRIPT_DIR/zapret.nix"
SERVICE_NAME="zapret-diy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO_URL="https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.tar.gz"
QNUM=200
FWMARK=0x40000000

# -- Colors ---------------------------------------------------------------
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

# -- Helpers ---------------------------------------------------------------
die()  { echo "${RED}[!]${RST} $*" >&2; exit 1; }
info() { echo "${CYN}[*]${RST} $*"; }
ok()   { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YLW}[~]${RST} $*"; }

# -- System detection ------------------------------------------------------
is_nixos() { [ -f /etc/NIXOS ]; }

# -- Find nfqws ------------------------------------------------------------
find_nfqws() {
    local bin
    bin="$(command -v nfqws 2>/dev/null || true)"
    if [ -z "$bin" ]; then
        info "nfqws not in PATH, resolving from nixpkgs..." >&2
        bin="$(nix-build '<nixpkgs>' -A zapret --no-out-link 2>/dev/null)/bin/nfqws"
    fi
    [ -x "$bin" ] || die "nfqws binary not found. Install zapret package."
    echo "$bin"
}

# -- Status ----------------------------------------------------------------
is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

get_active_strategy() {
    [ -f "$STRATEGY_FILE" ] && cat "$STRATEGY_FILE" 2>/dev/null || echo ""
}

is_autostart_enabled() {
    [ -f "$AUTOSTART_FILE" ]
}

get_autostart_strategy() {
    [ -f "$AUTOSTART_FILE" ] && cat "$AUTOSTART_FILE" 2>/dev/null || echo ""
}

# -- Stop ------------------------------------------------------------------
do_stop() {
    if ! is_running; then
        warn "zapret is not running."
        return 0
    fi
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    info "Stopping nfqws (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true

    if [ -f "$IPTABLES_FILE" ]; then
        info "Removing iptables rules..."
        while IFS= read -r rule; do
            eval "$rule" 2>/dev/null || true
        done < "$IPTABLES_FILE"
        rm -f "$IPTABLES_FILE"
    fi
    rm -f "$PID_FILE" "$STRATEGY_FILE"
    ok "Stopped."
}

# -- Download / Update -----------------------------------------------------
download_repo() {
    info "Downloading from GitHub..."
    local tmp
    tmp=$(mktemp -d)
    if curl -fsSL "$REPO_URL" | tar xz -C "$tmp" --strip-components=1; then
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
        cp "$tmp"/*.bat "$DATA_DIR/" 2>/dev/null || true
        cp -r "$tmp"/bin "$DATA_DIR/"
        cp -r "$tmp"/lists "$DATA_DIR/"
        rm -rf "$tmp"
        ok "Downloaded successfully."
    else
        rm -rf "$tmp"
        die "Download failed."
    fi
}

# -- Prepare runtime dir ---------------------------------------------------
prepare_runtime() {
    mkdir -p "$RUN_DIR/bin" "$RUN_DIR/lists"
    cp "$DATA_DIR"/bin/*.bin "$RUN_DIR/bin/" 2>/dev/null || true
    cp "$DATA_DIR"/lists/* "$RUN_DIR/lists/" 2>/dev/null || true
    chmod -R a+rX "$RUN_DIR"
}

# -- Collect strategies ----------------------------------------------------
collect_strategies() {
    STRATEGIES=()
    local names=()
    local f
    for f in "$DATA_DIR"/general*.bat; do
        [ -f "$f" ] && names+=("$(basename "$f" .bat)")
    done
    local sorted
    sorted=$(printf '%s\n' "${names[@]}" | sort -t'(' -k1,1 -k2V)
    while IFS= read -r name; do
        [ -n "$name" ] && STRATEGIES+=("$name")
    done <<< "$sorted"
}

# -- Parse .bat -> nfqws config -------------------------------------------
# $1=bat_file, $2=mode ("daemon" or "foreground")
parse_bat() {
    local bat_file="$1"
    local mode="${2:-daemon}"
    local raw
    raw=$(tr -d '\r' < "$bat_file" | sed ':a;/\^$/{ N; s/\^\n//; ba }')

    local cmdline
    cmdline=$(echo "$raw" | grep -oP '(?<=winws\.exe[" ]).+' | head -1)
    [ -n "$cmdline" ] || die "Cannot parse: $(basename "$bat_file")"

    WF_TCP=$(echo "$cmdline" | grep -oP '(?<=--wf-tcp=)[^ ]+' | head -1)
    WF_UDP=$(echo "$cmdline" | grep -oP '(?<=--wf-udp=)[^ ]+' | head -1)

    cmdline=$(echo "$cmdline" | sed 's/--wf-tcp=[^ ]* *//g; s/--wf-udp=[^ ]* *//g')
    cmdline=$(echo "$cmdline" | sed 's/,%GameFilter%//g; s/%GameFilter%,//g; s/%GameFilter%//g')
    cmdline=$(echo "$cmdline" | sed "s|\"*%BIN%\([^\"]*\)\"*|@$RUN_DIR/bin/\1|g")
    cmdline=$(echo "$cmdline" | sed "s|\"*%LISTS%\([^\"]*\)\"*|$RUN_DIR/lists/\1|g")
    cmdline=$(echo "$cmdline" | sed 's/\^!/!/g; s/\^//g')
    cmdline=$(echo "$cmdline" | sed 's/ --new --filter-\(tcp\|udp\)= .*$//')
    cmdline=$(echo "$cmdline" | sed 's/^--filter-\(tcp\|udp\)= .*--new //')
    cmdline=$(echo "$cmdline" | sed 's/\(--filter-\(tcp\|udp\)=[^, ]*\),\( \)/\1\3/g')
    cmdline=$(echo "$cmdline" | tr -s ' ')

    WF_TCP=$(echo "$WF_TCP" | sed 's/,%GameFilter%//g; s/%GameFilter%,//g; s/%GameFilter%//g')
    WF_UDP=$(echo "$WF_UDP" | sed 's/,%GameFilter%//g; s/%GameFilter%,//g; s/%GameFilter%//g')

    NFQWS_CONF="$RUN_DIR/nfqws.conf"
    {
        echo "--qnum=$QNUM"
        if [ "$mode" = "daemon" ]; then
            echo "--daemon"
            echo "--pidfile=$PID_FILE"
        fi
        echo "$cmdline" | tr ' ' '\n' | while IFS= read -r arg; do
            [ -n "$arg" ] && echo "$arg"
        done
    } > "$NFQWS_CONF"
    chmod a+r "$NFQWS_CONF"
}

# -- iptables --------------------------------------------------------------
setup_iptables() {
    local tcp_ports="$1"
    local udp_ports="$2"

    modprobe nfnetlink_queue 2>/dev/null || true

    local simple_tcp=() range_tcp=()
    local simple_udp=() range_udp=()

    IFS=',' read -ra tcp_parts <<< "$tcp_ports"
    for p in "${tcp_parts[@]}"; do
        [[ "$p" == *-* ]] && range_tcp+=("$p") || simple_tcp+=("$p")
    done
    IFS=',' read -ra udp_parts <<< "$udp_ports"
    for p in "${udp_parts[@]}"; do
        [[ "$p" == *-* ]] && range_udp+=("$p") || simple_udp+=("$p")
    done

    local mark="-m mark ! --mark $FWMARK/$FWMARK"
    local nfq="-j NFQUEUE --queue-num $QNUM --queue-bypass"
    > "$IPTABLES_FILE"

    if [ ${#simple_tcp[@]} -gt 0 ]; then
        local ports_str
        ports_str=$(IFS=','; echo "${simple_tcp[*]}")
        for cmd in iptables ip6tables; do
            $cmd -t mangle -I POSTROUTING -p tcp -m multiport --dports "$ports_str" $mark $nfq
            echo "$cmd -t mangle -D POSTROUTING -p tcp -m multiport --dports $ports_str $mark $nfq" >> "$IPTABLES_FILE"
        done
    fi
    for range in "${range_tcp[@]}"; do
        local dport="${range/-/:}"
        for cmd in iptables ip6tables; do
            $cmd -t mangle -I POSTROUTING -p tcp --dport "$dport" $mark $nfq
            echo "$cmd -t mangle -D POSTROUTING -p tcp --dport $dport $mark $nfq" >> "$IPTABLES_FILE"
        done
    done
    if [ ${#simple_udp[@]} -gt 0 ]; then
        local ports_str
        ports_str=$(IFS=','; echo "${simple_udp[*]}")
        for cmd in iptables ip6tables; do
            $cmd -t mangle -I POSTROUTING -p udp -m multiport --dports "$ports_str" $mark $nfq
            echo "$cmd -t mangle -D POSTROUTING -p udp -m multiport --dports $ports_str $mark $nfq" >> "$IPTABLES_FILE"
        done
    fi
    for range in "${range_udp[@]}"; do
        local dport="${range/-/:}"
        for cmd in iptables ip6tables; do
            $cmd -t mangle -I POSTROUTING -p udp --dport "$dport" $mark $nfq
            echo "$cmd -t mangle -D POSTROUTING -p udp --dport $dport $mark $nfq" >> "$IPTABLES_FILE"
        done
    done
}

cleanup_iptables_from_file() {
    if [ -f "$IPTABLES_FILE" ]; then
        while IFS= read -r rule; do
            eval "$rule" 2>/dev/null || true
        done < "$IPTABLES_FILE"
        rm -f "$IPTABLES_FILE"
    fi
}

# -- Systemd service -------------------------------------------------------
generate_nix_module() {
    cat > "$NIX_MODULE" <<'NIX'
{ ... }:
{
  systemd.services.zapret-diy = {
    description = "Zapret DPI bypass";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
NIX
    # ExecStart/ExecStopPost need the actual SCRIPT_DIR path
    cat >> "$NIX_MODULE" <<NIX
      ExecStart = "${SCRIPT_DIR}/zapret.sh service-start";
      ExecStopPost = "${SCRIPT_DIR}/zapret.sh service-stop";
NIX
    cat >> "$NIX_MODULE" <<'NIX'
      Restart = "no";
    };
  };
}
NIX
}

nixos_service_exists() {
    systemctl cat "$SERVICE_NAME" &>/dev/null
}

install_service() {
    local strategy_name="$1"

    echo "$strategy_name" > "$AUTOSTART_FILE"

    if is_nixos; then
        if ! nixos_service_exists; then
            generate_nix_module
            warn "NixOS: module generated at ${NIX_MODULE}"
            warn "Copy it to your NixOS config modules dir and add to imports."
            warn "Then run:  nh os switch <config-path>  or  sudo nixos-rebuild switch"
            warn "After that, autostart will work on reboot."
        fi
        ok "Autostart enabled: ${strategy_name}"
    else
        cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Zapret DPI bypass (${strategy_name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/zapret.sh service-start
ExecStopPost=${SCRIPT_DIR}/zapret.sh service-stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        ok "Autostart enabled: ${strategy_name}"
    fi
}

remove_service() {
    if is_nixos; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    else
        if [ -f "$SERVICE_FILE" ]; then
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload
        fi
    fi
    rm -f "$AUTOSTART_FILE"
    ok "Autostart disabled."
}

# -- Service commands (called by systemd) ----------------------------------
cmd_service_start() {
    local strategy_name
    strategy_name=$(get_autostart_strategy)
    if [ -z "$strategy_name" ]; then
        info "No strategy configured in $AUTOSTART_FILE, skipping."
        exit 0
    fi

    local bat_file="$DATA_DIR/${strategy_name}.bat"
    [ -f "$bat_file" ] || die "Strategy file not found: $bat_file"

    local nfqws
    nfqws="$(find_nfqws)"

    prepare_runtime
    parse_bat "$bat_file" foreground

    setup_iptables "$WF_TCP" "$WF_UDP"
    echo "$strategy_name" > "$STRATEGY_FILE"

    exec "$nfqws" "@$NFQWS_CONF"
}

cmd_service_stop() {
    cleanup_iptables_from_file
    rm -f "$PID_FILE" "$STRATEGY_FILE"
}

# -- Launch (manual, daemon mode) ------------------------------------------
do_launch() {
    local strategy_name="$1"
    local bat_file="$DATA_DIR/${strategy_name}.bat"

    [ "$(id -u)" -eq 0 ] || die "nfqws requires root. Run with sudo."

    if is_running; then
        info "Stopping current instance..."
        do_stop
    fi

    local nfqws
    nfqws="$(find_nfqws)"
    ok "nfqws: $nfqws"

    prepare_runtime
    parse_bat "$bat_file" daemon
    ok "Parsed: TCP=$WF_TCP UDP=$WF_UDP"

    # Validate
    local dryconf="$RUN_DIR/nfqws-dry.conf"
    { echo "--dry-run"; grep -vE '^--(daemon|pidfile)' "$NFQWS_CONF"; } > "$dryconf"
    chmod a+r "$dryconf"

    info "Validating..."
    if "$nfqws" "@$dryconf" 2>&1 | grep -q "verified"; then
        ok "Arguments verified."
    else
        warn "Dry-run output:"
        "$nfqws" "@$dryconf" 2>&1 || true
        die "nfqws rejected the arguments."
    fi

    info "Setting up iptables..."
    setup_iptables "$WF_TCP" "$WF_UDP"
    ok "iptables rules active."

    info "Starting nfqws [${strategy_name}] in background..."
    "$nfqws" "@$NFQWS_CONF"

    sleep 0.5
    if is_running; then
        echo "$strategy_name" > "$STRATEGY_FILE"
        ok "Running in background (PID $(cat "$PID_FILE"))."
    else
        cleanup_iptables_from_file
        die "Failed to start nfqws."
    fi
}

# -- TUI -------------------------------------------------------------------
hide_cursor() { printf '\033[?25l'; }
show_cursor() { printf '\033[?25h'; }

draw_menu() {
    local selected=$1
    local total=${#STRATEGIES[@]}
    local running=0
    local active_strategy=""
    local autostart=0
    local autostart_strategy=""

    is_running && running=1 && active_strategy=$(get_active_strategy)
    is_autostart_enabled && autostart=1 && autostart_strategy=$(get_autostart_strategy)

    local term_h
    term_h=$(tput lines 2>/dev/null || echo 24)
    local max_visible=$((term_h - 12))
    [ $max_visible -lt 5 ] && max_visible=5

    local scroll_offset=0
    if [ $selected -ge $max_visible ]; then
        scroll_offset=$((selected - max_visible + 1))
    fi
    local visible_end=$((scroll_offset + max_visible))
    [ $visible_end -gt $total ] && visible_end=$total

    local max_w=0
    for s in "${STRATEGIES[@]}"; do
        [ ${#s} -gt $max_w ] && max_w=${#s}
    done
    local inner_w=$((max_w + 6))
    [ $inner_w -lt 50 ] && inner_w=50

    clear

    # Top border
    local title=" zapret-linux "
    local border_right=$((inner_w - ${#title} - 1))
    printf "  ${DIM}+-%s${RST}${BOLD}${CYN}%s${RST}${DIM}" "-" "$title"
    printf -- '-%.0s' $(seq 1 $border_right)
    printf "+${RST}\n"

    # Status line
    if [ $running -eq 1 ]; then
        local status=" ACTIVE: ${active_strategy} "
        local pad=$((inner_w - ${#status}))
        printf "  ${DIM}|${RST}${BG_GRN}${BOLD}${WHT}%s${RST}%-${pad}s${DIM}|${RST}\n" "$status" ""
    else
        local status=" STOPPED "
        local pad=$((inner_w - ${#status}))
        printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$status" ""
    fi

    # Autostart line
    if [ $autostart -eq 1 ]; then
        local atext=" Autostart: ${autostart_strategy} "
        local pad=$((inner_w - ${#atext}))
        printf "  ${DIM}|${RST}${BG_YLW}${BOLD}%s${RST}%-${pad}s${DIM}|${RST}\n" "$atext" ""
    else
        local atext=" Autostart: off "
        local pad=$((inner_w - ${#atext}))
        printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad}s${DIM}|${RST}\n" "$atext" ""
    fi

    # Blank
    printf "  ${DIM}|${RST}%-${inner_w}s${DIM}|${RST}\n" ""

    # Items
    local i
    for ((i = scroll_offset; i < visible_end; i++)); do
        local name="${STRATEGIES[$i]}"
        if [ $i -eq $selected ]; then
            local text=" > ${name} "
            local pad=$((inner_w - ${#text}))
            printf "  ${DIM}|${RST}${BG_SEL}${BOLD}${WHT}%s%-${pad}s${RST}${DIM}|${RST}\n" "$text" ""
        else
            local prefix="   "
            if [ $running -eq 1 ] && [ "$name" = "$active_strategy" ]; then
                prefix=" ${GRN}*${RST} "
            fi
            local text="${name}"
            local pad=$((inner_w - ${#text} - 3))
            printf "  ${DIM}|${RST}%b%s%-${pad}s${DIM}|${RST}\n" "$prefix" "$text" ""
        fi
    done

    # Scroll indicator
    if [ $total -gt $max_visible ]; then
        local indicator="($((selected + 1))/$total)"
        local pad=$((inner_w - ${#indicator}))
        printf "  ${DIM}|${RST}%-${pad}s%s${DIM}|${RST}\n" "" "$indicator"
    fi

    # Blank
    printf "  ${DIM}|${RST}%-${inner_w}s${DIM}|${RST}\n" ""

    # Hints
    local h1 h2
    if [ $running -eq 1 ]; then
        h1=" [Enter] Switch  [s] Stop  [a] Autostart"
    else
        h1=" [Enter] Launch  [a] Autostart"
    fi
    h2=" [u] Update  [q] Quit"

    local pad1=$((inner_w - ${#h1}))
    [ $pad1 -lt 0 ] && pad1=0
    printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad1}s${DIM}|${RST}\n" "$h1" ""
    local pad2=$((inner_w - ${#h2}))
    [ $pad2 -lt 0 ] && pad2=0
    printf "  ${DIM}|${RST}${DIM}%s${RST}%-${pad2}s${DIM}|${RST}\n" "$h2" ""

    # Bottom border
    printf "  ${DIM}+"
    printf -- '-%.0s' $(seq 1 $((inner_w + 1)))
    printf "+${RST}\n"
}

run_tui() {
    local selected=0
    local total=${#STRATEGIES[@]}

    hide_cursor
    trap 'show_cursor; stty echo 2>/dev/null' RETURN
    stty -echo 2>/dev/null || true

    while true; do
        draw_menu $selected

        local key
        IFS= read -rsn1 key

        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 key2 || true
                case "$key2" in
                    '[A') ((selected > 0)) && ((selected--)) ;;
                    '[B') ((selected < total - 1)) && ((selected++)) ;;
                esac
                ;;
            k|K) ((selected > 0)) && ((selected--)) ;;
            j|J) ((selected < total - 1)) && ((selected++)) ;;
            '')
                show_cursor; stty echo 2>/dev/null || true
                SELECTED_IDX=$selected; TUI_ACTION="launch"
                return 0
                ;;
            s|S)
                if is_running; then
                    show_cursor; stty echo 2>/dev/null || true
                    TUI_ACTION="stop"; return 0
                fi
                ;;
            a|A)
                show_cursor; stty echo 2>/dev/null || true
                SELECTED_IDX=$selected; TUI_ACTION="autostart"
                return 0
                ;;
            u|U)
                show_cursor; stty echo 2>/dev/null || true
                download_repo; collect_strategies
                total=${#STRATEGIES[@]}; selected=0
                hide_cursor; stty -echo 2>/dev/null || true
                ;;
            q|Q)
                show_cursor; stty echo 2>/dev/null || true
                return 1
                ;;
        esac
    done
}

# -- Main ------------------------------------------------------------------
main() {
    # Handle service subcommands (called by systemd)
    case "${1:-}" in
        service-start) cmd_service_start; exit 0 ;;
        service-stop)  cmd_service_stop;  exit 0 ;;
    esac

    if [ ! -d "$DATA_DIR" ] || [ -z "$(find "$DATA_DIR" -maxdepth 1 -name 'general*.bat' 2>/dev/null | head -1)" ]; then
        warn "Strategy data not found."
        download_repo
    fi

    collect_strategies
    [ ${#STRATEGIES[@]} -eq 0 ] && die "No strategies found in $DATA_DIR"

    while true; do
        if ! run_tui; then
            exit 0
        fi

        echo ""

        case "$TUI_ACTION" in
            stop)
                do_stop
                sleep 1
                continue
                ;;
            launch)
                local strategy_name="${STRATEGIES[$SELECTED_IDX]}"
                info "Selected: ${strategy_name}"
                do_launch "$strategy_name"
                sleep 1
                continue
                ;;
            autostart)
                if is_autostart_enabled; then
                    info "Disabling autostart..."
                    remove_service
                else
                    local strategy_name="${STRATEGIES[$SELECTED_IDX]}"
                    info "Enabling autostart: ${strategy_name}"
                    install_service "$strategy_name"
                fi
                sleep 1
                continue
                ;;
        esac
    done
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
source "$ROOT/zapret.sh"

TEST_TMP="$(mktemp -d /tmp/zapret-tests.XXXXXX)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

pass_count=0
fail() {
	echo "not ok - $*" >&2
	exit 1
}
pass() {
	pass_count=$((pass_count + 1))
	echo "ok $pass_count - $*"
}

assert_contains() {
	local file="$1" expected="$2"
	grep -Fx -- "$expected" "$file" >/dev/null || fail "$file does not contain: $expected"
}

assert_rejected() {
	local fixture="$1" expected="$2" log="$TEST_TMP/rejected.log"
	if (parse_bat "$fixture" validate "$TEST_TMP/runtime" disabled "$TEST_TMP/rejected.conf") >"$log" 2>&1; then
		fail "$(basename "$fixture") was accepted"
	fi
	grep -F -- "$expected" "$log" >/dev/null || fail "$(basename "$fixture") did not report: $expected"
}

mkdir -p "$TEST_TMP/runtime/bin" "$TEST_TMP/runtime/lists"
printf 'payload\n' >"$TEST_TMP/runtime/bin/fake.bin"
printf 'domain.example.abc\n' >"$TEST_TMP/runtime/lists/list-general-user.txt"

declare -A expected_tcp=(
	[disabled]='80,443,12'
	[all]='80,443,1024-65535'
	[tcp]='80,443,1024-65535'
	[udp]='80,443,12'
)
declare -A expected_udp=(
	[disabled]='443,12'
	[all]='443,1024-65535'
	[tcp]='443,12'
	[udp]='443,1024-65535'
)

for mode in disabled all tcp udp; do
	config="$TEST_TMP/${mode}.conf"
	parse_bat "$FIXTURES/current-format.bat" validate "$TEST_TMP/runtime" "$mode" "$config"
	[ "$WF_TCP" = "${expected_tcp[$mode]}" ] || fail "$mode TCP ports: $WF_TCP"
	[ "$WF_UDP" = "${expected_udp[$mode]}" ] || fail "$mode UDP ports: $WF_UDP"
	assert_contains "$config" '--hostlist=/tmp/zapret-tests.'"${TEST_TMP##*.}"'/runtime/lists/list-general-user.txt'
	assert_contains "$config" '--dpi-desync-split-seqovl-pattern=@/tmp/zapret-tests.'"${TEST_TMP##*.}"'/runtime/bin/fake.bin'
	if rg -q '%[A-Za-z0-9_]+%' "$config"; then fail "$mode left a placeholder"; fi
done
pass 'current Flowseal placeholders and all game-filter modes'

assert_rejected "$FIXTURES/unknown-placeholder.bat" 'unsupported placeholder %FutureVariable%'
pass 'unknown placeholder is rejected'

assert_rejected "$FIXTURES/missing-file.bat" 'Referenced list does not exist'
pass 'missing referenced file is rejected'

assert_rejected "$FIXTURES/multiple-commands.bat" 'expected one winws.exe command, found 2'
pass 'multiple winws commands are rejected'

# Firewall setup must roll back rules already inserted when the IPv6 command
# fails, otherwise a failed launch leaves traffic intercepted by a dead queue.
FIREWALL_ROOT="$TEST_TMP/firewall"
RUN_DIR="$FIREWALL_ROOT/run"
IPTABLES_FILE="$RUN_DIR/zapret.iptables"
FIREWALL_LOG="$FIREWALL_ROOT/calls.log"
mkdir -p "$RUN_DIR"
iptables() {
	printf 'iptables %s\n' "$*" >>"$FIREWALL_LOG"
}
ip6tables() {
	printf 'ip6tables %s\n' "$*" >>"$FIREWALL_LOG"
	case " $* " in
	*' -I '*) return 1 ;;
	esac
}
modprobe() { :; }
export -f iptables ip6tables modprobe
if (setup_iptables '80,443' '443'); then
	fail 'firewall setup accepted an ip6tables failure'
fi
grep -F -- '-t mangle -D' "$FIREWALL_LOG" >/dev/null || fail 'firewall setup did not roll back inserted rules'
[ ! -e "$IPTABLES_FILE" ] || fail 'firewall rollback left the cleanup file'
pass 'firewall setup rolls back partial rules'

# Stale state must still be cleaned when nfqws has already exited.
RUN_DIR="$TEST_TMP/stale-run"
PID_FILE="$RUN_DIR/zapret.pid"
STRATEGY_FILE="$RUN_DIR/zapret.strategy"
IPTABLES_FILE="$RUN_DIR/zapret.iptables"
STALE_LOG="$TEST_TMP/stale-cleanup.log"
mkdir -p "$RUN_DIR"
printf '%s\n' 999999 >"$PID_FILE"
printf '%s\n' stale >"$STRATEGY_FILE"
printf '%s\n' "iptables -t mangle -D POSTROUTING -p tcp --dport 80" >"$IPTABLES_FILE"
iptables() { printf '%s\n' "$*" >>"$STALE_LOG"; }
export -f iptables
do_stop >/dev/null
[ ! -e "$PID_FILE" ] && [ ! -e "$STRATEGY_FILE" ] && [ ! -e "$IPTABLES_FILE" ] || fail 'stale runtime state was not removed'
grep -F -- '-t mangle -D POSTROUTING' "$STALE_LOG" >/dev/null || fail 'stale firewall rules were not cleaned'
pass 'stop cleans stale runtime state'

# A system nfqws must not bypass the project-local installation.
LOCAL_ROOT="$TEST_TMP/local-zapret"
ZAPRET_INSTALL_DIR="$LOCAL_ROOT"
install_local_zapret() {
	mkdir -p "$ZAPRET_INSTALL_DIR/bin"
	printf '%s\n' local >"$ZAPRET_INSTALL_DIR/bin/nfqws"
	chmod +x "$ZAPRET_INSTALL_DIR/bin/nfqws"
}
resolved_nfQws="$(find_nfqws)"
[ "$resolved_nfQws" = "$ZAPRET_INSTALL_DIR/bin/nfqws" ] || fail 'find_nfqws selected a system binary'
pass 'nfqws is resolved from the local installation'

# NixOS units must remain declarative; the launcher must not create a mutable
# systemd unit there or leave an autostart selection behind.
AUTOSTART_FILE="$TEST_TMP/nixos-autostart.conf"
SERVICE_FILE="$TEST_TMP/nixos.service"
is_nixos() { return 0; }
if (install_service general) >"$TEST_TMP/nixos-autostart.log" 2>&1; then
	fail 'NixOS autostart was enabled'
fi
[ ! -e "$AUTOSTART_FILE" ] || fail 'NixOS autostart selection was written'
grep -F 'not supported on NixOS' "$TEST_TMP/nixos-autostart.log" >/dev/null || fail 'NixOS autostart rejection was not reported'
pass 'NixOS autostart is rejected'

# Exercise the updater with local archives and a fake nfqws validator. This
# verifies transaction boundaries without network access or firewall changes.
UPDATE_ROOT="$TEST_TMP/update-root"
DATA_DIR="$UPDATE_ROOT/data"
DATA_BACKUP_DIR="$UPDATE_ROOT/data.previous"
USER_LISTS_DIR="$UPDATE_ROOT/user-lists"
REPO_URL='fixture://flowseal'
mkdir -p "$DATA_DIR" "$USER_LISTS_DIR"
printf 'old-data\n' >"$DATA_DIR/marker.txt"
printf 'custom.example\n' >"$USER_LISTS_DIR/list-general-user.txt"
printf 'excluded.example\n' >"$USER_LISTS_DIR/list-exclude-user.txt"
printf '198.51.100.1/32\n' >"$USER_LISTS_DIR/ipset-exclude-user.txt"

FAKE_NFQWS="$TEST_TMP/fake-nfqws"
cat >"$FAKE_NFQWS" <<'EOF'
#!/usr/bin/env bash
grep -Fx -- '--dry-run' "${1#@}" >/dev/null || exit 1
echo 'command line parameters verified'
EOF
chmod +x "$FAKE_NFQWS"
find_nfqws() { echo "$FAKE_NFQWS"; }

make_update_archive() {
	local fixture="$1" archive="$2" tree="$TEST_TMP/archive-tree"
	rm -rf -- "$tree"
	mkdir -p "$tree/release/bin" "$tree/release/lists" "$tree/release/.service"
	cp "$fixture" "$tree/release/general.bat"
	cp "$fixture" "$tree/release/service.bat"
	printf 'payload\n' >"$tree/release/bin/fake.bin"
	printf 'base.example\n' >"$tree/release/lists/list-general.txt"
	printf 'exclude.example\n' >"$tree/release/lists/list-exclude.txt"
	printf '203.0.113.0/24\n' >"$tree/release/lists/ipset-exclude.txt"
	printf 'test-version\n' >"$tree/release/.service/version.txt"
	tar czf "$archive" -C "$tree" release
}

GOOD_ARCHIVE="$TEST_TMP/good.tar.gz"
BAD_ARCHIVE="$TEST_TMP/bad.tar.gz"
make_update_archive "$FIXTURES/current-format.bat" "$GOOD_ARCHIVE"
make_update_archive "$FIXTURES/unknown-placeholder.bat" "$BAD_ARCHIVE"
ACTIVE_ARCHIVE="$GOOD_ARCHIVE"
curl() { command cat "$ACTIVE_ARCHIVE"; }

download_repo >/dev/null
[ -f "$DATA_DIR/general.bat" ] || fail 'successful update did not activate candidate data'
[ "$(cat "$DATA_BACKUP_DIR/marker.txt")" = old-data ] || fail 'successful update did not preserve previous data'
[ "$(cat "$USER_LISTS_DIR/list-general-user.txt")" = custom.example ] || fail 'successful update changed user lists'
pass 'successful update is atomic and preserves user lists'

printf 'working-data\n' >"$DATA_DIR/marker.txt"
before_hash="$(sha256sum "$DATA_DIR/general.bat" | cut -d' ' -f1)"
ACTIVE_ARCHIVE="$BAD_ARCHIVE"
if download_repo >"$TEST_TMP/update-rejected.log" 2>&1; then
	fail 'incompatible update was accepted'
fi
[ "$(cat "$DATA_DIR/marker.txt")" = working-data ] || fail 'rejected update changed current data'
[ "$(sha256sum "$DATA_DIR/general.bat" | cut -d' ' -f1)" = "$before_hash" ] || fail 'rejected update replaced current strategy'
grep -F 'Update rejected' "$TEST_TMP/update-rejected.log" >/dev/null || fail 'rejected update was not reported'
pass 'incompatible update leaves current data unchanged'

echo "1..$pass_count"

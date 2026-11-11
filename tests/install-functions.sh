#!/bin/bash
# Run the removal helpers of install.sh against stub system commands.
# Needs no root and changes nothing outside a temporary directory.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'command rm -rf -- "$work"' EXIT
# shellcheck source=/dev/null
source <(sed -n '/^# BEGIN REMOVAL HELPERS/,/^# END REMOVAL HELPERS$/p' "$root/install.sh")
declare -F rules_present cascade_processes deactivate remove_files uninstall >/dev/null

# Variables read by the sourced helpers.
# shellcheck disable=SC2034
{
    LIBDIR=$work/lib PROGRAM=$work/lib/cascade.py COMMAND=$work/bin/cascade CONFIG=$work/etc
    UNIT=$work/unit/cascade.service WANTS=$work/wants/cascade.service PYTHON=fake_python
    PROC=$work/proc PROC_UID=$(id -u) LEGACY_TABLES=$work/ip_tables_names
}
calls=$work/calls
# Keep the real process scan for the /proc model below, then stub it.
eval "real_$(declare -f cascade_processes)"

# Stubs. Each variant of iptables-save prints $work/<variant>.out and exits
# with the status in $work/<variant>.status.
iptables-nft-save() { cat "$work/nft.out"; return "$(cat "$work/nft.status")"; }
iptables-legacy-save() { cat "$work/legacy.out"; return "$(cat "$work/legacy.status")"; }
fake_python() {
    if [[ $2 == -c ]]; then  # the state.json check in rules_present
        if grep -q '"proto"' "${!#}"; then return 3; fi
        if grep -q '"rules": \[\]' "${!#}"; then return 0; fi
        return 1
    fi
    echo "manager ${*:3}" >>"$calls"  # "clear" removes nft rules only
    : >"$work/nft.out"
}
systemctl() {
    echo "systemctl $*" >>"$calls"
    if [[ $1 == show ]]; then echo loaded; fi
    if [[ $1 == daemon-reload && -e $work/reload.fails ]]; then return 1; fi
    return 0
}
flock() { :; }
cascade_processes() { if [[ -e $work/processes ]]; then cat "$work/processes"; fi; }
rm() {  # fails only when removing the path written to $work/rm.fails
    local arg
    if [[ -e $work/rm.fails ]]; then
        for arg in "$@"; do
            if [[ $arg == "$(cat "$work/rm.fails")" ]]; then return 1; fi
        done
    fi
    command rm "$@"
}

reset() {
    command rm -rf -- "$work/lib" "$work/bin" "$work/etc" "$work/unit" "$work/processes" \
        "$work/rm.fails" "$work/reload.fails" "$LEGACY_TABLES" "$PROC"
    : >"$calls"
    : >"$work/nft.out"
    : >"$work/legacy.out"
    echo 0 >"$work/nft.status"
    echo 0 >"$work/legacy.status"
}
installed() {
    reset
    mkdir -p "$LIBDIR" "$CONFIG" "${COMMAND%/*}" "${UNIT%/*}"
    touch "$PROGRAM" "$COMMAND" "$UNIT" "$CONFIG/.lock" "$CONFIG/.state-x"
    echo '{"version": 2, "rules": [], "backend": null}' >"$CONFIG/state.json"
}
expect() {
    local want=$1 got=0
    shift
    "$@" 2>>"$work/stderr" || got=$?
    [[ $got == "$want" ]] || { echo "FAIL: '$*' returned $got, expected $want" >&2; cat "$work/stderr" >&2; exit 1; }
}
fail() { echo "FAIL: $*" >&2; exit 1; }
kept() { [[ -e $PROGRAM && -e $UNIT && -e $CONFIG/state.json ]] || fail "$1: files were removed"; }
gone() {
    local path
    for path in "$LIBDIR" "$COMMAND" "$UNIT" "$CONFIG"; do
        [[ ! -e $path ]] || fail "$1: $path left behind"
    done
}

# rules_present distinguishes present (0), absent (1) and unknown (2).
reset
expect 1 rules_present
echo '-A FORWARD -m comment --comment "cascade:v2" -j CSCD_FWD' >"$work/legacy.out"
expect 0 rules_present
reset
echo 1 >"$work/legacy.status"
expect 2 rules_present
installed
echo '{"version": 2, "rules": [{"proto": "tcp"}], "backend": "nft"}' >"$CONFIG/state.json"
expect 0 rules_present
echo '{broken' >"$CONFIG/state.json"
expect 2 rules_present
# A missing iptables-save proves nothing, except for legacy rules when the
# kernel provably has no legacy tables. Real binaries live in /usr/sbin, so a
# PATH without it hides them while keeping coreutils.
reset
(unset -f iptables-nft-save; PATH=/usr/bin:/bin; expect 2 rules_present)
(unset -f iptables-nft-save iptables-legacy-save; PATH=/usr/bin:/bin; expect 2 rules_present)
legacy_missing() { (unset -f iptables-legacy-save; PATH=/usr/bin:/bin; expect "$1" rules_present); }
legacy_missing 1                          # no list in /proc/net: ip_tables is not loaded
: >"$LEGACY_TABLES"
legacy_missing 1                          # list read and empty
echo filter >"$LEGACY_TABLES"
legacy_missing 2                          # legacy tables exist
command rm -f -- "$LEGACY_TABLES"
mkdir -- "$LEGACY_TABLES"
legacy_missing 2                          # the list exists but cannot be read
command rm -rf -- "$LEGACY_TABLES"
(LEGACY_TABLES=$work/no-proc-net/ip_tables_names; legacy_missing 2)  # /proc/net itself is missing

# Every way to start a CascadeVPN manager is found in a model of /proc.
reset
proc_entry() {  # pid cwd argv...
    local pid=$1 cwd=$2
    shift 2
    mkdir -p "$PROC/$pid"
    printf '%s\0' "$@" >"$PROC/$pid/cmdline"
    ln -s -- "$cwd" "$PROC/$pid/cwd"
}
mkdir -p "$LIBDIR" "${COMMAND%/*}"
proc_entry 101 "$LIBDIR" python3 -I ./cascade.py menu  # relative, from the install dir
proc_entry 102 / /usr/bin/python3 -I "$COMMAND"         # the cascade command
proc_entry 103 / python3 /root/CascadeVPN/cascade.py menu  # a clone or copy
proc_entry 104 "${COMMAND%/*}" python3.11 -I ./cascade  # relative command path
proc_entry 105 "$LIBDIR" python3 -I ../lib/cascade.py
proc_entry 106 / /usr/bin/python "$COMMAND" menu        # python-is-python3
proc_entry 201 / python3 -I /srv/other.py               # unrelated programs
proc_entry 202 "$LIBDIR" bash ./cascade.py
proc_entry 203 / python3
expected='101 102 103 104 105 106 '
if [[ ! -L $PROC/104/cwd ]]; then  # e.g. Git Bash without symlink rights; CI runs on Linux
    echo 'SKIP: no symlinks here, relative command path not checked' >&2
    expected='101 102 103 105 106 '
fi
found=$(real_cascade_processes | sort | tr '\n' ' ')
[[ $found == "$expected" ]] || fail "process scan found '$found', expected '$expected'"

# Partial installation without program and configuration: a missing nft
# tool must not let removal claim success.
installed
command rm -- "$PROGRAM" "$CONFIG/state.json"
(unset -f iptables-nft-save; PATH=/usr/bin:/bin; expect 1 uninstall)
[[ -e $UNIT && -e $COMMAND ]] || fail 'missing nft tool: files were removed'

# A clean installation is removed completely.
installed
expect 0 uninstall
gone 'clean removal'
grep -q 'systemctl disable cascade.service' "$calls" || fail 'unit was not disabled'

# Rules are removed by the manager and verified afterwards.
installed
echo '-A FORWARD -m comment --comment "cascade:v2" -j CSCD_FWD' >"$work/nft.out"
expect 0 uninstall
grep -q 'manager clear --yes --deactivate' "$calls" || fail 'manager did not clear rules'
gone 'removal with rules'

# Rules left in the other iptables variant block removal.
installed
echo '-A FORWARD -m comment --comment "cascade:v2" -j CSCD_FWD' >"$work/legacy.out"
expect 1 uninstall
kept 'rules left after cleanup'

# An unreadable firewall is never treated as an empty one.
installed
command rm -- "$PROGRAM"
echo 1 >"$work/legacy.status"
expect 1 uninstall
[[ -e $UNIT && -e $CONFIG/state.json ]] || fail 'unknown firewall: files were removed'
grep -q 'systemctl disable cascade.service' "$calls" || fail 'unknown firewall: unit stayed enabled'

# Failed file removal or daemon-reload is reported.
for path in "$PROGRAM" "$CONFIG/.lock"; do
    installed
    echo "$path" >"$work/rm.fails"
    expect 1 uninstall
done
installed
touch "$work/reload.fails"
expect 1 uninstall

# An open CascadeVPN process keeps the lock with the removal mark.
installed
echo 4242 >"$work/processes"
expect 0 uninstall
[[ ! -e $PROGRAM && ! -e $UNIT && ! -e $CONFIG/state.json && ! -e $CONFIG/.state-x ]] || fail 'open menu: files kept'
grep -qx disabled "$CONFIG/.lock" || fail 'open menu: lock removed or not marked'
command rm -- "$work/processes"
expect 0 uninstall
gone 'second removal after the menu closed'

echo 'PASS: install.sh removal helpers'

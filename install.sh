#!/bin/bash
# Install the Cascade manager and systemd service.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
REPO=https://raw.githubusercontent.com/WeirdPhrog/Cascade/main
EXPECTED_SHA256=11c550109fe70fc96de1e8d26f4e30c77d3b260805ae3cebea75647d5636ecf3
LIBDIR=/usr/local/lib/cascade
PROGRAM=$LIBDIR/cascade.py
COMMAND=/usr/local/bin/cascade
CONFIG=/etc/cascade
UNIT=/etc/systemd/system/cascade.service
WANTS=/etc/systemd/system/multi-user.target.wants/cascade.service
PYTHON=/usr/bin/python3
# Kernel views used by the removal helpers (replaced by tests/install-functions.sh).
PROC=/proc
PROC_UID=0
LEGACY_TABLES=/proc/net/ip_tables_names
NO_MENU=0
ACTION=install
case "${1:-}" in
    --no-menu) NO_MENU=1 ;;
    --uninstall) ACTION=uninstall ;;
    --help) printf '%s\n' 'sudo bash install.sh [--no-menu|--uninstall]'; exit 0 ;;
    '') ;;
    *) printf '%s\n' 'Неизвестный параметр. Используйте --help.' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
[[ $EUID -eq 0 && $(uname -s) == Linux ]] || { echo 'Нужен Linux и sudo/root.' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'Нужна система с работающим systemd.' >&2; exit 1; }
# /run is writable only by root; /run/lock is world-writable on Debian/Ubuntu,
# where another local user could pre-create or hold this file.
exec 9>/run/cascade-install.lock
flock -x 9

# Apply the same ownership checks to installation and removal.
for directory in /etc/cascade /usr/local/lib/cascade; do
    [[ ! -L $directory ]] || { echo "Символическая ссылка вместо $directory" >&2; exit 1; }
    if [[ -e $directory ]] && [[ ! -d $directory || $(stat -c %u "$directory") != 0 ]]; then
        echo "Каталог $directory должен принадлежать root." >&2; exit 1
    fi
done
for file in "$PROGRAM" "$UNIT" /etc/cascade/state.json /etc/cascade/.lock; do
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || {
        echo "Ожидался обычный файл: $file" >&2; exit 1;
    }
done
if [[ -e /usr/local/bin/cascade || -L /usr/local/bin/cascade ]]; then
    [[ $(readlink /usr/local/bin/cascade || true) == "$PROGRAM" ]] || {
        echo 'Файл /usr/local/bin/cascade принадлежит другой программе.' >&2; exit 1;
    }
fi
if [[ -e $UNIT ]] && ! grep -q '^# Cascade managed unit$' "$UNIT"; then
    echo "Файл $UNIT не принадлежит Cascade." >&2; exit 1
fi
if [[ -e $PROGRAM ]] && ! grep -Fxq '"""IPv4 relay: only tagged Cascade chains and hooks are modified."""' "$PROGRAM"; then
    echo "Файл $PROGRAM не принадлежит Cascade." >&2; exit 1
fi

# BEGIN REMOVAL HELPERS (tests/install-functions.sh runs them with stub commands)
# Every helper reports failure through its status: callers use them in
# conditions, where set -e does not apply.

# Returns 0 if Cascade rules exist, 1 if there are none, 2 if unknown.
rules_present() {
    local save output status=0 result=1
    if [[ -e $CONFIG/state.json ]]; then
        "$PYTHON" -I -c 'import json, sys
sys.exit(3 if json.load(open(sys.argv[1], encoding="utf-8"))["rules"] else 0)' "$CONFIG/state.json" 2>/dev/null || status=$?
        if [[ $status == 3 ]]; then
            return 0
        elif [[ $status != 0 ]]; then
            echo "Не удалось прочитать $CONFIG/state.json." >&2
            result=2
        fi
    fi
    # Both variants: rules may remain in the one that is no longer selected.
    # A missing tool proves nothing (it may be removed after rules were
    # applied), except that the kernel lists no legacy tables at all.
    for save in iptables-nft-save iptables-legacy-save; do
        if ! command -v "$save" >/dev/null; then
            if [[ $save == iptables-legacy-save && -z $(cat -- "$LEGACY_TABLES" 2>/dev/null) ]]; then
                continue
            fi
            echo "Нет $save: правила этого варианта iptables проверить нельзя." \
                'Установите пакет iptables и повторите.' >&2
            result=2
        elif ! output=$("$save" 2>&1); then
            echo "Не удалось проверить firewall командой $save: ${output%%$'\n'*}" >&2
            result=2
        elif [[ $output == *cascade:v2* ]]; then
            return 0
        fi
    done
    return "$result"
}

# PIDs of running Cascade managers (open menus or commands), one per line.
# A false match only keeps the lock file, so matching is deliberately broad:
# any root Python process with an argument named cascade.py (an installed
# file, a copy or a clone), or with a path that resolves to the program or
# the command, also relative to the process's working directory.
cascade_processes() {
    local dir arg args cwd path
    for dir in "$PROC"/[0-9]*; do
        [[ $(stat -c %u "$dir" 2>/dev/null) == "$PROC_UID" ]] || continue
        mapfile -d '' -t args 2>/dev/null <"$dir/cmdline" || continue
        [[ ${#args[@]} -gt 1 && ${args[0]##*/} == python* ]] || continue
        cwd=$(readlink -- "$dir/cwd" 2>/dev/null) || cwd=/
        cwd=${cwd% (deleted)}
        for arg in "${args[@]:1}"; do
            if [[ $arg == /* ]]; then path=$arg; else path=$cwd/$arg; fi
            path=$(realpath -m -- "$path" 2>/dev/null) || path=
            if [[ ${arg##*/} == cascade.py || $path == "$PROGRAM" || $path == "$COMMAND" ]]; then
                echo "${dir##*/}"
                break
            fi
        done
    done
    return 0
}

# Every later command, including one already waiting for this lock, reads the
# mark after locking and stops. cascade.py never recreates a removed lock.
deactivate() {
    [[ -f $CONFIG/.lock ]] || return 0
    exec 8>>"$CONFIG/.lock" || return 1
    if ! flock -w 90 8; then
        exec 8>&-
        echo "Блокировку $CONFIG/.lock не отпускает другой процесс Cascade (PID: $(cascade_processes | tr '\n' ' '))." \
            'Закройте его и повторите удаление.' >&2
        return 1
    fi
    if ! printf 'disabled\n' >&8; then
        exec 8>&-
        return 1
    fi
    exec 8>&-
}

# Only Cascade's own files are removed; foreign files were rejected above.
remove_files() {
    local pids dir
    if [[ -L $WANTS && $(readlink "$WANTS") == "$UNIT" ]]; then
        rm -f -- "$WANTS" || return 1
    fi
    # Stopping also cancels a pending automatic restart. Without the program
    # ExecStop cannot run, but rules_present has already found no rules.
    if [[ $(systemctl show -p LoadState --value cascade.service 2>/dev/null) == loaded ]]; then
        systemctl stop cascade.service || [[ ! -f $PROGRAM ]] || return 1
        systemctl reset-failed cascade.service 2>/dev/null || true
    fi
    rm -f -- "$UNIT" "$COMMAND" "$PROGRAM" "$LIBDIR/.cascade.py.new" \
        "$CONFIG/state.json" "$CONFIG"/.state-* || return 1
    # A menu opened before an upgrade still runs old code, which would
    # recreate a missing lock without the removal mark and keep working.
    pids=$(cascade_processes) || return 1
    if [[ -n $pids ]]; then
        echo "Открыты процессы Cascade (PID: ${pids//$'\n'/ })." \
            "$CONFIG/.lock оставлен с отметкой удаления: они не смогут изменить firewall." \
            'Закройте их и повторите удаление, чтобы убрать и этот файл.' >&2
    else
        rm -f -- "$CONFIG/.lock" || return 1
    fi
    # Directories stay only if something else is left in them.
    rmdir "$LIBDIR" 2>/dev/null || true
    rmdir "$CONFIG" 2>/dev/null || true
    systemctl daemon-reload || return 1
    systemctl reset-failed cascade.service 2>/dev/null || true
    for dir in "$LIBDIR" "$CONFIG"; do
        if [[ -e $dir && ! ( $dir == "$CONFIG" && -n $pids ) ]]; then
            echo "Каталог $dir не удалён: в нём есть посторонние файлы." >&2
        fi
    done
    return 0
}

# Shared by --uninstall and by the rollback of a first installation.
uninstall() {
    local found=0
    deactivate || return 1
    if [[ -e $UNIT ]]; then
        # Even if cleanup stops below, nothing is applied again after reboot.
        systemctl disable cascade.service || return 1
    fi
    rules_present || found=$?
    if [[ $found != 1 ]]; then
        if [[ ! -f $PROGRAM ]]; then
            if [[ $found == 0 ]]; then
                echo "Найдены правила Cascade, но нет $PROGRAM. Запустите установку, затем удаление." >&2
            fi
            return 1
        fi
        "$PYTHON" -I "$PROGRAM" clear --yes --deactivate || return 1
        # Never report removal while tagged rules may still be active, e.g.
        # in the iptables variant that was selected before.
        found=0
        rules_present || found=$?
        if [[ $found == 0 ]]; then
            echo 'После очистки в firewall остались правила с меткой cascade:v2 (возможно, в другом варианте iptables).' \
                'Удалите их вручную и повторите удаление.' >&2
        fi
        [[ $found == 1 ]] || return 1
    fi
    remove_files
}
# END REMOVAL HELPERS

# A firewall snapshot saved while Cascade was active would restore it at boot.
warn_saved() {
    local file
    for file in /etc/iptables/rules.v4 /etc/iptables.rules /etc/iptables.up.rules; do
        if [[ -f $file ]] && grep -Eq 'cascade:v2|^:CSCD_(DNAT|SNAT|FWD) ' "$file"; then
            echo "Внимание: $file содержит правила или цепочки Cascade; загрузчик firewall вернёт их после перезагрузки." >&2
            echo 'Пересохраните текущие правила (например, sudo netfilter-persistent save) или удалите из файла' \
                'строки с cascade:v2 и объявления цепочек :CSCD_DNAT, :CSCD_SNAT, :CSCD_FWD.' >&2
        fi
    done
    return 0
}

if [[ $ACTION == uninstall ]]; then
    installed=0
    for path in "$PROGRAM" "$UNIT" "$COMMAND" "$LIBDIR" "$CONFIG"; do
        if [[ -e $path || -L $path ]]; then installed=1; fi
    done
    if [[ -L $WANTS && $(readlink "$WANTS") == "$UNIT" ]]; then installed=1; fi
    if [[ $installed == 0 ]]; then
        found=0
        rules_present || found=$?
        if [[ $found == 1 ]]; then
            echo 'Cascade не установлен.'
            warn_saved
            exit 0
        fi
        [[ $found == 2 ]] || echo 'Cascade не установлен, но в firewall есть правила с меткой cascade:v2. Установите Cascade и запустите удаление.' >&2
        warn_saved
        exit 1
    fi
    if ! uninstall; then
        echo 'Удаление не завершено (см. ошибку выше). Устраните её и повторите удаление;' \
            'чтобы вернуть Cascade в работу, запустите установку.' >&2
        exit 1
    fi
    warn_saved
    echo 'Cascade удалён. Системные пакеты и чужой firewall сохранены.'
    exit 0
fi

# shellcheck disable=SC1091
source /etc/os-release
case "$ID:${VERSION_ID:-}" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) echo 'Поддерживаются Debian 12/13 и Ubuntu 22.04/24.04.' >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3 iptables nftables conntrack iproute2 ca-certificates curl

scratch=$(mktemp -d /tmp/cascade-install.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $source_dir/cascade.py ]]; then
    cp -- "$source_dir/cascade.py" "$scratch/cascade.py"
else
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 15 --max-time 120 "$REPO/cascade.py" -o "$scratch/cascade.py"
fi
printf '%s  %s\n' "$EXPECTED_SHA256" "$scratch/cascade.py" | sha256sum --check --status || {
    echo 'Контрольная сумма cascade.py не совпала. Скачайте install.sh и cascade.py одной версии.' >&2; exit 1;
}
/usr/bin/python3 -I "$scratch/cascade.py" --version
cat > "$scratch/cascade.service" <<'UNIT'
# Cascade managed unit
[Unit]
Description=Cascade IPv4 TCP/UDP relay
Wants=network-online.target
After=network-online.target nftables.service netfilter-persistent.service ufw.service firewalld.service docker.service
# Retry for several minutes if an address or route appears late after boot.
StartLimitIntervalSec=10min
StartLimitBurst=20

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=20s
ExecStart=/usr/bin/python3 -I /usr/local/lib/cascade/cascade.py apply
ExecReload=/usr/bin/python3 -I /usr/local/lib/cascade/cascade.py apply
ExecStop=/usr/bin/python3 -I /usr/local/lib/cascade/cascade.py stop
TimeoutStartSec=90
TimeoutStopSec=90
UMask=0077
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=/etc/cascade
# Legacy iptables inspection uses a raw socket even though it is read-only.
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT

had_program=0
had_unit=0
was_enabled=0
was_active=0
[[ ! -f $PROGRAM ]] || { cp -- "$PROGRAM" "$scratch/old.py"; had_program=1; }
[[ ! -f $UNIT ]] || { cp -- "$UNIT" "$scratch/old.service"; had_unit=1; }
systemctl is-enabled --quiet cascade.service 2>/dev/null && was_enabled=1
systemctl is-active --quiet cascade.service 2>/dev/null && was_active=1
rollback() {
    local result=${1:-$?}
    trap - ERR INT TERM
    set +e
    journalctl -u cascade.service -n 30 --no-pager >&2
    if [[ $had_program == 0 ]]; then
        # Cascade was not installed before: remove everything this run created.
        if uninstall; then
            echo 'Установка не завершена; созданные файлы удалены. Проверьте ошибки выше.' >&2
        else
            echo 'Откат не завершён, автозапуск отключён. Устраните ошибку выше и выполните: sudo bash install.sh --uninstall' >&2
        fi
        exit "$result"
    fi
    install -m 0755 "$scratch/old.py" "$PROGRAM"
    [[ $had_unit == 0 ]] || install -m 0644 "$scratch/old.service" "$UNIT"
    systemctl daemon-reload
    # Return the unit to its previous state while its file still exists.
    [[ $was_active == 1 ]] || systemctl stop cascade.service
    [[ $was_enabled == 1 ]] || systemctl disable cascade.service
    if [[ $had_unit == 0 ]]; then
        rm -f -- "$UNIT"
        systemctl daemon-reload
    fi
    [[ $was_active == 0 ]] || systemctl reload cascade.service
    echo 'Установка не завершена; предыдущие файлы восстановлены. Проверьте ошибки выше.' >&2
    exit "$result"
}
trap rollback ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM
install -d -o root -g root -m 0700 /etc/cascade
install -d -o root -g root -m 0755 /usr/local/lib/cascade
install -m 0755 "$scratch/cascade.py" /usr/local/lib/cascade/.cascade.py.new
mv -f -- /usr/local/lib/cascade/.cascade.py.new "$PROGRAM"
ln -sfn -- "$PROGRAM" /usr/local/bin/cascade
install -m 0644 "$scratch/cascade.service" "$UNIT"
# Re-enable commands after an unfinished removal, without replacing the lock inode.
exec 8>>/etc/cascade/.lock
flock -x 8
: >/etc/cascade/.lock
flock -u 8
exec 8>&-
systemctl daemon-reload
systemctl enable cascade.service
if [[ $was_active == 1 ]]; then
    systemctl reload cascade.service
else
    systemctl start cascade.service
fi
trap - ERR INT TERM
echo 'Cascade установлен. Команда: cascade; справка: cascade --help'
if [[ $NO_MENU == 0 && -t 0 ]]; then
    flock -u 9
    exec /usr/bin/python3 -I "$PROGRAM" menu
fi

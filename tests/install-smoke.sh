#!/bin/bash
# Run only on an expendable GitHub Actions VM (uses the actual systemd).
set -Eeuo pipefail
# Never use this fixture on an existing installation.
for file in /usr/local/lib/cascade/cascade.py /usr/local/bin/cascade /etc/systemd/system/cascade.service; do
    [[ ! -e $file && ! -L $file ]] || { echo "Test requires a fresh VM: $file" >&2; exit 1; }
done
sudo bash install.sh --no-menu
sudo systemctl is-enabled --quiet cascade.service
sudo systemctl is-active --quiet cascade.service
sudo cascade list
sudo cascade --version

# Exercise the real unit with saved rules, while all network changes stay in a netns.
namespace="cascade-smoke-$$"
scratch=$(mktemp -d)
cleanup() {
    sudo journalctl -u cascade.service -n 40 --no-pager
    sudo systemctl stop cascade.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/cascade.service.d/network-test.conf
    sudo rm -f /etc/systemd/system/cascade.service.d/failure-test.conf
    sudo rm -f /etc/systemd/system/cascade.service.d/start-failure-test.conf
    sudo rmdir /etc/systemd/system/cascade.service.d 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo ip netns delete "$namespace" 2>/dev/null || true
    rm -rf -- "$scratch"
}
trap cleanup EXIT
# Removal leaves no CascadeVPN file, directory, enablement link or failed unit.
assert_removed() {
    local path
    for path in /usr/local/lib/cascade /usr/local/bin/cascade /etc/cascade /etc/systemd/system/cascade.service \
        /etc/systemd/system/multi-user.target.wants/cascade.service /run/lock/cascade-install.lock; do
        [[ ! -e $path && ! -L $path ]] || { echo "Left behind: $path" >&2; exit 1; }
    done
    [[ $(systemctl show -p ActiveState --value cascade.service) == inactive ]] || {
        echo 'cascade.service is still active or failed' >&2; exit 1;
    }
}
sudo ip netns add "$namespace"
sudo ip -n "$namespace" link set lo up
sudo ip -n "$namespace" link add relay0 type dummy
sudo ip -n "$namespace" addr add 198.18.0.1/24 dev relay0
sudo ip -n "$namespace" link set relay0 up
sudo ip netns exec "$namespace" sysctl -w net.ipv4.ip_forward=0
sudo systemctl stop cascade.service
sudo mkdir -p /etc/systemd/system/cascade.service.d
printf '[Service]\nNetworkNamespacePath=/run/netns/%s\n' "$namespace" | sudo tee /etc/systemd/system/cascade.service.d/network-test.conf
sudo systemctl daemon-reload
sudo systemctl start cascade.service
sudo ip netns exec "$namespace" cascade add --proto udp --listen 198.18.0.1 --in-port 45000 --target 198.18.0.2 --out-port 45001
sudo bash install.sh --no-menu
sudo systemctl reload cascade.service
sudo systemctl restart cascade.service
sudo ip netns exec "$namespace" iptables -t nat -S CSCD_DNAT
[[ $(sudo ip netns exec "$namespace" sysctl -n net.ipv4.ip_forward) == 1 ]]
sudo systemctl stop cascade.service
if sudo ip netns exec "$namespace" iptables -t nat -S CSCD_DNAT; then
    echo 'Chain survived service stop' >&2
    exit 1
fi
[[ $(sudo ip netns exec "$namespace" sysctl -n net.ipv4.ip_forward) == 1 ]]
sudo systemctl start cascade.service
sudo ip netns exec "$namespace" iptables -t nat -S CSCD_DNAT
sudo systemd-analyze verify /etc/systemd/system/cascade.service
# Reinstall must restore the previous executable when systemd reload fails.
python3 - "$scratch" <<'PY'
import hashlib, re, sys
from pathlib import Path
destination = Path(sys.argv[1])
program = Path('/usr/local/lib/cascade/cascade.py').read_bytes()
(destination / 'before.py').write_bytes(program)
candidate = program + b'\n# Temporary install test candidate.\n'
(destination / 'cascade.py').write_bytes(candidate)
script = Path('install.sh').read_text()
(destination / 'install.sh').write_text(re.sub(r'EXPECTED_SHA256=[0-9a-f]+', 'EXPECTED_SHA256=' + hashlib.sha256(candidate).hexdigest(), script))
PY
sudo cp /etc/cascade/state.json "$scratch/before.json"
printf '[Service]\nExecReload=\nExecReload=/bin/false\n' | sudo tee /etc/systemd/system/cascade.service.d/failure-test.conf
sudo systemctl daemon-reload
if sudo bash "$scratch/install.sh" --no-menu; then
    echo 'Failed reload was reported as a successful install' >&2; exit 1
fi
cmp "$scratch/before.py" /usr/local/lib/cascade/cascade.py
sudo cmp "$scratch/before.json" /etc/cascade/state.json
sudo ip netns exec "$namespace" iptables -t nat -S CSCD_DNAT
sudo rm /etc/systemd/system/cascade.service.d/failure-test.conf
sudo systemctl daemon-reload
sudo systemctl reload cascade.service
# A symlink used as a lock must not truncate or chmod its target.
printf 'foreign data\n' > "$scratch/foreign-lock"
sudo mv /etc/cascade/.lock "$scratch/real-lock"
sudo ln -s "$scratch/foreign-lock" /etc/cascade/.lock
if sudo bash install.sh --no-menu; then
    echo 'Installer followed a lock symlink' >&2; exit 1
fi
if sudo ip netns exec "$namespace" cascade apply; then
    echo 'Manager followed a lock symlink' >&2; exit 1
fi
[[ $(cat "$scratch/foreign-lock") == 'foreign data' ]]
sudo rm /etc/cascade/.lock
sudo mv "$scratch/real-lock" /etc/cascade/.lock
# Removal must not delete a command now belonging to someone else.
sudo rm /usr/local/bin/cascade
printf 'foreign command\n' | sudo tee /usr/local/bin/cascade
if sudo bash install.sh --uninstall; then
    echo 'Uninstall accepted a foreign command' >&2; exit 1
fi
[[ $(cat /usr/local/bin/cascade) == 'foreign command' ]]
sudo ip netns exec "$namespace" iptables -t nat -S CSCD_DNAT
sudo rm /usr/local/bin/cascade
sudo ln -s /usr/local/lib/cascade/cascade.py /usr/local/bin/cascade
sudo ip netns exec "$namespace" bash install.sh --uninstall
assert_removed
if sudo ip netns exec "$namespace" iptables-save | grep -F 'cascade:v2'; then
    echo 'Uninstall left tagged rules' >&2; exit 1
fi
sudo bash install.sh --uninstall
# A subsequent clean installation must work after a complete removal.
sudo bash install.sh --no-menu
sudo ip netns exec "$namespace" cascade add --proto udp --listen 198.18.0.1 --in-port 45000 --target 198.18.0.2
sudo ip netns exec "$namespace" bash install.sh --uninstall
assert_removed
# A menu left open during removal may still run the previous release, which
# recreates a missing lock. The lock stays marked until the menu is closed.
curl -fsSL --retry 3 -o "$scratch/old.py" \
    https://raw.githubusercontent.com/WeirdPhrog/CascadeVPN/309ab3d451fa2499ca5460b8d75bab96814e1c9d/cascade.py
echo "def02d8acf7d06b13a9f42e46876c4899657899fdb4083f9d9b9f217f6bd12c8  $scratch/old.py" | sha256sum --check --status
sudo bash install.sh --no-menu
# The branding change must accept files from releases with the old markers.
sudo systemctl stop cascade.service
sudo install -m 0755 "$scratch/old.py" /usr/local/lib/cascade/cascade.py
sudo sed -i 's/^# CascadeVPN managed unit$/# Cascade managed unit/' /etc/systemd/system/cascade.service
sudo bash install.sh --no-menu
cmp cascade.py /usr/local/lib/cascade/cascade.py
sudo systemctl is-active --quiet cascade.service
grep -qx '# CascadeVPN managed unit' /etc/systemd/system/cascade.service
# Started by a relative path from the install directory, so only the
# process's working directory identifies it.
menu='^python3 -I \./cascade\.py menu$'
sleep 60 | sudo script -qfec 'cd /usr/local/lib/cascade && exec python3 -I ./cascade.py menu' /dev/null >/dev/null 2>&1 &
menu_job=$!
for _ in $(seq 1 50); do
    if pgrep -f "$menu" >/dev/null; then break; fi
    sleep 0.1
done
pgrep -f "$menu" >/dev/null
sudo bash install.sh --uninstall
[[ ! -e /usr/local/lib/cascade && ! -e /etc/systemd/system/cascade.service ]]
sudo grep -qx disabled /etc/cascade/.lock
if sudo ip netns exec "$namespace" python3 -I "$scratch/old.py" add --proto udp --listen 198.18.0.1 \
    --in-port 45002 --target 198.18.0.2 2>"$scratch/old.err"; then
    echo 'Release 2.0.1 kept working after removal' >&2; exit 1
fi
grep -q 'удаляется' "$scratch/old.err"
sudo pkill -f "$menu"
wait "$menu_job" || true
sudo bash install.sh --uninstall
assert_removed
# A partially removed installation (program deleted by hand) is cleaned up too.
sudo bash install.sh --no-menu
sudo rm /usr/local/lib/cascade/cascade.py
sudo bash install.sh --uninstall
assert_removed
# A failed first installation removes everything it created.
printf '[Service]\nExecStart=\nExecStart=/bin/false\n' | sudo tee /etc/systemd/system/cascade.service.d/start-failure-test.conf
sudo systemctl daemon-reload
if sudo bash install.sh --no-menu; then
    echo 'Failed start was reported as a successful install' >&2; exit 1
fi
assert_removed
sudo rm /etc/systemd/system/cascade.service.d/start-failure-test.conf
sudo systemctl daemon-reload
echo 'PASS: install, rollback of failed reinstall and first install, systemd lifecycle, foreign-file protection, complete and partial removal'

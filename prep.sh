#!/usr/bin/env bash
# One-time guest prep on the FIRST boot (the OLD system), before any switch:
# a real user with a pre-existing ~/.ssh (utah#474 / ki's report is about homes
# created before the switch) and two /etc changes for the 3-way merge check.
# Runs as root: `ssh root@vm "PUBKEY='…' LANE=… bash -s" < prep.sh`.
TU="${TU:-tuser}"
echo "--- useradd"
useradd -m -s /bin/bash -G wheel "$TU" 2>&1; echo "useradd rc=$?"
H=$(getent passwd "$TU" | cut -d: -f6); echo "home=$H"
install -d -m 700 -o "$TU" -g "$TU" "$H/.ssh"
printf '%s\n' "${PUBKEY:-}" > "$H/.ssh/authorized_keys"
chmod 600 "$H/.ssh/authorized_keys"; chown "$TU:$TU" "$H/.ssh/authorized_keys"
printf 'created %s on %s (lane %s)\n' "$(date -u +%FT%TZ)" "$(grep -E '^PRETTY_NAME=' /etc/os-release)" "${LANE:-?}" > "$H/MARKER-classic"
chown "$TU:$TU" "$H/MARKER-classic"
echo "--- restorecon -RFv $H"; restorecon -RFv "$H" 2>&1 | head -20
echo "--- /etc changes"
hostnamectl hostname "classic-vm" 2>&1 || echo classic-vm > /etc/hostname
printf 'created=%s\nlane=%s\n' "$(date -u +%FT%TZ)" "${LANE:-?}" > /etc/classic-marker.conf
echo "--- state after prep"
stat -c '%C %A %U:%G %n' /var/home "$H" "$H/.ssh" "$H/.ssh/authorized_keys" "$H/MARKER-classic" 2>&1
grep -E '^HOME=' /etc/default/useradd 2>&1
ostree admin config-diff 2>&1 | grep -E 'hostname|classic-marker'

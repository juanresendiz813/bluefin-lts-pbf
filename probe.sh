#!/usr/bin/env bash
# Per-boot guest probe for the Classic -> Utah switch test. Runs as root inside
# the VM (`ssh root@vm bash -s < probe.sh`). Prints "### <section>" headers;
# the harness splits the output into one file per section. Every command is
# allowed to fail — a missing tool is itself a fact (Utah has no rpm-ostree).
TU="${TU:-tuser}"
sec() { printf '\n### %s\n' "$1"; }

sec identity
grep -E '^(NAME|VERSION|VERSION_ID|OSTREE_VERSION|IMAGE_ID|IMAGE_VERSION)=' /etc/os-release
cat /usr/share/ublue-os/image-info.json 2>/dev/null; echo
uname -r; cat /proc/cmdline; hostname

sec graphical
printf 'default_target=%s\n' "$(systemctl get-default 2>&1)"
for u in graphical.target gdm.service display-manager.service; do printf '%s=%s\n' "$u" "$(systemctl is-active "$u" 2>&1)"; done
loginctl list-sessions --no-legend 2>&1
pgrep -a gnome-shell 2>&1 | head -3
pgrep -a -f 'gdm' 2>&1 | head -3

sec selinux-state
getenforce 2>&1
sestatus 2>&1 | head -8
ls -la /etc/selinux/targeted/contexts/files/ 2>&1
echo "--- policy store /var/lib/selinux/targeted"; ls -A /var/lib/selinux/targeted 2>&1 | head

sec subs-dist
echo "--- active /etc"
grep -nE '^\s*/(var/)?home\b' /etc/selinux/targeted/contexts/files/file_contexts.subs_dist 2>&1
echo "--- pristine /usr/etc"
grep -nE '^\s*/(var/)?home\b' /usr/etc/selinux/targeted/contexts/files/file_contexts.subs_dist 2>&1

sec homedirs
for f in /etc/selinux/targeted/contexts/files/file_contexts.homedirs /usr/etc/selinux/targeted/contexts/files/file_contexts.homedirs; do
  printf '%s: var_home_keyed=%s home_keyed=%s sha=%s mtime=%s\n' "$f" \
    "$(grep -c '^/var/home/\[' "$f" 2>/dev/null)" "$(grep -c '^/home/\[' "$f" 2>/dev/null)" \
    "$(sha256sum "$f" 2>/dev/null | cut -c1-12)" "$(stat -c %y "$f" 2>/dev/null)"
done
grep -n 'user_home_dir_t' /etc/selinux/targeted/contexts/files/file_contexts.homedirs 2>&1 | head -3

sec matchpathcon
for p in /home "/home/$TU" /var/home "/var/home/$TU" "/var/home/$TU/.ssh" "/var/home/$TU/.ssh/authorized_keys" /var/home/linuxbrew; do
  printf '%-44s ' "$p"; matchpathcon "$p" 2>&1
done

sec labels
stat -c '%C %A %U:%G %n' /home /var/home "/var/home/$TU" "/var/home/$TU/.ssh" "/var/home/$TU/.ssh/authorized_keys" "/var/home/$TU/MARKER-classic" /var/home/linuxbrew /var/roothome /var/roothome/.ssh 2>&1
echo "--- ls -laZ /var/home"; ls -laZ /var/home 2>&1
echo "--- ls -laZ /var/home/$TU"; ls -laZ "/var/home/$TU" 2>&1
echo "--- ls -laZ /var/home/$TU/.ssh"; ls -laZ "/var/home/$TU/.ssh" 2>&1

sec sed-test
# ki's symptom (utah#474): `sed -i` under a default_t home warns about the file creation context.
runuser -u "$TU" -- bash -c 'cd ~ && echo abc > sedtest.txt && sed -i s/a/b/ sedtest.txt; echo "sed rc=$?"; cat sedtest.txt; ls -Z sedtest.txt' 2>&1

sec avc
journalctl -b --no-pager -o short-precise 2>/dev/null | grep -iE 'avc: +denied' > /tmp/avc.txt
echo "avc_denied_lines=$(wc -l < /tmp/avc.txt)"
sed -E 's/ pid=[0-9]+//; s/ ino=[0-9]+//; s/^[^ ]+ [^ ]+ [^ ]+ //' /tmp/avc.txt | sort | uniq -c | sort -rn | head -30
# ausearch reads stdin when it is a pipe (run 37068137827: it swallowed the rest of this script) — never give it one.
if command -v ausearch >/dev/null 2>&1; then ausearch -m avc -ts boot 2>&1 </dev/null | tail -20; else echo "ausearch: not available"; fi

sec sed-permission-journal
journalctl -b --no-pager 2>/dev/null | grep -iE 'sed: .*(ermission denied|file creation context)|failed to set default file creation context|Regex version mismatch' | head -20
echo "lines=$(journalctl -b --no-pager 2>/dev/null | grep -ciE 'sed: .*ermission denied|failed to set default file creation context')"

sec bootupctl
bootupctl status 2>&1
echo "--- /boot/bootupd-state.json"; head -c 2000 /boot/bootupd-state.json 2>&1; echo

sec esp
ESP=$(findmnt -nro TARGET -t vfat 2>/dev/null | head -1)
echo "esp_mount=${ESP:-NONE}"
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS / /boot /boot/efi /efi /sysroot 2>&1
df -h /boot /boot/efi 2>&1
# A bootc-installed system has no fstab and nothing mounts the ESP at runtime (08 §4.1); bootupd mounts
# it itself when it runs. Mount the vfat partition read-only for the listing, then put it back.
MOUNTED_HERE=0
if [[ -z "$ESP" ]]; then
  ESPDEV=$(lsblk -nro PATH,FSTYPE 2>/dev/null | awk '$2=="vfat"{print $1; exit}')
  echo "esp_device=${ESPDEV:-NONE}"
  if [[ -n "$ESPDEV" ]]; then mkdir -p /run/c2u-esp && mount -o ro "$ESPDEV" /run/c2u-esp 2>&1 && { ESP=/run/c2u-esp; MOUNTED_HERE=1; }; fi
fi
if [[ -n "$ESP" ]]; then
  echo "--- files (bytes path)"; (cd "$ESP" && find . -type f -printf '%10s %p\n' | sort -k2) 2>&1
  echo "--- du"; du -sh "$ESP"/EFI/* 2>&1; df -h "$ESP" 2>&1 | tail -1
  echo "--- efi hashes"; find "$ESP" -name '*.efi' -type f -exec sha256sum {} + 2>&1 | sed -E 's/^([0-9a-f]{16})[0-9a-f]+/\1/'
  echo "--- grub.cfg"; find "$ESP" -name grub.cfg -exec sh -c 'echo "== $1"; cat "$1"' _ {} \; 2>&1 | head -60
  [[ $MOUNTED_HERE == 1 ]] && umount /run/c2u-esp 2>&1
fi

sec boot-dir
ls -la /boot /boot/loader 2>&1
echo "--- entries"; for e in /boot/loader/entries/*.conf; do echo "== $e"; cat "$e"; done 2>&1
echo "--- kernels"; ls -la /boot/ostree/* 2>&1; du -sh /boot/ostree/* 2>&1
echo "--- grub2"; ls -la /boot/grub2 2>&1
echo "--- bootctl"; if command -v bootctl >/dev/null 2>&1; then bootctl status --no-pager 2>&1 | head -40; else echo "bootctl: not available"; fi
echo "--- efibootmgr"; if command -v efibootmgr >/dev/null 2>&1; then efibootmgr -v 2>&1; else echo "efibootmgr: not available"; fi

sec bootc
bootc --version 2>&1
bootc status 2>&1
echo "--- json"; bootc status --format json 2>/dev/null; echo
echo "--- rpm-ostree"; if command -v rpm-ostree >/dev/null 2>&1; then rpm-ostree status 2>&1 | head -40; else echo "rpm-ostree: not available"; fi
echo "--- ostree admin status"; ostree admin status 2>&1

sec etc-merge
echo "--- ostree admin config-diff"; ostree admin config-diff 2>&1 | sort
echo "--- markers"; cat /etc/hostname 2>&1; cat /etc/classic-marker.conf 2>&1
echo "--- /etc/containers/policy.json"; cat /etc/containers/policy.json 2>&1
echo "--- policy.json vs pristine /usr/etc"; diff -u /usr/etc/containers/policy.json /etc/containers/policy.json 2>&1 | head -40; echo "diff rc=${PIPESTATUS[0]}"
echo "--- registries.d"; ls -la /etc/containers/registries.d 2>&1; for f in /etc/containers/registries.d/*; do echo "== $f"; cat "$f"; done 2>&1
echo "--- /etc/pki/containers"; ls -la /etc/pki/containers 2>&1
echo "--- useradd HOME"; grep -E '^HOME=' /etc/default/useradd 2>&1
# Utah README "Known gaps: cross-vendor switch and update timers": Bluefin's timers.target.wants symlink
# for bootc-fetch-apply-updates.timer carries across the /etc merge while Utah masks the unit (utah#101).
echo "--- bootc-fetch-apply-updates"; for u in bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service; do printf '%s: is-enabled=%s is-active=%s\n' "$u" "$(systemctl is-enabled "$u" 2>&1)" "$(systemctl is-active "$u" 2>&1)"; done
ls -la /etc/systemd/system/timers.target.wants/ /etc/systemd/system/bootc-fetch-apply-updates.* /usr/lib/systemd/system/bootc-fetch-apply-updates.* 2>&1
systemctl list-timers --all --no-pager 2>&1 | grep -iE 'bootc|NEXT'

sec userdata
ls -la "/var/home/$TU" 2>&1
cat "/var/home/$TU/MARKER-classic" 2>&1
printf 'authorized_keys sha=%s\n' "$(sha256sum "/var/home/$TU/.ssh/authorized_keys" 2>/dev/null | cut -c1-16)"
id "$TU" 2>&1
echo "--- flatpak"; flatpak remotes 2>&1; flatpak list --app --columns=application,origin 2>&1 | head -50
echo "flatpak_app_count=$(flatpak list --app 2>/dev/null | wc -l)"
echo "--- brew"; ls -la /var/home/linuxbrew/.linuxbrew/bin 2>&1 | head -5

sec utah
ls -la /usr/share/utah/ 2>&1
echo "contract_lines=$(wc -l < /usr/share/utah/contract.txt 2>/dev/null)"
head -5 /usr/share/utah/contract.txt 2>&1
rpm -q bootc bootupd ostree systemd shim-x64 grub2-efi-x64 selinux-policy-targeted systemd-boot-unsigned gnome-shell gdm 2>&1

sec hooks
journalctl -b --no-pager -u ublue-system-setup.service 2>&1 | tail -80
echo "--- user-setup"; journalctl -b --no-pager -u 'ublue-user-setup*' 2>&1 | tail -20
echo "--- hook lines"; journalctl -b --no-pager 2>/dev/null | grep -iE 'bootupctl-adopt|home-labels|adopt-and-update|restorecon' | head -40
echo "--- recorded versions (libsetup.sh stores them per invoking user)"; for f in /root/.local/share/ublue/setup_versioning.json /var/roothome/.local/share/ublue/setup_versioning.json "/var/home/$TU/.local/share/ublue/setup_versioning.json"; do [[ -f "$f" ]] && { echo "== $f"; cat "$f"; echo; }; done; ls -la /etc/ublue 2>&1 | head -3

sec failed-detail
systemctl --failed --no-legend --no-pager 2>&1
for u in $(systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}'); do echo "== $u"; systemctl status "$u" --no-pager 2>&1 | head -15; done

sec upgrade-check
# Does the booted deployment's image reference + signature policy still work for updates?
out=$(timeout 180 bootc upgrade --check 2>&1); rc=$?
echo "$out" | tail -8; echo "rc=$rc"

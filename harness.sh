#!/usr/bin/env bash
# Classic -> Utah `bootc switch` verification harness (review only).
# Reuses the boot-hang harness (review/boot-hang-verify, run 36676639424):
#   1. `bootc install to-disk --via-loopback` the OLD image into a raw disk — a real
#      install: bootupd puts shim/grub on the ESP, ostree writes BLS entries.
#   2. Boot the disk under QEMU/KVM through OVMF (UEFI firmware), SSH in as root.
#   3. prep.sh: create a user + ~/.ssh/authorized_keys + two /etc changes on the OLD system.
#   4. `bootc switch --enforce-container-sigpolicy NEW` (retry without the flag if rejected),
#      `systemctl reboot`, let the firmware + grub pick the staged deployment.
#   5. probe.sh per boot: graphical target, SELinux home labels / AVCs / sed warnings,
#      ESP + BLS entries + bootupctl, /etc merge, user data, flatpaks, contract.txt.
#   6. EXTRA_REBOOTS more reboots; optionally `bootc rollback` + one more boot (ROLLBACK=1).
# NEW="" = control (install OLD and just boot it). NEW="@same" = re-switch OLD to itself by digest.
# Exit 0 = boots, 1 = hang / wrong deployment / rollback failed, 2 = harness failed early.
set -uo pipefail

OLD="${OLD:?OLD image required}"
NEW="${NEW:-}"
LANE="${LANE:?LANE name required}"
OUT="${OUT:-$PWD/out}"
DISKDIR="${DISKDIR:-/mnt/bhv}"           # /mnt has ~60 GB free on GitHub runners; / does not
DISK="$DISKDIR/disk.raw"
SSH_PORT="${SSH_PORT:-2222}"
FIRST_BOOT_DEADLINE="${FIRST_BOOT_DEADLINE:-600}"
POST_SWITCH_DEADLINE="${POST_SWITCH_DEADLINE:-600}"
SWITCH_TIMEOUT="${SWITCH_TIMEOUT:-2400}"
EXTRA_REBOOTS="${EXTRA_REBOOTS:-2}"
ROLLBACK="${ROLLBACK:-0}"
DISK_SIZE="${DISK_SIZE:-40G}"
TU="${TU:-tuser}"

mkdir -p "$OUT"; sudo mkdir -p "$DISKDIR"; sudo chmod 777 "$DISKDIR"
KEY="$PWD/vm_key"
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -f "$KEY" -N "" -C "c2u@gha"
# G-035: re-assert 0600 before every use; the ssh client silently refuses a 0644 key.
chmod 600 "$KEY"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR -p "$SSH_PORT")

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/harness.log"; }
vssh() { chmod 600 "$KEY"; ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }
# boot_id only, stripped of login-shell noise (ublue-motd prints to stderr on ssh).
boot_id() { vssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | grep -oE '^[0-9a-f]{8}-[0-9a-f-]{27}$' | head -1; }
RESULT="$OUT/RESULT.md"
note() { printf '%s\n' "$*" >> "$RESULT"; }

# ---------------------------------------------------------------- image facts
image_facts() {
  local side="$1" img="$2"
  local d="$OUT/image-$side"
  mkdir -p "$d"
  log "facts: pulling $img"
  sudo podman pull --quiet "$img" > "$d/pull.log" 2>&1 || { log "pull failed for $img"; cat "$d/pull.log"; return 1; }
  local idx; idx=$(skopeo inspect --raw "docker://$img" | sha256sum | awk '{print $1}')
  echo "index sha256:$idx" > "$d/digest"
  # Is there a cosign signature for this digest at all? (sigstore attachment tag; the fork's F45 images are unsigned)
  local sigref="${img%%:*}"; sigref="${sigref%%@*}:sha256-${idx}.sig"
  if skopeo inspect --raw "docker://$sigref" >/dev/null 2>&1; then echo "cosign-signature-tag=present ($sigref)" >> "$d/digest"; else echo "cosign-signature-tag=ABSENT ($sigref)" >> "$d/digest"; fi
  sudo podman image inspect --format 'manifest {{.Digest}}{{"\n"}}created={{index .Labels "org.opencontainers.image.created"}}{{"\n"}}version={{index .Labels "org.opencontainers.image.version"}}{{"\n"}}revision={{index .Labels "org.opencontainers.image.revision"}}{{"\n"}}ostree.linux={{index .Labels "ostree.linux"}}' "$img" >> "$d/digest" 2>&1
  sudo podman run --rm "$img" bash -c '
    echo "--- rpm"; rpm -q bootc bootupd ostree systemd shim-x64 grub2-efi-x64 selinux-policy-targeted systemd-boot-unsigned rpm-ostree gdm 2>&1
    echo "--- image-info.json"; cat /usr/share/ublue-os/image-info.json 2>/dev/null; echo
    echo "--- os-release"; grep -E "^(NAME|VERSION|VERSION_ID|OSTREE_VERSION|IMAGE_ID)=" /etc/os-release
    echo "--- bootc --version"; bootc --version 2>&1
    echo "--- bootc install config"; cat /usr/lib/bootc/install/*.toml 2>&1
    echo "--- /etc/containers/policy.json"; cat /etc/containers/policy.json 2>&1
    echo "--- registries.d"; ls /etc/containers/registries.d 2>&1; cat /etc/containers/registries.d/* 2>&1
    echo "--- /etc/pki/containers"; ls -la /etc/pki/containers 2>&1
    echo "--- subs_dist home lines"; grep -nE "^\s*/(var/)?home\b" /etc/selinux/targeted/contexts/files/file_contexts.subs_dist 2>&1
    echo "--- homedirs keying (/etc)"; f=/etc/selinux/targeted/contexts/files/file_contexts.homedirs; echo "var_home_keyed=$(grep -c "^/var/home/\[" $f) home_keyed=$(grep -c "^/home/\[" $f) sha=$(sha256sum $f | cut -c1-12)"
    echo "--- useradd HOME"; grep -E "^HOME=" /etc/default/useradd 2>&1
    echo "--- bootupd payload"; ls /usr/lib/bootupd/updates/EFI/ /usr/lib/bootupd/updates/EFI/* 2>&1 | head -20; find /usr/lib/efi -maxdepth 5 2>/dev/null | head -20
    echo "--- utah contract"; ls -la /usr/share/utah/ 2>&1; wc -l /usr/share/utah/contract.txt 2>&1
    echo "--- sshd effective config"; grep -vhE "^\s*(#|$)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>&1
    echo "--- wants symlinks in image /etc"; ls /etc/systemd/system/default.target.wants/ /etc/systemd/system/multi-user.target.wants/ 2>&1
  ' > "$d/facts.txt" 2>&1
  {
    echo "### image $side: \`$img\`"; echo '```'; cat "$d/digest"; grep -A3 -- '--- os-release' "$d/facts.txt"; grep -A1 -- '--- bootc --version' "$d/facts.txt" | tail -1; echo '```'
  } >> "$RESULT"
}

# ---------------------------------------------------------------- install
# Partition roles by filesystem, not by number (Utah's bootc may lay the disk out differently).
find_parts() {  # $1 = loop device → sets ESP_PART ROOT_PART
  ESP_PART=$(lsblk -nro NAME,FSTYPE "$1" | awk '$2=="vfat"{print "/dev/"$1; exit}')
  ROOT_PART=$(lsblk -nro NAME,FSTYPE "$1" | awk '$2=="ext4"||$2=="btrfs"||$2=="xfs"{print "/dev/"$1; exit}')
}

install_to_disk() {
  local img="$1"
  log "install: $img -> $DISK ($DISK_SIZE, ext4, via-loopback)"
  rm -f "$DISK"; truncate -s "$DISK_SIZE" "$DISK"
  cp "$KEY.pub" "$DISKDIR/vm_key.pub.copy"
  sudo podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$DISKDIR:/data" \
    "$img" bootc install to-disk \
      --via-loopback /data/disk.raw --filesystem ext4 --wipe \
      --root-ssh-authorized-keys /data/vm_key.pub.copy \
      --karg console=ttyS0,115200 \
      --karg systemd.journald.forward_to_console=1 \
      --karg systemd.wants=sshd.service \
    2>&1 | tee "$OUT/bootc-install.log"
  local rc=${PIPESTATUS[0]}
  log "install: bootc install rc=$rc"
  local loop; loop=$(sudo losetup -f --show -P "$DISK")
  find_parts "$loop"
  sudo mkdir -p /mnt/bhv-root /mnt/bhv-esp
  {
    echo "--- partitions"; lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL "$loop"; echo "esp=$ESP_PART root=$ROOT_PART"
    if [[ -n "$ROOT_PART" ]] && sudo mount -o ro "$ROOT_PART" /mnt/bhv-root 2>/dev/null; then
      local dep; dep=$(sudo find /mnt/bhv-root/ostree/deploy/default/deploy -mindepth 1 -maxdepth 1 -type d | head -1)
      echo "--- deployment: $dep"
      echo "--- etc/fstab"; sudo cat "$dep/etc/fstab" 2>&1
      echo "--- etc/tmpfiles.d"; sudo ls -la "$dep/etc/tmpfiles.d/" 2>&1
      echo "--- boot/loader/entries"; sudo find /mnt/bhv-root/boot/loader/entries/ -type f -exec sh -c 'echo "== $1"; cat "$1"' _ {} \; 2>&1
      echo "--- boot/ostree"; sudo ls -la /mnt/bhv-root/boot/ostree/* 2>&1
      echo "--- boot/grub2"; sudo ls -la /mnt/bhv-root/boot/grub2/ 2>&1; sudo head -30 /mnt/bhv-root/boot/grub2/grub.cfg 2>&1
      echo "--- boot/bootupd-state.json"; sudo head -c 1500 /mnt/bhv-root/boot/bootupd-state.json 2>&1; echo
      sudo umount /mnt/bhv-root
    else echo "mount root failed"; fi
    if [[ -n "$ESP_PART" ]] && sudo mount -o ro "$ESP_PART" /mnt/bhv-esp 2>/dev/null; then
      echo "--- ESP (installed by OLD image's bootupd)"; (cd /mnt/bhv-esp && sudo find . -type f -printf '%10s %p\n' | sort -k2) 2>&1
      echo "--- ESP efi hashes"; sudo find /mnt/bhv-esp -name '*.efi' -type f -exec sha256sum {} + 2>&1 | sed -E 's/^([0-9a-f]{16})[0-9a-f]+/\1/'
      sudo umount /mnt/bhv-esp
    else echo "mount ESP failed"; fi
  } > "$OUT/disk-after-install.txt" 2>&1
  # Root SSH key straight into the stateroot's /var with the labels sshd expects (bootc's
  # own tmpfiles `f~` line cannot create the missing .ssh dir — run 36665173579). /etc untouched.
  sudo mkdir -p /mnt/bhv-rw
  if [[ -n "$ROOT_PART" ]] && sudo mount "$ROOT_PART" /mnt/bhv-rw; then
    local vr=/mnt/bhv-rw/ostree/deploy/default/var/roothome
    if [[ ! -d "$vr" ]]; then sudo mkdir -m 0700 "$vr"; sudo setfattr -n security.selinux -v 'system_u:object_r:admin_home_t:s0' "$vr"; fi
    sudo mkdir -m 0700 -p "$vr/.ssh"
    sudo cp "$KEY.pub" "$vr/.ssh/authorized_keys" || echo "cp of authorized_keys FAILED" >> "$OUT/disk-after-install.txt"
    sudo chmod 600 "$vr/.ssh/authorized_keys"
    sudo setfattr -n security.selinux -v 'system_u:object_r:ssh_home_t:s0' "$vr/.ssh" "$vr/.ssh/authorized_keys"
    { echo "--- stateroot var/roothome after key injection"; sudo ls -laZ "$vr" "$vr/.ssh"; } >> "$OUT/disk-after-install.txt" 2>&1
    sudo umount /mnt/bhv-rw
  else echo "rw mount of root failed — key injection skipped" >> "$OUT/disk-after-install.txt"; fi
  sudo losetup -d "$loop"
  sudo podman rmi -f "$img" >/dev/null 2>&1 || true
  df -h / "$DISKDIR" | tail -2 | tee -a "$OUT/harness.log"
  return "$rc"
}

# ---------------------------------------------------------------- VM
vm_start() {
  local code vars
  for code in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f $code ]] && break; done
  for vars in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [[ -f $vars ]] && break; done
  cp "$vars" "$PWD/OVMF_VARS.fd"
  log "vm: starting QEMU/KVM + OVMF ($code)"
  : > "$OUT/serial.log"; chmod 666 "$OUT/serial.log"
  sudo qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 4096 -smp 4 -rtc base=utc \
    -drive "if=pflash,format=raw,readonly=on,file=$code" \
    -drive "if=pflash,format=raw,file=$PWD/OVMF_VARS.fd" \
    -drive "if=none,id=disk,file=$DISK,format=raw,cache=unsafe,aio=threads,discard=unmap" \
    -device virtio-blk-pci,drive=disk \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -device virtio-gpu-pci -display none \
    -serial "file:$OUT/serial.log" \
    -monitor unix:/tmp/qemu-monitor.sock,server,nowait \
    -daemonize -pidfile /tmp/qemu.pid
  log "vm: qemu pid $(sudo cat /tmp/qemu.pid)"
}
vm_stop() { [[ -f /tmp/qemu.pid ]] && sudo kill "$(sudo cat /tmp/qemu.pid)" 2>/dev/null; sleep 2; }

# wait until ssh answers with a boot_id different from $1 (empty = any); prints seconds taken
wait_boot() {
  local prev="${1:-}" deadline="$2" t0=$SECONDS id
  while (( SECONDS - t0 < deadline )); do
    id=$(boot_id || true)
    if [[ -n "$id" && "$id" != "$prev" ]]; then echo $((SECONDS - t0)); return 0; fi
    sleep 5
  done
  echo $((SECONDS - t0)); return 1
}

reboot_and_wait() {  # $1 = label; returns 0 if a new boot answered ssh
  local label="$1" prev t
  prev=$(boot_id || true)
  vssh 'systemctl reboot' >/dev/null 2>&1 || true
  sleep 15
  if t=$(wait_boot "$prev" "$POST_SWITCH_DEADLINE"); then log "$label: ssh after $((t + 15))s"; return 0; fi
  return 1
}

# ---------------------------------------------------------------- collect
field() { grep -oE "$2" "$OUT/$1" 2>/dev/null | head -1 | sed -E 's/^[^=]*=//'; }
ltype() { awk -v p="$2" '$NF==p{print $1; exit}' "$OUT/$1" 2>/dev/null | awk -F: '{print $3}'; }

collect() {
  local label="$1" d="$OUT/$1"; mkdir -p "$d"
  log "collect: $label"
  boot_id > "$d/boot_id"
  vssh 'uname -r' 2>/dev/null > "$d/uname"
  vssh 'bootc status --format json' 2>/dev/null > "$d/bootc-status.json"
  vssh 'timeout 240 systemctl is-system-running --wait; echo "rc=$?"' > "$d/is-system-running-wait" 2>&1
  vssh 'systemctl is-system-running' 2>/dev/null > "$d/is-system-running"
  vssh 'systemctl list-jobs --no-pager' > "$d/list-jobs" 2>&1
  vssh 'systemctl --failed --no-legend --no-pager' > "$d/failed-units" 2>&1
  vssh 'journalctl -b -o short-precise --no-pager' > "$d/journal-b.log" 2>&1
  grep -iE 'ordering cycle|deleted to break' "$d/journal-b.log" > "$d/cycle-lines" || true
  grep -iE 'Timed out waiting for device|Dependency failed for' "$d/journal-b.log" > "$d/device-timeouts" || true
  vssh 'systemd-analyze critical-chain --no-pager 2>&1' > "$d/critical-chain" 2>&1
  # the sectioned probe: one file per "### section". Copied in and run by path — streaming it on
  # stdin (`bash -s`) let `ausearch` eat everything after the avc section in run 37068137827.
  vssh 'cat > /root/probe.sh' < "$PWD/probe.sh"
  vssh "TU=$TU bash /root/probe.sh" > "$d/probe.txt" 2>&1
  awk -v dir="$d" '/^### /{f=dir"/"$2; next} f{print > f}' "$d/probe.txt"
  printf 'sections=%s\n' "$(grep -c '^### ' "$d/probe.txt")" >> "$OUT/harness.log"

  local img dig state kern gdm vh sshl avc sedp esp
  img=$(jq -r '.status.booted.image.image.image // "?"' "$d/bootc-status.json" 2>/dev/null)
  dig=$(jq -r '.status.booted.image.imageDigest // "?"' "$d/bootc-status.json" 2>/dev/null)
  state=$(head -1 "$d/is-system-running" 2>/dev/null); kern=$(cat "$d/uname")
  gdm=$(field "$label/graphical" 'gdm.service=[a-z]+'); vh=$(ltype "$label/labels" /var/home); sshl=$(ltype "$label/labels" "/var/home/$TU/.ssh")
  avc=$(field "$label/avc" 'avc_denied_lines=[0-9]+'); sedp=$(field "$label/sed-permission-journal" '^lines=[0-9]+')
  esp=$(grep -cE '^ *[0-9]+ \./' "$d/esp" 2>/dev/null)
  local line="| $label | $kern | \`$img\` | \`${dig:0:19}\` | $state | ${gdm:-?} | $(wc -l < "$d/failed-units") | $(wc -l < "$d/cycle-lines") | ${vh:-?} / ${sshl:-?} | ${avc:-?} | ${sedp:-?} | ${esp:-?} |"
  log "collect: $line"
  echo "$line" >> "$OUT/boots.tsv"
}

postmortem() {
  local label="$1" d="$OUT/$1-postmortem"; mkdir -p "$d"
  log "postmortem: $label (no SSH) — serial tail + on-disk journal"
  tail -300 "$OUT/serial.log" > "$d/serial-tail.log"
  grep -iE 'ordering cycle|deleted to break|Timed out waiting for device|emergency|Failed to open|Not Found' "$OUT/serial.log" > "$d/serial-signals" || true
  chmod 600 "$KEY"; ssh -vvv -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -p "$SSH_PORT" root@127.0.0.1 true > "$d/ssh-vvv.log" 2>&1 || true
  vm_stop
  local loop; loop=$(sudo losetup -f --show -P "$DISK"); find_parts "$loop"
  sudo mkdir -p /mnt/bhv-root /mnt/bhv-esp
  if [[ -n "$ROOT_PART" ]] && sudo mount -o ro "$ROOT_PART" /mnt/bhv-root; then
    local j=/mnt/bhv-root/ostree/deploy/default/var/log/journal
    sudo journalctl -D "$j" --list-boots --no-pager > "$d/list-boots" 2>&1
    sudo journalctl -D "$j" -b 0 -o short-precise --no-pager > "$d/journal-last-boot.log" 2>&1
    grep -iE 'ordering cycle|deleted to break' "$d/journal-last-boot.log" > "$d/journal-cycle-lines" || true
    sudo find /mnt/bhv-root/boot/loader/entries/ -type f -exec sh -c 'echo "== $1"; cat "$1"' _ {} \; > "$d/bls-entries" 2>&1
    sudo ls -la /mnt/bhv-root/ostree/deploy/default/deploy/ > "$d/deployments" 2>&1
    sudo umount /mnt/bhv-root
  fi
  if [[ -n "$ESP_PART" ]] && sudo mount -o ro "$ESP_PART" /mnt/bhv-esp; then
    (cd /mnt/bhv-esp && sudo find . -type f -printf '%10s %p\n' | sort -k2) > "$d/esp-files" 2>&1; sudo umount /mnt/bhv-esp
  fi
  sudo losetup -d "$loop"
  echo "| $label | (no ssh) | — | — | NO-SSH | — | — | serial:$(wc -l < "$d/serial-signals") | — | — | — | — |" >> "$OUT/boots.tsv"
}

# ---------------------------------------------------------------- main
{
  echo "# Classic → Utah switch — lane \`$LANE\`"
  echo
  echo "- OLD (installed): \`$OLD\`"
  echo "- NEW (switch target): \`${NEW:-— (control: no switch)}\`"
  echo "- runner: $(uname -a); qemu: $(qemu-system-x86_64 --version | head -1); kvm: $(ls -la /dev/kvm 2>&1)"
  echo "- started: $(date -u +%FT%TZ)"
  echo
} > "$RESULT"

OLD_TAG="$OLD"
dg=$(skopeo inspect --raw "docker://$OLD" | sha256sum | awk '{print $1}')
OLD_PIN="${OLD%%:*}@sha256:$dg"
if [[ "${PIN_OLD:-0}" == "1" ]]; then
  OLD="$OLD_PIN"
  note "- OLD pinned by digest at run time: \`$OLD_TAG\` → \`$OLD\`"
fi
if [[ "$NEW" == "@same" ]]; then
  # re-switch to the same bytes under a different reference string (identical refs are a no-op for bootc)
  if [[ "$OLD" == "$OLD_PIN" ]]; then NEW="$OLD_TAG"; else NEW="$OLD_PIN"; fi
  note "- NEW resolved from \`@same\`: \`$NEW\` (same index digest \`sha256:${dg:0:12}…\` as OLD)"
fi

image_facts old "$OLD" || { note "**HARNESS-FAILED: cannot pull OLD**"; exit 2; }
if [[ -n "$NEW" ]]; then image_facts new "$NEW" || { note "**HARNESS-FAILED: cannot pull NEW**"; exit 2; }; sudo podman rmi -f "$NEW" >/dev/null 2>&1 || true; fi

install_to_disk "$OLD"; rc=$?
if [[ $rc -ne 0 ]]; then
  if grep -q 'ostree/deploy/default/deploy' "$OUT/disk-after-install.txt" && grep -qi 'BOOTX64' "$OUT/disk-after-install.txt"; then
    note "- bootc install exited $rc but deployment + ESP payload are present; continuing"
  else
    note "**HARNESS-FAILED: bootc install to-disk rc=$rc** (see bootc-install.log / disk-after-install.txt)"; exit 2
  fi
fi

echo "| boot | kernel | booted image | digest | is-system-running | gdm | failed units | cycle lines | label /var/home / $TU/.ssh | AVC denied | sed-perm lines | ESP files |" > "$OUT/boots.tsv"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|" >> "$OUT/boots.tsv"

vm_start
if t=$(wait_boot "" "$FIRST_BOOT_DEADLINE"); then
  log "boot-1 (OLD, first boot): ssh after ${t}s"
  log "prep: user $TU + ~/.ssh + /etc markers on the OLD system"
  vssh 'cat > /root/prep.sh' < "$PWD/prep.sh"
  vssh "PUBKEY='$(cat "$KEY.pub")' LANE='$LANE' TU='$TU' bash /root/prep.sh" > "$OUT/prep.log" 2>&1
  collect boot-1-old
else
  postmortem boot-1-old
  note "**$( [[ -n $NEW ]] && echo HARNESS-FAILED || echo NO-SSH ): first boot of \`$OLD\` never reached SSH in ${FIRST_BOOT_DEADLINE}s** (see serial.log / boot-1-old-postmortem)"
  cat "$OUT/boots.tsv" >> "$RESULT"; exit 2
fi
old_digest=$(jq -r '.status.booted.image.imageDigest // "?"' "$OUT/boot-1-old/bootc-status.json")

verdict="BOOTS"; exit_code=0; n=1
if [[ -n "$NEW" ]]; then
  prev=$(cat "$OUT/boot-1-old/boot_id")
  log "switch: bootc switch --enforce-container-sigpolicy $NEW"
  t0=$SECONDS
  chmod 600 "$KEY"; timeout "$SWITCH_TIMEOUT" ssh "${SSH_OPTS[@]}" root@127.0.0.1 "bootc switch --enforce-container-sigpolicy $NEW" > "$OUT/switch.log" 2>&1; src=$?
  log "switch: rc=$src after $((SECONDS - t0))s"
  note "- \`bootc switch --enforce-container-sigpolicy $NEW\` → rc=$src in $((SECONDS - t0))s (switch.log)"
  switch_mode="enforce-container-sigpolicy"
  if [[ $src -ne 0 ]]; then
    tail -5 "$OUT/switch.log" | tee -a "$OUT/harness.log"
    note "  - FINDING: enforced switch rejected; last line: \`$(tail -1 "$OUT/switch.log" | cut -c1-200)\`"
    log "switch: retrying without --enforce-container-sigpolicy"
    t0=$SECONDS
    timeout "$SWITCH_TIMEOUT" ssh "${SSH_OPTS[@]}" root@127.0.0.1 "bootc switch $NEW" > "$OUT/switch-noflag.log" 2>&1; src=$?
    note "- retry \`bootc switch $NEW\` (no flag) → rc=$src in $((SECONDS - t0))s (switch-noflag.log)"
    switch_mode="NO-ENFORCEMENT (unverified transport)"
    [[ $src -ne 0 ]] && { note "**HARNESS-FAILED: bootc switch failed both ways**"; cat "$OUT/boots.tsv" >> "$RESULT"; exit 2; }
  fi
  note "- switch mode that succeeded: **$switch_mode**"
  grep -E 'Queued for next boot|ostree-image-signed|ostree-unverified|Digest' "$OUT/switch.log" "$OUT/switch-noflag.log" 2>/dev/null | sed 's/^/- /' >> "$RESULT" || true
  vssh 'bootc status' > "$OUT/after-switch-bootc-status.yaml" 2>&1
  vssh 'bootc status --format json' 2>/dev/null > "$OUT/after-switch-bootc-status.json"
  staged=$(jq -r '.status.staged.image.imageDigest // "none"' "$OUT/after-switch-bootc-status.json")
  note "- staged after switch: \`$staged\`"
  # ESP + BLS entries right after the switch, still on the OLD boot (what the finalizer wrote)
  vssh 'E=$(findmnt -nro TARGET -t vfat | head -1); echo "esp=$E"; cd "$E" && find . -type f -printf "%10s %p\n" | sort -k2; echo "--- entries"; for e in /boot/loader/entries/*.conf; do echo "== $e"; cat "$e"; done; echo "--- boot/ostree"; ls -la /boot/ostree/*; du -sh /boot/ostree/*; echo "--- deployments"; ls -la /ostree/deploy/default/deploy/' > "$OUT/after-switch-esp-and-entries.txt" 2>&1
  log "reboot into the staged deployment (firmware path: OVMF → shim → grub → ostree:0)"
  vssh 'systemctl reboot' >/dev/null 2>&1 || true
  sleep 15
  if t=$(wait_boot "$prev" "$POST_SWITCH_DEADLINE"); then
    log "boot-2 (after switch): ssh after $((t + 15))s"
    collect boot-2-new
    booted=$(jq -r '.status.booted.image.imageDigest // "?"' "$OUT/boot-2-new/bootc-status.json")
    if [[ "$booted" != "$staged" ]]; then note "- **WARNING: booted digest \`$booted\` != staged \`$staged\` — the new deployment was NOT booted**"; verdict="BOOTED-WRONG-DEPLOYMENT"; exit_code=1; fi
  else
    postmortem boot-2-new
    verdict="HANG"; exit_code=1
  fi
  n=2
fi

# Utah's privileged hooks (05-bootupctl-adopt, 20-home-labels, 99-flatpaks …) only run when a wheel user's
# GNOME session calls `pkexec /usr/bin/ublue-privileged-setup` (common 99-privileged.sh). Nobody logs into
# this VM — run 37068137827 showed the gdm-greeter's attempt dying with pkexec 127 — so simulate the first
# admin login once, right after the first boot of a Utah deployment, and probe again in the same boot.
if [[ $exit_code -eq 0 && "${RUN_PRIVILEGED_SETUP:-0}" == "1" ]]; then
  log "privileged-setup: simulating the first admin login (timeout 900 /usr/bin/ublue-privileged-setup)"
  vssh 'ls /usr/share/ublue-os/privileged-setup.hooks.d/; timeout 900 /usr/bin/ublue-privileged-setup; echo "privileged-setup rc=$?"' > "$OUT/privileged-setup.log" 2>&1
  note "- simulated first admin login: \`/usr/bin/ublue-privileged-setup\` → $(grep -oE 'privileged-setup rc=[0-9]+' "$OUT/privileged-setup.log" | tail -1) (privileged-setup.log; same boot re-probed as \`boot-$n-after-privileged-setup\`)"
  collect "boot-$n-after-privileged-setup"
fi

# extra reboots of whatever is now booted (only if the previous boot reached ssh)
if [[ $exit_code -eq 0 ]]; then
  for i in $(seq 1 "$EXTRA_REBOOTS"); do
    n=$((n + 1))
    log "reboot #$n"
    if reboot_and_wait "boot-$n"; then collect "boot-$n"
    else postmortem "boot-$n"; verdict="HANG (on reboot #$n)"; exit_code=1; break; fi
  done
fi

# rollback to the OLD deployment (switch lanes only)
if [[ -n "$NEW" && "$ROLLBACK" == "1" && $exit_code -eq 0 ]]; then
  n=$((n + 1))
  log "rollback: bootc rollback"
  vssh 'bootc rollback' > "$OUT/rollback.log" 2>&1; rrc=$?
  note "- \`bootc rollback\` → rc=$rrc (rollback.log)"
  vssh 'bootc status' > "$OUT/after-rollback-bootc-status.yaml" 2>&1
  if [[ $rrc -eq 0 ]] && reboot_and_wait "boot-$n-rollback"; then
    collect "boot-$n-rollback"
    rb=$(jq -r '.status.booted.image.imageDigest // "?"' "$OUT/boot-$n-rollback/bootc-status.json")
    if [[ "$rb" == "$old_digest" ]]; then note "- rollback: **ROLLBACK-OK** — booted \`${rb:0:19}\` = OLD"; else note "- rollback: **ROLLBACK-WRONG** — booted \`${rb:0:19}\`, OLD was \`${old_digest:0:19}\`"; verdict="$verdict + ROLLBACK-WRONG"; exit_code=1; fi
  else
    [[ $rrc -ne 0 ]] && note "- rollback: **ROLLBACK-FAILED** (rc=$rrc, rollback.log)" || { postmortem "boot-$n-rollback"; note "- rollback: **HANG after rollback**"; }
    verdict="$verdict + ROLLBACK-FAILED"; exit_code=1
  fi
fi

vm_stop
{
  echo; echo "## Boots"; echo; cat "$OUT/boots.tsv"; echo
  echo "## Verdict: **$verdict** — ordering-cycle journal lines across all boots: $(cat "$OUT"/boot-*/cycle-lines 2>/dev/null | wc -l)"
  echo; echo "finished: $(date -u +%FT%TZ)"
} >> "$RESULT"
cat "$RESULT" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
cat "$RESULT"
exit "$exit_code"

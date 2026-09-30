#!/usr/bin/env bash
# Boot-hang verification harness (review only; projectbluefin/bluefin-lts #391 #466 #585).
#
# On a GitHub-hosted ubuntu runner:
#   1. `bootc install to-disk --via-loopback` the OLD image into a raw disk — a real
#      install: bootupd puts shim/grub on the ESP, ostree writes BLS entries.
#   2. Boot the disk under QEMU/KVM through OVMF (UEFI firmware), SSH in as root.
#   3. `bootc switch NEW` inside the VM, `systemctl reboot`, let the firmware +
#      grub pick the new deployment (ostree:0), wait for SSH again.
#   4. Collect journal / jobs / critical-chain / rechunker-group-fix state per boot,
#      then reboot EXTRA_REBOOTS more times (the hang is reported as intermittent).
# NEW="" means "control": install OLD (really the target) and just boot it.
# Every artefact lands in $OUT. Exit 0 = boots, 1 = hang/no-ssh after switch,
# 2 = harness failed before the interesting part.
set -uo pipefail

OLD="${OLD:?OLD image required}"
NEW="${NEW:-}"
LANE="${LANE:?LANE name required}"
OUT="${OUT:-$PWD/out}"
DISK="${DISK:-$PWD/disk.raw}"
SSH_PORT="${SSH_PORT:-2222}"
FIRST_BOOT_DEADLINE="${FIRST_BOOT_DEADLINE:-600}"
POST_SWITCH_DEADLINE="${POST_SWITCH_DEADLINE:-600}"
SWITCH_TIMEOUT="${SWITCH_TIMEOUT:-1800}"
EXTRA_REBOOTS="${EXTRA_REBOOTS:-2}"
DISK_SIZE="${DISK_SIZE:-30G}"

mkdir -p "$OUT"
KEY="$PWD/vm_key"
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -f "$KEY" -N "" -C "bhv@gha"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR -p "$SSH_PORT")

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/harness.log"; }
vssh() { ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }
RESULT="$OUT/RESULT.md"
note() { printf '%s\n' "$*" >> "$RESULT"; }

# ---------------------------------------------------------------- image facts
image_facts() {
  local side="$1" img="$2"
  local d="$OUT/image-$side"
  mkdir -p "$d"
  log "facts: pulling $img"
  sudo podman pull --quiet "$img" > "$d/pull.log" 2>&1 || { log "pull failed for $img"; cat "$d/pull.log"; return 1; }
  if command -v skopeo >/dev/null; then
    skopeo inspect --raw "docker://$img" | sha256sum | awk '{print "index sha256:"$1}' > "$d/digest"
  fi
  sudo podman image inspect --format 'manifest {{.Digest}}{{"\n"}}created={{index .Labels "org.opencontainers.image.created"}}{{"\n"}}version={{index .Labels "org.opencontainers.image.version"}}{{"\n"}}revision={{index .Labels "org.opencontainers.image.revision"}}{{"\n"}}ostree.linux={{index .Labels "ostree.linux"}}' "$img" >> "$d/digest" 2>&1
  sudo podman run --rm "$img" bash -c '
    echo "--- rpm"; rpm -q bootc bootupd ostree systemd shim-x64 grub2-efi-x64 2>&1
    echo "--- image-info.json"; cat /usr/share/ublue-os/image-info.json 2>/dev/null
    echo "--- os-release"; grep -E "^(NAME|VERSION|VERSION_ID|OSTREE_VERSION)=" /etc/os-release
    echo "--- rechunker-group-fix.service (unit as shipped)"; cat /usr/lib/systemd/system/rechunker-group-fix.service 2>&1
    echo "--- rechunker-group-fix ordering lines"; grep -nE "^(After|Before|Wants|Requires)=" /usr/lib/systemd/system/rechunker-group-fix.service 2>&1
    echo "--- wants symlinks in image /etc"; ls -la /etc/systemd/system/default.target.wants/ /etc/systemd/system/multi-user.target.wants/ 2>&1
    echo "--- sshd PermitRootLogin"; grep -rn PermitRootLogin /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>&1
    echo "--- bootupd payload"; ls /usr/lib/bootupd/updates/EFI/ /usr/lib/bootupd/updates/EFI/* 2>&1 | head -20
    echo "--- bootc --version"; bootc --version 2>&1
  ' > "$d/facts.txt" 2>&1
  {
    echo "### image $side: \`$img\`"; echo '```'; cat "$d/digest"; echo; grep -A4 -- '--- rechunker-group-fix ordering lines' "$d/facts.txt"; echo '```'
  } >> "$RESULT"
}

# ---------------------------------------------------------------- install
install_to_disk() {
  local img="$1"
  log "install: $img -> $DISK ($DISK_SIZE, ext4, via-loopback)"
  rm -f "$DISK"; truncate -s "$DISK_SIZE" "$DISK"
  cp "$KEY.pub" "$PWD/vm_key.pub.copy"
  sudo podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$PWD:/data" \
    "$img" bootc install to-disk \
      --via-loopback /data/disk.raw --filesystem ext4 --wipe \
      --root-ssh-authorized-keys /data/vm_key.pub.copy \
      --karg console=ttyS0,115200 \
      --karg systemd.journald.forward_to_console=1 \
      --karg systemd.wants=sshd.service \
    2>&1 | tee "$OUT/bootc-install.log"
  local rc=${PIPESTATUS[0]}
  log "install: bootc install rc=$rc"
  # Inspect what landed (read-only): fstab, wants, BLS entries, ESP contents.
  local loop; loop=$(sudo losetup -f --show -P "$DISK")
  sudo mkdir -p /mnt/bhv-root /mnt/bhv-esp
  {
    echo "--- partitions"; lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL "$loop"
    if sudo mount -o ro "${loop}p3" /mnt/bhv-root 2>/dev/null; then
      local dep; dep=$(sudo find /mnt/bhv-root/ostree/deploy/default/deploy -mindepth 1 -maxdepth 1 -type d | head -1)
      echo "--- deployment: $dep"
      echo "--- etc/fstab"; sudo cat "$dep/etc/fstab"
      echo "--- etc/tmpfiles.d"; sudo ls -la "$dep/etc/tmpfiles.d/"; sudo cat "$dep/etc/tmpfiles.d/bootc-root-ssh.conf" 2>&1 | cut -c1-80
      echo "--- default.target.wants"; sudo ls -la "$dep/etc/systemd/system/default.target.wants/" 2>&1
      echo "--- multi-user.target.wants"; sudo ls -la "$dep/etc/systemd/system/multi-user.target.wants/" 2>&1
      echo "--- boot/loader/entries"; sudo find /mnt/bhv-root/boot/loader/entries/ -type f -exec sh -c 'echo "== $1"; cat "$1"' _ {} \; 2>&1
      echo "--- boot/grub2"; sudo ls -la /mnt/bhv-root/boot/grub2/ 2>&1; sudo head -30 /mnt/bhv-root/boot/grub2/grub.cfg 2>&1
      sudo umount /mnt/bhv-root
    else echo "mount p3 failed"; fi
    if sudo mount -o ro "${loop}p2" /mnt/bhv-esp 2>/dev/null; then
      echo "--- ESP"; sudo find /mnt/bhv-esp -maxdepth 3 2>&1; sudo umount /mnt/bhv-esp
    else echo "mount p2 (ESP) failed"; fi
  } > "$OUT/disk-after-install.txt" 2>&1
  sudo losetup -d "$loop"
  sudo podman rmi -f "$img" >/dev/null 2>&1 || true
  df -h / | tail -1 | tee -a "$OUT/harness.log"
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
    id=$(vssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    if [[ -n "$id" && "$id" != "$prev" ]]; then echo $((SECONDS - t0)); return 0; fi
    sleep 5
  done
  echo $((SECONDS - t0)); return 1
}

# ---------------------------------------------------------------- collect
collect() {
  local label="$1" d="$OUT/$1"; mkdir -p "$d"
  log "collect: $label"
  vssh 'cat /proc/sys/kernel/random/boot_id' > "$d/boot_id" 2>&1
  vssh 'uname -r' > "$d/uname" 2>&1
  vssh 'cat /proc/cmdline' > "$d/cmdline" 2>&1
  vssh 'bootc status' > "$d/bootc-status.yaml" 2>&1
  vssh 'bootc status --format json' > "$d/bootc-status.json" 2>&1
  vssh 'timeout 240 systemctl is-system-running --wait; echo "rc=$?"' > "$d/is-system-running-wait" 2>&1
  vssh 'systemctl is-system-running' > "$d/is-system-running" 2>&1
  vssh 'systemctl list-jobs --no-pager' > "$d/list-jobs" 2>&1
  vssh 'systemctl --failed --no-legend --no-pager' > "$d/failed-units" 2>&1
  vssh 'journalctl -b -o short-precise --no-pager' > "$d/journal-b.log" 2>&1
  grep -iE 'ordering cycle|deleted to break' "$d/journal-b.log" > "$d/cycle-lines" || true
  grep -iE 'Timed out waiting for device|Dependency failed for' "$d/journal-b.log" > "$d/device-timeouts" || true
  vssh 'systemd-analyze critical-chain --no-pager 2>&1' > "$d/critical-chain" 2>&1
  vssh 'systemd-analyze time 2>&1' > "$d/analyze-time" 2>&1
  vssh 'systemd-analyze verify default.target 2>&1 | grep -i cycle' > "$d/analyze-verify-cycles" 2>&1
  vssh 'findmnt -no TARGET,SOURCE,FSTYPE / /var /boot /boot/efi; echo "--- fstab"; cat /etc/fstab' > "$d/mounts" 2>&1
  vssh 'ls -la /var/home /var/roothome 2>&1' > "$d/home-dirs" 2>&1
  vssh 'systemctl show rechunker-group-fix.service -p Id -p ActiveState -p SubState -p Result -p UnitFileState -p After -p Before -p Wants; echo "--- status"; systemctl status rechunker-group-fix.service --no-pager 2>&1 | head -40; echo "--- unit file"; cat /usr/lib/systemd/system/rechunker-group-fix.service; echo "--- drop-ins"; ls -la /etc/systemd/system/rechunker-group-fix.service.d/ 2>&1' > "$d/rechunker-unit" 2>&1
  vssh 'ls -la /etc/systemd/system/default.target.wants/ /etc/systemd/system/multi-user.target.wants/ 2>&1' > "$d/wants" 2>&1
  vssh 'cat /usr/share/ublue-os/image-info.json 2>/dev/null; grep -E "^(NAME|VERSION|OSTREE_VERSION)=" /etc/os-release' > "$d/identity" 2>&1

  local img dig cyc dto state kern
  img=$(jq -r '.status.booted.image.image.image // "?"' "$d/bootc-status.json" 2>/dev/null)
  dig=$(jq -r '.status.booted.image.imageDigest // "?"' "$d/bootc-status.json" 2>/dev/null)
  cyc=$(wc -l < "$d/cycle-lines"); dto=$(wc -l < "$d/device-timeouts")
  state=$(cat "$d/is-system-running" 2>/dev/null | head -1); kern=$(cat "$d/uname")
  local line="| $label | $kern | \`$img\` | \`${dig:0:19}\` | $state | $cyc | $dto | $(wc -l < "$d/failed-units") | $(cat "$d/list-jobs" | grep -c ' waiting\| running' || true) |"
  log "collect: $line"
  echo "$line" >> "$OUT/boots.tsv"
}

postmortem() {
  local label="$1" d="$OUT/$1-postmortem"; mkdir -p "$d"
  log "postmortem: $label (no SSH) — serial tail + on-disk journal"
  tail -200 "$OUT/serial.log" > "$d/serial-tail.log"
  grep -iE 'ordering cycle|deleted to break|Timed out waiting for device' "$OUT/serial.log" > "$d/serial-cycle-lines" || true
  vm_stop
  local loop; loop=$(sudo losetup -f --show -P "$DISK")
  sudo mkdir -p /mnt/bhv-root
  if sudo mount -o ro "${loop}p3" /mnt/bhv-root; then
    local j=/mnt/bhv-root/ostree/deploy/default/var/log/journal
    sudo journalctl -D "$j" --list-boots --no-pager > "$d/list-boots" 2>&1
    sudo journalctl -D "$j" -b 0 -o short-precise --no-pager > "$d/journal-last-boot.log" 2>&1
    grep -iE 'ordering cycle|deleted to break' "$d/journal-last-boot.log" > "$d/journal-cycle-lines" || true
    sudo umount /mnt/bhv-root
  fi
  sudo losetup -d "$loop"
  echo "| $label | (no ssh) | — | — | NO-SSH | serial:$(wc -l < "$d/serial-cycle-lines") | — | — | — |" >> "$OUT/boots.tsv"
}

# ---------------------------------------------------------------- main
{
  echo "# Boot-hang verification — lane \`$LANE\`"
  echo
  echo "- OLD (installed): \`$OLD\`"
  echo "- NEW (switch target): \`${NEW:-— (control: no switch)}\`"
  echo "- runner: $(uname -a); qemu: $(qemu-system-x86_64 --version | head -1); kvm: $(ls -la /dev/kvm 2>&1)"
  echo "- started: $(date -u +%FT%TZ)"
  echo
} > "$RESULT"

image_facts old "$OLD" || { note "**HARNESS-FAILED: cannot pull OLD**"; exit 2; }
if [[ -n "$NEW" ]]; then image_facts new "$NEW" || { note "**HARNESS-FAILED: cannot pull NEW**"; exit 2; }; sudo podman rmi -f "$NEW" >/dev/null 2>&1 || true; fi

install_to_disk "$OLD"; rc=$?
if [[ $rc -ne 0 ]]; then
  if grep -q 'ostree/deploy/default/deploy' "$OUT/disk-after-install.txt" && grep -q 'BOOTX64' "$OUT/disk-after-install.txt"; then
    note "- bootc install exited $rc but deployment + ESP payload are present; continuing"
  else
    note "**HARNESS-FAILED: bootc install to-disk rc=$rc** (see bootc-install.log / disk-after-install.txt)"; exit 2
  fi
fi

echo "| boot | kernel | booted image | digest | is-system-running | ordering-cycle lines | device timeouts/dep failures | failed units | pending jobs |" > "$OUT/boots.tsv"
echo "|---|---|---|---|---|---|---|---|---|" >> "$OUT/boots.tsv"

vm_start
if t=$(wait_boot "" "$FIRST_BOOT_DEADLINE"); then
  log "boot-1 (OLD, first boot): ssh after ${t}s"
  collect boot-1-old
else
  postmortem boot-1-old
  note "**$( [[ -n $NEW ]] && echo HARNESS-FAILED || echo NO-SSH ): first boot of \`$OLD\` never reached SSH in ${FIRST_BOOT_DEADLINE}s** (see serial.log / boot-1-old-postmortem)"
  cat "$OUT/boots.tsv" >> "$RESULT"; exit 2
fi

verdict="BOOTS"; exit_code=0
if [[ -n "$NEW" ]]; then
  prev=$(cat "$OUT/boot-1-old/boot_id")
  log "switch: bootc switch --enforce-container-sigpolicy $NEW"
  t0=$SECONDS
  timeout "$SWITCH_TIMEOUT" ssh "${SSH_OPTS[@]}" root@127.0.0.1 "bootc switch --enforce-container-sigpolicy $NEW" > "$OUT/switch.log" 2>&1; src=$?
  log "switch: rc=$src after $((SECONDS - t0))s"
  note "- \`bootc switch --enforce-container-sigpolicy $NEW\` → rc=$src in $((SECONDS - t0))s (switch.log)"
  if [[ $src -ne 0 ]]; then
    tail -5 "$OUT/switch.log" | tee -a "$OUT/harness.log"
    log "switch: retrying without --enforce-container-sigpolicy"
    t0=$SECONDS
    timeout "$SWITCH_TIMEOUT" ssh "${SSH_OPTS[@]}" root@127.0.0.1 "bootc switch $NEW" > "$OUT/switch-noflag.log" 2>&1; src=$?
    note "- retry \`bootc switch $NEW\` (no flag) → rc=$src in $((SECONDS - t0))s (switch-noflag.log)"
    [[ $src -ne 0 ]] && { note "**HARNESS-FAILED: bootc switch failed both ways**"; cat "$OUT/boots.tsv" >> "$RESULT"; exit 2; }
  fi
  vssh 'bootc status' > "$OUT/after-switch-bootc-status.yaml" 2>&1
  vssh 'bootc status --format json' > "$OUT/after-switch-bootc-status.json" 2>&1
  staged=$(jq -r '.status.staged.image.imageDigest // "none"' "$OUT/after-switch-bootc-status.json")
  note "- staged after switch: \`$staged\`"
  vssh 'ls -la /etc/systemd/system/default.target.wants/ 2>&1' > "$OUT/after-switch-wants-booted-etc" 2>&1
  log "reboot into the staged deployment (firmware path: OVMF → shim → grub → ostree:0)"
  vssh 'systemctl reboot' >/dev/null 2>&1 || true
  if t=$(wait_boot "$prev" "$POST_SWITCH_DEADLINE"); then
    log "boot-2 (after switch): ssh after ${t}s"
    collect boot-2-new
    booted=$(jq -r '.status.booted.image.imageDigest // "?"' "$OUT/boot-2-new/bootc-status.json")
    if [[ "$booted" != "$staged" ]]; then note "- **WARNING: booted digest \`$booted\` != staged \`$staged\` — the new deployment was NOT booted**"; verdict="BOOTED-WRONG-DEPLOYMENT"; exit_code=1; fi
  else
    postmortem boot-2-new
    verdict="HANG"; exit_code=1
  fi
  n=2
else
  n=1
fi

# extra reboots of whatever is now booted (only if the previous boot reached ssh)
if [[ $exit_code -eq 0 ]]; then
  for i in $(seq 1 "$EXTRA_REBOOTS"); do
    prev=$(vssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    n=$((n + 1))
    log "reboot #$n"
    vssh 'systemctl reboot' >/dev/null 2>&1 || true
    if t=$(wait_boot "$prev" "$POST_SWITCH_DEADLINE"); then
      log "boot-$n: ssh after ${t}s"; collect "boot-$n"
    else
      postmortem "boot-$n"; verdict="HANG (on reboot #$n)"; exit_code=1; break
    fi
  done
fi

vm_stop
{
  echo; echo "## Boots"; echo; cat "$OUT/boots.tsv"; echo
  total_cycles=$(cat "$OUT"/boot-*/cycle-lines 2>/dev/null | wc -l)
  echo "## Verdict: **$verdict** — ordering-cycle journal lines across all boots: $total_cycles"
  echo; echo "finished: $(date -u +%FT%TZ)"
} >> "$RESULT"
cat "$RESULT" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
cat "$RESULT"
exit "$exit_code"

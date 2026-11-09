#!/usr/bin/env bash
# smoke-googlebook.sh
# Picked up automatically by smoketests-all.sh, which globs /usr/local/bin/smoke-*.sh.
#
# Most of this re-checks what install-googlebook-layer.sh already asserts at build time.
# That is deliberate: those assertions only cover the layer's own build, and this image
# tracks a base image that moves underneath it. A base rebuild that bumps the kernel
# without a matching rebuild here would leave modules that silently refuse to load, and on
# Moonstone that means Slot B boots to a black screen with nothing in the logs.
set -euo pipefail
echo "$(basename "$0") started"

fail=0
check() {
  desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   $desc"
  else
    echo "  FAIL $desc"
    fail=1
  fi
}

KVER=$(ls /usr/lib/modules | head -1)
echo "image kernel: $KVER"

# --- out-of-tree modules match the kernel they will be loaded against -------------------
for ko in "/usr/lib/modules/$KVER/extra"/*.ko "/usr/lib/modules/$KVER/updates"/*.ko; do
  [ -f "$ko" ] || continue
  got=$(modinfo -F vermagic "$ko" | awk '{print $1}')
  if [ "$got" = "$KVER" ]; then
    echo "  ok   vermagic $(basename "$ko")"
  else
    echo "  FAIL vermagic $(basename "$ko"): '$got' != '$KVER'"
    fail=1
  fi
done

# --- and are reachable by name, which is how the initramfs and modules-load.d load them --
for mod in coreboot_table framebuffer-coreboot cros_ec_ishtp \
           snd-soc-sof-sdw snd-soc-sdw-utils; do
  check "modprobe resolves $mod" modinfo -k "$KVER" "$mod"
done

# --- firmware the initramfs pulls in by absolute path ----------------------------------
check "ISH firmware present" \
  test -f /usr/lib/firmware/intel/ish/ish_ptl_62b0f067_501de2f8.bin
check "RT1320 calibration present" \
  test -f /usr/lib/firmware/realtek/rt1320/rt1320_Google_Moonstone_sku1.dat

# --- Vivaldi top row. The /etc copy of hwdb.bin shadows /usr/lib, so this catches a base
# --- image that reintroduces one and silently disables the keymap again.
check "Moonstone hwdb entry resolves" \
  sh -c 'systemd-hwdb query "evdev:atkbd:dmi:bvnA:bvrB:bdC:br1:svnGoogle:pnMoonstone:pvr1" | grep -q KEYBOARD_KEY_91'

# --- dracut drop-ins that keep the Slot B ramdisks inside their 32 MiB / 8 MiB budget ---
check "Slot B dracut conf present" \
  test -f /usr/lib/dracut/dracut.conf.d/90-googlebook-slotb.conf
check "sensor dracut conf present" \
  test -f /usr/lib/dracut/dracut.conf.d/91-googlebook-sensors.conf
# composefs is how an ostree deployment mounts /usr. Without erofs and overlay in the
# initramfs, ostree-prepare-root fails with ENODEV and Slot B never reaches switch-root.
check "composefs modules pinned in add_drivers" \
  grep -qE 'add_drivers.*erofs.*overlay' /usr/lib/dracut/dracut.conf.d/90-googlebook-slotb.conf
check "composefs modules pinned in filesystems (independent instmods batch)" \
  grep -qE 'filesystems.*erofs.*overlay' /usr/lib/dracut/dracut.conf.d/90-googlebook-slotb.conf
# Must be a basename the packer does not also write into /etc, or dracut shadows it.
check "bootc dracut omit list present" \
  test -f /usr/lib/dracut/dracut.conf.d/92-googlebook-bootc.conf
check "omit list is not shadowed by a packer-written /etc copy" \
  sh -c '! test -f /etc/dracut.conf.d/92-googlebook-bootc.conf'
check "clevis is omitted" \
  grep -q 'clevis' /usr/lib/dracut/dracut.conf.d/92-googlebook-bootc.conf
# --- the initramfs must be able to act on ostree= ----------------------------------------
# 50ostree's check() returns 255: available, but included only when a dracut.conf.d file
# names it in add_dracutmodules. The base image used to do that in 20-bootc-base.conf and
# stopped when it swapped to rpm-ostree's 20-atomic-*.conf set - after which dracut built
# initramfses with erofs and overlay but no ostree-prepare-root.service, and Slot B
# switch-rooted into the bare subvolume with nothing logged. install-googlebook-layer.sh
# asserts this at build time; re-assert it here because every link but 92-googlebook-bootc.conf
# belongs to the base image and can move under this layer between builds.
#
# Shadowing is already covered: the check above asserts no /etc copy of 92 exists, and 92 is
# the file that carries the request, so a plain scan of both directories is enough here.
check "dracut config requests the ostree module" sh -c '
  cat /etc/dracut.conf.d/*.conf /usr/lib/dracut/dracut.conf.d/*.conf 2>/dev/null \
    | grep -E "^[[:space:]]*add_dracutmodules" \
    | grep -qE "[[:space:]\"]ostree[[:space:]\"]"'
# Requested is not enough: 50ostree returns 1 - never include - unless both of these are
# executable, which would leave the request satisfied and the initramfs still broken.
check "50ostree dracut module present" \
  test -d /usr/lib/dracut/modules.d/50ostree
check "ostree-prepare-root present (50ostree check() precondition)" \
  test -x /usr/lib/ostree/ostree-prepare-root
check "ostree-prepare-root.service present (what gets linked into initrd-root-fs.target.wants)" \
  test -f /usr/lib/systemd/system/ostree-prepare-root.service
check "coreboot framebuffer autoload present" \
  test -f /usr/lib/modules-load.d/googlebook-coreboot-fb.conf
check "staged Xe2 modprobe rules present" \
  test -f /usr/lib/modprobe.d/googlebook-xe-staged.conf
check "/var/lib/googlebook tmpfiles entry present" \
  grep -q '/var/lib/googlebook' /usr/lib/tmpfiles.d/googlebook.conf

# --- directories this image ships into must stay traversable by non-root -----------------
# `COPY --chmod=0644 configs/ /` chmods directories as well as files, and not only the ones
# it creates: it walks the destination path and leaves /usr/lib, /usr/share,
# /usr/lib/systemd/system and friends at 0644. root is exempt (CAP_DAC_OVERRIDE), so an
# image broken this way builds, lints and passes every root-run check while no user session
# works on it - gdm cannot read /usr/share, pipewire cannot read the UCM config below.
# Checked here as well as at build time because the base image is built from a separate
# Containerfile that can reintroduce it underneath this layer at any time.
untraversable=0
for d in /usr /usr/lib /usr/lib/systemd /usr/lib/systemd/system /usr/lib/udev \
         /usr/lib/udev/hwdb.d /usr/lib/dracut /usr/lib/dracut/dracut.conf.d \
         /usr/lib/modprobe.d /usr/lib/modules-load.d /usr/lib/tmpfiles.d \
         /usr/lib/modules /usr/lib/firmware /usr/share /usr/share/alsa \
         /usr/local /usr/local/bin /usr/local/sbin /usr/local/share \
         /etc /etc/yum.repos.d /etc/keyd; do
  [ -d "$d" ] || continue
  if [ -n "$(find "$d" -maxdepth 0 ! -perm -o=rx 2>/dev/null)" ]; then
    echo "  FAIL $d is $(stat -c %A "$d") - not traversable by non-root"
    untraversable=1
    fail=1
  fi
done
if [ "$untraversable" -eq 0 ]; then
  echo "  ok   shipped directories traversable by non-root"
fi

# --- the toolkit entry points -----------------------------------------------------------
for tool in googlebook-pack-slotb googlebook-restore-slotb googlebook-switch-slot \
            googlebook-sysroot-sync googlebook-slotb-sync googleboot-menu googleboot-scan \
            boot-android; do
  check "$tool is executable" test -x "/usr/local/bin/$tool"
done
check "googleboot-menu is a built binary" \
  sh -c 'file -b "$(readlink -f /usr/local/bin/googleboot-menu)" | grep -q ELF'
check "packer parses" bash -n /usr/local/share/googlebook-dualboot/bin/googlebook-pack-slotb
check "sync wrapper parses" bash -n /usr/local/bin/googlebook-slotb-sync

# --- the tools the packer shells out to -------------------------------------------------
for cmd in dracut mkbootimg kexec sgdisk zstd depmod cpio findmnt; do
  check "$cmd available" command -v "$cmd"
done

# --- units that keep Slot B in step with the deployment ----------------------------------
check "googlebook-slotb-sync.path enabled" \
  systemctl is-enabled googlebook-slotb-sync.path
check "googlebook-gpu-init.service enabled" \
  systemctl is-enabled googlebook-gpu-init.service
# bootupd updates GRUB in an ESP. There is no ESP and no GRUB on a Depthcharge machine, so
# it fails every boot and buries real failures in `systemctl --failed`.
check "bootloader-update.service masked (no ESP on this machine)" \
  sh -c '[ "$(systemctl is-enabled bootloader-update.service 2>&1)" = masked ]'
# gnome-software has no bootc plugin and falls back to rpm-ostreed, which prompts for a
# password at every login and refreshes every repo in /etc/yum.repos.d. The OS is updated with
# bootc, so Software keeps only its application and firmware roles.
check "gnome-software package backends removed" \
  sh -c '! ls /usr/lib64/gnome-software/plugins-*/libgs_plugin_dnf5.so \
           /usr/lib64/gnome-software/plugins-*/libgs_plugin_rpm-ostree.so >/dev/null 2>&1'
check "gnome-software flatpak backend kept" \
  sh -c 'ls /usr/lib64/gnome-software/plugins-*/libgs_plugin_flatpak.so >/dev/null 2>&1'

# --- runtime-only: these need a real deployment, not a container -------------------------
BOOTIMAGE=$(bootc status --booted --format json 2>/dev/null | jq -r '.spec.image // "null"' || echo null)
if [ "$BOOTIMAGE" = "null" ]; then
  echo "  --   not a bootc system, skipping deployment checks"
else
  echo "Running under bootc - image=$BOOTIMAGE"
  check "ostree deployment marker" test -f /run/ostree-booted
  check "an ostree boot entry carries ostree=" \
    sh -c 'grep -qs "ostree=" /boot/loader/entries/*.conf'
  check "slotb-sync state directory" test -d /var/lib/googlebook
  # An in-place migration can leave files in /etc with no SELinux label. Confined domains
  # cannot even getattr an unlabeled_t file, so this surfaces as "Permission denied" from
  # processes running as root and is easy to misread. Observed on a converted machine:
  # /etc/udev/hwdb.bin unlabeled, which broke systemd-hwdb-update.service (leaving a
  # truncated index that udev refuses to parse, costing the whole Vivaldi keymap) and
  # colord's read of the same inode. Fix with: restorecon -Rv /etc
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    unlabeled=$(find /etc -context '*unlabeled_t*' 2>/dev/null | head -20)
    if [ -z "$unlabeled" ]; then
      echo "  ok   no unlabeled files in /etc"
    else
      echo "  FAIL unlabeled files in /etc (run: restorecon -Rv /etc):"
      echo "$unlabeled" | sed 's/^/         /'
      fail=1
    fi
  fi
  # /etc/udev/hwdb.bin is redundant here - the image keeps the index in /usr - and is the one
  # file that has actually caused this. Its absence also drops systemd-hwdb-update.service
  # out of its own OR'd conditions, so it is skipped rather than failing every boot.
  check "no redundant /etc/udev/hwdb.bin shadowing the /usr index" \
    sh -c '! test -f /etc/udev/hwdb.bin || test -n "$(ls -A /etc/udev/hwdb.d 2>/dev/null)"'
  check "systemd-hwdb-update.service is not failed" \
    sh -c '[ "$(systemctl is-failed systemd-hwdb-update.service 2>&1)" != failed ]'
fi

if [ "$fail" -ne 0 ]; then
  echo "$(basename "$0") FAILED"
  exit 1
fi
echo "$(basename "$0") finished"

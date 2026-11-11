#!/bin/bash
# install-into-initramfs.sh
# Injects the compiled googleboot-menu binary, googleboot-scan backend, kexec binary,
# and systemd initrd service into an unpacked Slot B rd_vendor directory.
#
# Usage:
#   ./scripts/install-into-initramfs.sh /path/to/unpacked_rd_vendor

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RD_DIR="${1:?Usage: $0 /path/to/unpacked_rd_vendor}"

make -B -C "$SCRIPT_DIR" 2>/dev/null || [[ -x "$SCRIPT_DIR/bin/googleboot-menu" ]]

mkdir -p "$RD_DIR/usr/local/bin" \
         "$RD_DIR/boot/googlebook-theme" \
         "$RD_DIR/etc/systemd/system/sysinit.target.wants" \
         "$RD_DIR/etc/systemd/system/initrd.target.wants"

cp -f "$SCRIPT_DIR/bin/googleboot-menu" "$RD_DIR/usr/local/bin/googleboot-menu"
cp -f "$SCRIPT_DIR/bin/googleboot-scan" "$RD_DIR/usr/local/bin/googleboot-scan"
for name in googlebook-switch-slot googlebook-restore-slotb; do
  cp -f "$SCRIPT_DIR/../bin/$name" "$RD_DIR/usr/local/bin/$name"
  chmod 755 "$RD_DIR/usr/local/bin/$name"
done
cp -f "$SCRIPT_DIR/theme/theme.conf" "$RD_DIR/boot/googlebook-theme/theme.conf"
chmod 755 "$RD_DIR/usr/local/bin/googleboot-menu" \
          "$RD_DIR/usr/local/bin/googleboot-scan"

if command -v kexec >/dev/null 2>&1; then
  cp -f "$(command -v kexec)" "$RD_DIR/usr/sbin/kexec"
  chmod 755 "$RD_DIR/usr/sbin/kexec"
fi

# Do not carry the old whole-disk write grant into the rebuilt initramfs.
rm -f "$RD_DIR/etc/udev/rules.d/99-googlebook-slotb.rules" "$RD_DIR/etc/sudoers.d/googlebook-slotb"

# Prevent plymouth from grabbing DRM master (/dev/dri/card0) before googleboot-menu
rm -f "$RD_DIR/usr/lib/systemd/system/sysinit.target.wants/plymouth-start.service" \
      "$RD_DIR/etc/systemd/system/sysinit.target.wants/plymouth-start.service" 2>/dev/null || true

# Ensure systemd-cryptsetup waits for googleboot-menu and skips re-prompting if already unlocked (any LUKS UUID/name)
CRYPT_DROPIN_DIR="$RD_DIR/etc/systemd/system/systemd-cryptsetup@.service.d"
mkdir -p "$CRYPT_DROPIN_DIR"
cat > "$CRYPT_DROPIN_DIR/skip-if-unlocked.conf" << 'EOF'
[Unit]
After=googleboot-menu.service
ConditionPathExists=!/dev/mapper/%i
EOF

cat > "$RD_DIR/etc/systemd/system/googleboot-menu.service" << 'EOF'
[Unit]
Description=GoogleBook Moonstone Graphical kexec Boot Menu
DefaultDependencies=no
After=systemd-udevd.service systemd-udev-trigger.service systemd-modules-load.service
# The last three Before= entries are what actually gate this boot, and leaving them out cost
# the menu its countdown. With root=UUID= on the command line and the NVMe driver already in
# rd.driver.pre, systemd-fstab-generator mounts sysroot itself and dracut-initqueue never
# runs at all - so ordering before initqueue gated nothing. sysroot mounted about a second
# in, initrd-root-fs.target was reached, and initrd-cleanup.service isolated
# initrd-switch-root.target, which STOPS every unit not part of that target regardless of
# ordering: the menu died on SIGTERM at 1.07s with its 5-second timer still running and the
# selector flashed up unreadably. Before=initrd-switch-root.target does not help, because an
# isolate is not an ordering question. Measured on Moonstone; it only looked fine while a
# stale ostree= kept sysroot from mounting at all, which let the menu outlive the boot.
Before=cryptsetup-pre.target cryptsetup.target initrd-switch-root.target dracut-initqueue.service initrd-cleanup.service sysroot.mount initrd-root-fs.target
# And stop as part of the switch-root transaction, which is a different problem from the
# ordering above: this unit is Type=oneshot with RemainAfterExit=yes, so without Conflicts=
# it is still *active* when systemd serializes its state across switch-root. The new root
# has no fragment for it - it only ever existed inside the ramdisk - so systemd re-reads it
# as not-found and parks it in `systemctl --failed` on every single boot, where it fails
# smoke-base-system.sh and buries any real failure next to it. Conflicts= is the standard
# dracut idiom for this; dracut-initqueue.service and friends all carry it. The two fixes
# are independent: ordering alone leaves the unit listed as failed, Conflicts= alone leaves
# the menu with a one-second life.
Conflicts=initrd-switch-root.target

[Service]
Type=oneshot
# Release discovery mounts when the menu exits, even if explicit unmount fails.
PrivateMounts=yes
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
ExecStart=/bin/sh -c 'modprobe nvme nvme_core ext4 btrfs vfat fat dm_crypt usb_storage uas 2>/dev/null || true; udevadm settle --timeout=3 2>/dev/null || sleep 1; for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/dri/card0 ] && break; sleep 0.2; done; exec /usr/local/bin/googleboot-menu'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target initrd.target
EOF

ln -sf ../googleboot-menu.service "$RD_DIR/etc/systemd/system/sysinit.target.wants/googleboot-menu.service"
ln -sf ../googleboot-menu.service "$RD_DIR/etc/systemd/system/initrd.target.wants/googleboot-menu.service"
echo "==> Installed googleboot-menu and googleboot-menu.service into $RD_DIR"

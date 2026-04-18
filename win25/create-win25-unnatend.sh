#!/bin/bash
# create-opnsense26.sh
# fw01 — OPNsense 26.1.2 firewall VM for ad.lab
# Interfaces: vtnet0=WAN vtnet1=LAN vtnet2=DMZ vtnet3=MGMT

set -e

VM_NAME="fw01"
ORIG_ISO="/home/huber/Downloads/OPNsense-26.1.2-dvd-amd64.iso"
DISK_PATH="/vms/fw01.qcow2"
NEW_ISO="/vms/fw01-config.iso"
CONFIG_DIR="$(pwd)/config"

DISK_SIZE=20
RAM=4096
VCPUS=2

WAN_NET="lab-wan"
LAN_NET="lab-lan"
DMZ_NET="lab-dmz"
MGMT_NET="lab-mgmt"

# ── dependency check ──────────────────────────────────────────
for cmd in virt-install qemu-img virsh genisoimage; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "Install: apt install virtinst qemu-utils genisoimage"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ] && echo "ERROR: ISO not found: $ORIG_ISO" && exit 1
[ ! -f "$CONFIG_DIR/conf/config.xml" ] && echo "ERROR: config.xml not found: $CONFIG_DIR/conf/config.xml" && exit 1

mkdir -p /vms

# ── clean old VM ──────────────────────────────────────────────
echo "[1/4] Cleaning old VM if exists..."
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH" "$NEW_ISO"

# ── create disk ───────────────────────────────────────────────
echo "[2/4] Creating disk..."
qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# ── build config ISO from existing config/conf/config.xml ─────
echo "[3/4] Building config ISO from $CONFIG_DIR/conf/config.xml..."
genisoimage \
  -o "$NEW_ISO" \
  -r -J \
  -V "OPNsense_Config" \
  "$CONFIG_DIR"
echo "    Config ISO: $NEW_ISO"

# ── launch VM ─────────────────────────────────────────────────
echo "[4/4] Launching $VM_NAME..."

virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     freebsd13.0 \
  --machine        q35 \
  --boot           cdrom,hd \
  --disk           path="$DISK_PATH",format=qcow2,bus=virtio \
  --cdrom          "$ORIG_ISO" \
  --disk           path="$NEW_ISO",device=cdrom,bus=sata \
  --network        network="$WAN_NET",model=virtio \
  --network        network="$LAN_NET",model=virtio \
  --network        network="$DMZ_NET",model=virtio \
  --network        network="$MGMT_NET",model=virtio \
  --graphics       spice \
  --video          virtio \
  --noautoconsole

echo ""
echo "✅ $VM_NAME created!"
echo ""
echo "Open console:"
echo "  virt-viewer $VM_NAME"
echo ""
echo "Credentials:"
echo "  user: root  or  installer"
echo "  pass: opnsense"
echo ""
echo "Expected interface assignment:"
echo "  vtnet0 → WAN   10.0.0.2/30    gateway: 10.0.0.1"
echo "  vtnet1 → LAN   10.0.1.1/24"
echo "  vtnet2 → DMZ   10.0.2.1/24"
echo "  vtnet3 → MGMT  10.0.3.1/24"
echo ""
echo "WebGUI after install (from LAN):"
echo "  https://10.0.1.1"
echo "  user: root"
echo "  pass: opnsense"
echo ""
echo "After install reboot, verify interfaces:"
echo "  Menu option 1 → confirm vtnet0-3 assignments"
echo "  Menu option 2 → confirm IPs match above"

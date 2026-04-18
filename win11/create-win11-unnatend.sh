#!/bin/bash
# create-win11-unattended.sh
# Windows 11 unattended install — UEFI/GPT via q35.
# Requirements: p7zip-full, genisoimage, qemu-utils, virtinst, ovmf
#   apt install p7zip-full genisoimage qemu-utils virtinst ovmf

set -e

VM_NAME="win11"
ORIG_ISO="/home/huber/Downloads/Your_Windows_11_ISO.iso"  # CHANGE THIS PATH
ANSWER_FILE="/home/huber/wd/libvirt/autounattend.xml"
NEW_ISO="/home/huber/wd/libvirt/win11-unattended.iso"
WORK_DIR="/tmp/win11-iso-work"
DISK_PATH="/vms/win11.qcow2"
DISK_SIZE=80   # Windows 11 needs more space
RAM=8192       # Windows 11 recommends 8GB
VCPUS=4        # Windows 11 runs better with 4 cores

# Dependency check
for cmd in 7z genisoimage qemu-img virt-install; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found."
    echo "  Install: apt install p7zip-full genisoimage qemu-utils virtinst ovmf"
    exit 1
  }
done

[ ! -f "$ORIG_ISO" ]    && echo "ERROR: ISO not found: $ORIG_ISO"            && exit 1
[ ! -f "$ANSWER_FILE" ] && echo "ERROR: Answer file not found: $ANSWER_FILE" && exit 1

if [ ! -f /usr/share/OVMF/OVMF_CODE.fd ] && [ ! -f /usr/share/ovmf/OVMF.fd ]; then
  echo "ERROR: OVMF not found. Install with: apt install ovmf"
  exit 1
fi

mkdir -p /vms

# 1. Extract ISO
echo "[1/4] Extracting ISO..."
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
7z x "$ORIG_ISO" -o"$WORK_DIR" -y > /dev/null

# 2. Inject answer file
echo "[2/4] Injecting autounattend.xml..."
cp "$ANSWER_FILE" "$WORK_DIR/autounattend.xml"

# For Windows 11, also copy to root and add to sources
cp "$ANSWER_FILE" "$WORK_DIR/Autounattend.xml" 2>/dev/null || true

# 3. Rebuild bootable ISO
echo "[3/4] Rebuilding ISO at $NEW_ISO ..."
genisoimage \
  -iso-level 4 \
  -l -R -J \
  -no-emul-boot \
  -b boot/etfsboot.com \
  -boot-load-size 8 \
  -boot-load-seg 0x07C0 \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys_noprompt.bin \
  -no-emul-boot \
  -allow-limited-size \
  -relaxed-filenames \
  -joliet-long \
  -o "$NEW_ISO" \
  "$WORK_DIR"

# 4. Clean up old VM, create disk, launch with UEFI
echo "[4/4] Creating disk and launching VM (UEFI)..."
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
rm -f "$DISK_PATH"

qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

virt-install \
  --name           "$VM_NAME" \
  --ram            "$RAM" \
  --vcpus          "$VCPUS" \
  --os-variant     win11 \
  --machine        q35 \
  --boot           uefi \
  --disk           path="$DISK_PATH",format=qcow2,bus=virtio \
  --cdrom          "$NEW_ISO" \
  --network        network=default,model=virtio \
  --graphics       spice \
  --video          qxl \
  --tpm            backend.type=emulator,backend.version=2.0,model=tpm-tis \
  --features       smm.state=on \
  --noautoconsole

echo ""
echo "Done. VM is installing Windows 11 unattended (UEFI/GPT)."
echo "  Watch progress : virt-viewer $VM_NAME"
echo "  Check state    : virsh domstate $VM_NAME"
echo "  List VMs       : virsh list --all"

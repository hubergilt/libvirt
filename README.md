# Windows VM AutoInstall for KVM/QEMU

Automated unattended installation of Windows 10, 11, and Windows Server (2019, 2022, 2025) on KVM/QEMU with UEFI/GPT support.

## Repository Structure
├── autounattend.xml # Generic answer file (copy as needed)
├── create-win10-unattended.sh # Windows 10 Pro installer
├── create-win11-unattended.sh # Windows 11 Pro installer (TPM 2.0)
├── create-win19-unattended.sh # Windows Server 2019
├── create-win22-unattended.sh # Windows Server 2022
├── create-win25-unattended.sh # Windows Server 2025
├── create-win19-manual.sh # Windows Server 2019 (manual install)
├── win10/autounattend.xml # Win10 specific answer file
├── win11/autounattend.xml # Win11 specific answer file
├── win19/autounattend.xml # Server 2019 answer file
├── win22/autounattend.xml # Server 2022 answer file
└── win25/autounattend.xml # Server 2025 answer file


## Features

- ✅ **Fully unattended** installation
- ✅ **UEFI/GPT** partitioning (no MBR)
- ✅ **Secure Boot** support (Windows 11)
- ✅ **TPM 2.0** emulation (Windows 11)
- ✅ Automatic disk partitioning (EFI + MSR + OS)
- ✅ Pre-configured administrator password
- ✅ Timezone: `SA Pacific Standard Time` (change as needed)
- ✅ Bypasses online account requirement

## Prerequisites

### Debian/Ubuntu

```bash
sudo apt update
sudo apt install -y \
    p7zip-full \
    genisoimage \
    qemu-utils \
    virtinst \
    ovmf \
    swtpm                    # Required for Windows 11 TPM

Quick Start
1. Download Windows ISO

Get the official ISO from Microsoft:

    Windows 10/11: Microsoft Software Download

    Windows Server: Microsoft Evaluation Center

2. Edit script configuration

Open the desired script and update:
bash

ORIG_ISO="/path/to/your/windows.iso"      # Change this
ANSWER_FILE="/path/to/autounattend.xml"   # Change this

3. Run the installer
bash

chmod +x create-*.sh

# Windows 11
./create-win11-unattended.sh

# Windows Server 2025
./create-win25-unattended.sh

4. Connect to VM
bash

virt-viewer win11
# or
virsh console win11

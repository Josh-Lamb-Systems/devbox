#!/usr/bin/env bash
# Clone the Ubuntu dev template (9000) into a new VM with user-supplied
# cores, memory, VM ID, and name.
set -euo pipefail

TEMPLATE_ID=9000
DISK_SIZE="100G"
CI_USER="josh"
SSH_KEY="/root/.ssh/macbook.pub"
# Inherit cicustom vendor-data from the template, including custom snippet names.

is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# Check the SSH key up front so a bad key doesn't leave a half-built VM.
# Proxmox rejects keys with Windows line endings (CRLF) or anything that
# isn't a valid public key line, so clean it into a temp copy and verify it.
[[ -r "$SSH_KEY" ]] || { echo "Error: SSH key file $SSH_KEY not found or not readable." >&2; exit 1; }
CLEAN_KEY=$(mktemp)
trap 'rm -f "$CLEAN_KEY"' EXIT
tr -d '\r' < "$SSH_KEY" | sed -e 's/[[:space:]]*$//' -e '/^$/d' > "$CLEAN_KEY"
if ! ssh-keygen -l -f "$CLEAN_KEY" &>/dev/null; then
  echo "Error: $SSH_KEY is not a valid SSH public key." >&2
  echo "       It should be a single line like: ssh-ed25519 AAAA... josh@host" >&2
  echo "       (Make sure it's the .pub file, not the private key.)" >&2
  exit 1
fi

read -rp "Number of cores: " CORES
is_positive_int "$CORES" || { echo "Error: cores must be a positive whole number." >&2; exit 1; }

read -rp "Memory (GB): " MEMORY_GB
is_positive_int "$MEMORY_GB" || { echo "Error: memory must be a positive whole number of GB." >&2; exit 1; }
MEMORY_MB=$(( MEMORY_GB * 1024 ))

read -rp "Destination VM ID: " VMID
is_positive_int "$VMID" || { echo "Error: VM ID must be a positive whole number." >&2; exit 1; }
if qm status "$VMID" &>/dev/null; then
  echo "Error: VM $VMID already exists." >&2
  exit 1
fi

read -rp "Destination VM name: " VM_NAME
[[ "$VM_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
  echo "Error: VM name must be a valid DNS name (letters, digits, hyphens, dots)." >&2; exit 1; }

echo
echo "About to create VM $VMID ($VM_NAME): $CORES cores, ${MEMORY_GB}GB (${MEMORY_MB}MB) RAM, $DISK_SIZE disk"
read -rp "Proceed? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

qm clone "$TEMPLATE_ID" "$VMID" --name "$VM_NAME" --full 1
qm set "$VMID" --cores "$CORES" --memory "$MEMORY_MB"
qm set "$VMID" --agent enabled=1
qm disk resize "$VMID" scsi0 "$DISK_SIZE"
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --sshkeys "$CLEAN_KEY"
qm set "$VMID" --ipconfig0 ip=dhcp
qm start "$VMID"

echo "VM $VMID ($VM_NAME) created and started."

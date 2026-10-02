#!/usr/bin/env bash
# Revised 2026-10-02: Ubuntu LTS discovery, offline image preparation, and JLS vendor-data.
# Run on an amd64 Proxmox VE host. Never boot the template before cloning it.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VMID=${VMID:-9000}
STORAGE=${STORAGE:-live}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-local}
VENDOR_DATA=${VENDOR_DATA:-$SCRIPT_DIR/jls-ubuntu-dev-vendor-data.yaml}
SNIPPET_NAME=${SNIPPET_NAME:-jls-ubuntu-dev-vendor-data.yaml}
CI_USER=${CI_USER:-josh}
SSH_KEY=${SSH_KEY:-/root/.ssh/macbook.pub}
BRIDGE=${BRIDGE:-vmbr0}
CPU=${CPU:-host}
CORES=${CORES:-4}
MEMORY=${MEMORY:-4096}
DISK_GB=${DISK_GB:-32}
UBUNTU_RELEASE=${UBUNTU_RELEASE:-latest}
WORK_ROOT=${WORK_ROOT:-/var/tmp}

usage() {
    cat <<'HELP'
Usage: bash qmtemplatemaker.sh [--help]
Run as root on Proxmox VE. Settings are environment variables:
  VMID=9000                 Unused template ID (matches devbox.sh)
  STORAGE=live              Active storage accepting VM images
  SNIPPET_STORAGE=local     Active file storage accepting snippets
  VENDOR_DATA=<beside script>/jls-ubuntu-dev-vendor-data.yaml
  SNIPPET_NAME=jls-ubuntu-dev-vendor-data.yaml
  CI_USER=josh              Default clone login
  SSH_KEY=/root/.ssh/macbook.pub   Public key file, never a private key
  BRIDGE=vmbr0 CPU=host CORES=4 MEMORY=4096 DISK_GB=32
  UBUNTU_RELEASE=latest     Latest supported released LTS; or pin e.g. 24.04
  VM_NAME=<automatic>       Optional template name
  WORK_ROOT=/var/tmp        Staging filesystem with several GB free

Example:
  STORAGE=local-lvm SSH_KEY=/root/.ssh/laptop.pub bash qmtemplatemaker.sh

Required host packages (install first):
  apt-get update
  apt-get install -y libguestfs-tools curl python3 openssh-client

Enable Snippets in Datacenter > Storage > your snippet storage > Edit.
An existing snippet is reused only if its contents match; use a new
SNIPPET_NAME for changed vendor-data to avoid changing existing clones.
No existing VM is overwritten or automatically deleted on failure.
HELP
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 0 ]] || { usage >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'Run as root on the Proxmox host.'
[[ $(uname -m) == x86_64 ]] || fail 'This script builds amd64 KVM templates only.'
for cmd in qm pvesm pvesh curl python3 virt-customize qemu-img ssh-keygen sha256sum flock; do
    command -v "$cmd" >/dev/null || fail "Missing $cmd. See --help for prerequisites."
done
[[ $VMID =~ ^[1-9][0-9]{2,8}$ ]] || fail 'VMID must be 100 through 999999999.'
for value in "$CORES" "$MEMORY" "$DISK_GB"; do
    [[ $value =~ ^[1-9][0-9]{0,6}$ ]] || fail 'CORES, MEMORY, DISK_GB must be positive integers.'
done
[[ $CI_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'Invalid CI_USER.'
for value in "$STORAGE" "$SNIPPET_STORAGE"; do
    [[ $value =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || fail 'Invalid storage name.'
done
[[ $SNIPPET_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ ]] || fail 'SNIPPET_NAME must be a YAML basename.'
[[ -d /sys/class/net/$BRIDGE/bridge ]] || fail "Bridge $BRIDGE does not exist."
[[ -r $VENDOR_DATA && -s $VENDOR_DATA ]] || fail "Cannot read vendor-data: $VENDOR_DATA"
[[ $(head -n 1 "$VENDOR_DATA") == '#cloud-config' ]] || fail 'Vendor-data must start with #cloud-config.'
[[ -r $SSH_KEY && -s $SSH_KEY ]] || fail "Cannot read SSH public key: $SSH_KEY"
[[ -d $WORK_ROOT && $WORK_ROOT != *','* ]] || fail 'WORK_ROOT must exist and contain no comma.'
WORK_ROOT=$(cd -- "$WORK_ROOT" && pwd -P)
[[ $WORK_ROOT != *','* ]] || fail 'Resolved WORK_ROOT must contain no comma.'
# Serialize this script on this node; qm create also enforces cluster-wide ID uniqueness.
exec 9>/run/lock/jls-template-maker.lock
flock -n 9 || fail 'Another template build is already running on this node.'

WORK_DIR=$(mktemp -d "$WORK_ROOT/jls-template.XXXXXXXX")
created=0
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$WORK_DIR"
    if (( status != 0 && created == 1 )); then
        printf 'Build failed. VM %s was retained for inspection (qm config %s).\n' "$VMID" "$VMID" >&2
        printf 'Inspect it before manually removing it or choosing another VMID.\n' >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Failed at line %s.\n" "$LINENO" >&2' ERR

# Check both QEMU VMs and containers, on every node. API failures must stop the build.
pvesh get /cluster/resources --type vm --output-format json > "$WORK_DIR/resources.json"
python3 - "$WORK_DIR/resources.json" "$VMID" <<'PY'
import json, sys
if any(str(v['vmid']) == sys.argv[2] for v in json.load(open(sys.argv[1]))):
    sys.exit('VMID already exists in this cluster: ' + sys.argv[2])
PY
check_storage() {
    local storage=$1 content=$2
    pvesm status --storage "$storage" --content "$content" > "$WORK_DIR/storage-status"
    awk -v storage="$storage" '$1 == storage && $3 == "active" {found=1} END {exit !found}' \
        "$WORK_DIR/storage-status" || fail "$storage must be active and support $content on this node."
}
check_storage "$STORAGE" images
check_storage "$SNIPPET_STORAGE" snippets
SNIPPET_VOL="$SNIPPET_STORAGE:snippets/$SNIPPET_NAME"
SNIPPET_PATH=$(pvesm path "$SNIPPET_VOL")
[[ $SNIPPET_PATH == /* ]] || fail 'Snippet storage did not resolve to an absolute path.'
if [[ -e $SNIPPET_PATH || -L $SNIPPET_PATH ]]; then
    cmp -s "$VENDOR_DATA" "$SNIPPET_PATH" || fail "Existing snippet differs: $SNIPPET_PATH. Set a new SNIPPET_NAME."
fi
tr -d '\r' < "$SSH_KEY" | sed -e 's/[[:space:]]*$//' -e '/^$/d' > "$WORK_DIR/keys.pub"
! grep -q 'PRIVATE KEY' "$WORK_DIR/keys.pub" || fail 'SSH_KEY contains a private key.'
ssh-keygen -l -f "$WORK_DIR/keys.pub" >/dev/null || fail 'SSH_KEY is not a valid public key file.'

fetch() { curl --fail --location --show-error --retry 3 --connect-timeout 30 --proto '=https' --proto-redir '=https' "$1" --output "$2"; }
echo 'Discovering released Ubuntu LTS images from Canonical...'
fetch 'https://cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json' "$WORK_DIR/releases.json"
# Use the dated image path and its checksum from the same metadata snapshot.
python3 - "$WORK_DIR/releases.json" "$UBUNTU_RELEASE" > "$WORK_DIR/selected" <<'PY'
import json, re, sys
products = json.load(open(sys.argv[1]))['products'].values()
candidates = [p for p in products if p.get('arch') == 'amd64'
              and p.get('os') == 'ubuntu' and p.get('supported') is True
              and 'LTS' in p.get('release_title', '')
              and (sys.argv[2] == 'latest' or sys.argv[2] == p.get('version'))]
if not candidates:
    sys.exit('No matching supported Ubuntu LTS in Canonical metadata.')
p = max(candidates, key=lambda p: tuple(map(int, p['version'].split('.'))))
versions = [(v, data) for v, data in p['versions'].items()
            if data.get('label') == 'release' and 'disk1.img' in data['items']]
if not versions:
    sys.exit('No released KVM disk image for selected LTS.')
build, data = max(versions)
item = data['items']['disk1.img']
path = item['path']
if not re.fullmatch(r'[A-Za-z0-9/_.-]+', path) or '..' in path.split('/') or path.startswith('/'):
    sys.exit('Unexpected image path in metadata.')
if not re.fullmatch(r'[0-9a-f]{64}', item['sha256']):
    sys.exit('Invalid SHA256 in metadata.')
print(p['version'], p['release'], build, path, item['sha256'], sep='\n')
PY
{
    read -r RELEASE
    read -r CODENAME
    read -r BUILD
    read -r IMAGE_PATH
    read -r IMAGE_SHA256
} < "$WORK_DIR/selected"
IMAGE_URL="https://cloud-images.ubuntu.com/$IMAGE_PATH"
VM_NAME=${VM_NAME:-ubuntu-${RELEASE//./}-dev-template}
[[ $VM_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ && ${#VM_NAME} -le 63 ]] || fail 'VM_NAME must be a DNS label of at most 63 characters.'
IMAGE="$WORK_DIR/ubuntu.img"
printf 'Building Ubuntu %s LTS (%s): template %s, storage %s, CPU %s\n' "$RELEASE" "$BUILD" "$VMID" "$STORAGE" "$CPU"
fetch "$IMAGE_URL" "$IMAGE"
printf '%s  %s\n' "$IMAGE_SHA256" "$IMAGE" | sha256sum --check --status || fail 'Image checksum mismatch.'
qemu-img info --output=json "$IMAGE" > "$WORK_DIR/image-info.json"
python3 - "$WORK_DIR/image-info.json" "$DISK_GB" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
if info.get('format') != 'qcow2' or info.get('backing-filename'):
    sys.exit('Expected a standalone qcow2 cloud image.')
if info['virtual-size'] > int(sys.argv[2]) * 1024**3:
    sys.exit('DISK_GB is smaller than the cloud image; choose a larger size.')
PY

echo 'Installing guest agent and preparing unique clone identities...'
LIBGUESTFS_BACKEND=direct virt-customize --format qcow2 -a "$IMAGE" \
    --install qemu-guest-agent \
    --run-command 'systemctl enable qemu-guest-agent' \
    --run-command 'cloud-init clean --logs --seed' \
    --run-command 'rm -f /etc/ssh/ssh_host_* /var/lib/dbus/machine-id /var/lib/systemd/random-seed; ln -s /etc/machine-id /var/lib/dbus/machine-id' \
    --truncate /etc/machine-id

# Publish only after download/customization succeeds. Never replace a differing snippet.
install -d -m 0755 "$(dirname -- "$SNIPPET_PATH")"
if [[ ! -e $SNIPPET_PATH && ! -L $SNIPPET_PATH ]]; then
    install -m 0644 "$VENDOR_DATA" "$SNIPPET_PATH"
fi
cmp -s "$VENDOR_DATA" "$SNIPPET_PATH" || fail 'Snippet contents changed during the build.'
qm create "$VMID" --name "$VM_NAME" --ostype l26 \
    --memory "$MEMORY" --cores "$CORES" --cpu "$CPU" \
    --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single \
    --agent enabled=1,fstrim_cloned_disks=1 --serial0 socket --vga serial0
created=1
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMAGE,discard=on,ssd=1"
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm disk resize "$VMID" scsi0 "${DISK_GB}G"
qm set "$VMID" --ciuser "$CI_USER" --sshkeys "$WORK_DIR/keys.pub" \
    --ipconfig0 ip=dhcp --ciupgrade 1 --cicustom "vendor=$SNIPPET_VOL"
qm set "$VMID" --description "JLS Ubuntu $RELEASE LTS; image build $BUILD; source $IMAGE_URL; original SHA256 $IMAGE_SHA256. Developer tools provision on clone first boot."
qm cloudinit update "$VMID"
qm template "$VMID"
printf '\nTemplate %s (%s) is ready. Vendor-data: %s\n' "$VMID" "$VM_NAME" "$SNIPPET_VOL"
echo 'Create a full clone with devbox.sh, then wait inside it: cloud-init status --wait'
echo 'Run jls-doctor after provisioning. Nested virtualization on the host is required for local Docker Sandboxes.'

[Skip to content](https://theramblingtech.com/proxmox-cloud-init-template-guide/#content "Skip to content")

The Rambling Tech · Home Lab

# Proxmox VM Template & Cloud-Init Guide

A clean, step-by-step walkthrough for building a reusable Ubuntu template in Proxmox — clone a fully configured, SSH-ready server in under a minute, no installer, no console, no passwords typed.

We're building the image once and cloning it forever. Instead of mounting an ISO and clicking through the Ubuntu installer every time you need a VM, you'll create a single read-only master image with the guest agent already baked inside it. Cloud-init handles the per-machine setup automatically on first boot — the hostname, your user account, your SSH key, and the network. Clone it, name it, start it, SSH in. Under a minute, every time, identical every time.

#### Watch the build

How to Build a Proxmox Cloud-Init Template (Save Hours) - YouTube

Tap to unmute

[How to Build a Proxmox Cloud-Init Template (Save Hours)](https://www.youtube.com/watch?v=2H7f2ODRA6g) [Rambling Tech](https://www.youtube.com/channel/UCGGnkiCaonoLuteLIhuNjiw)

Rambling Tech1.14K subscribers

[Watch on](https://www.youtube.com/watch?v=2H7f2ODRA6g)

Every command below is on screen in the video, start to finish. Subscribe on [YouTube](https://www.youtube.com/@Ramblingtech) so you don't miss the next build.

## What a Template and Cloud-Init Actually Are

Two separate ideas, and they only get powerful together.

A **template** is a VM you built once and then froze. It's read-only — you can't start it, you can only clone it. Cloning copies the disk, so there's no installer, no partition screens, no fifteen minutes of clicking. You get a running machine in seconds.

On its own that's not quite enough, because every clone comes out identical. Same hostname, same SSH host keys, same machine ID, no user account set up the way you want. You'd still be logging into every clone at the console to fix all that by hand, which eats the time you just saved.

**Cloud-init** closes that gap. It's a small service already baked into official "cloud images" — the builds of Ubuntu, Debian, and Rocky made to run on AWS and similar platforms. On first boot it looks for a config source, applies whatever it finds, then switches itself off so it never runs again.

**Why this matters:** Proxmox supports cloud-init natively. It attaches a tiny virtual CD-ROM holding your settings, and the guest reads it during boot. There's no agent phoning home and nothing clever happening — just a disc with a config file on it.

Everything below runs in the Proxmox host shell as `root`. Get there by clicking your node in the web interface and choosing **Shell**, or by SSH-ing into the host directly.

## 01Check Your Storage Names

List every storage location Proxmox knows about

```
pvesm status
```

You need to know which pool your template's disk will live on before you start, because that name goes into two later commands. A typical single-node setup looks like this:

| Name | Type | What it's for |
| --- | --- | --- |
| `local` | dir | ISOs, snippets, and staging files on the boot drive |
| `local-lvm` | lvmthin | Default VM disk storage created by the installer |
| `vmdata` | zfspool | A ZFS pool on a separate SSD or NVMe — the fast one |

**What to note:** this guide uses `vmdata` throughout. Swap in whatever your fast pool is actually called. If you haven't set up a second pool yet, `local-lvm` works fine.

## 02Install the Image Toolkit

Refresh the package list and install the disk-image tools

```
apt update && apt install -y libguestfs-tools
```

**What this gets you:** the `virt-customize` command, which opens a disk image and modifies what's inside it without ever booting it as a VM. That's how software gets pre-installed into your template instead of installed by hand afterward. It pulls in a fair number of dependencies, so expect a page or two of scrolling.

## 03Download the Ubuntu Cloud Image

Make a staging folder and pull down Ubuntu Server 24.04 LTS

```
mkdir -p /root/images && cd /root/images && wget https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
```

About 600 MB. Three things worth understanding about this file.

**It's a `.img`, not an `.iso`.** There's no installer inside. Ubuntu already installed itself onto that disk back at the factory — which is the entire reason this approach is fast.

**It updates continuously.** Canonical rebuilds this image every few weeks with current patches baked in, so today's copy is already close to fully patched. When you rebuild your template later, you download it again and get a fresher starting point for free.

**It's only a staging file.** You're pulling it into a normal folder on the host, not into a Proxmox storage. Once it's imported in step 06, you can delete it.

## 04Bake In the Guest Agent

Install the guest agent inside the image and clear its machine ID

```
export LIBGUESTFS_BACKEND=direct && virt-customize -a ubuntu-24.04-server-cloudimg-amd64.img --install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent' --truncate /etc/machine-id
```

**What's happening, piece by piece:**

- `LIBGUESTFS_BACKEND=direct` tells the toolkit to boot its internal helper directly instead of going through libvirt, which isn't installed on a Proxmox host. Without this you get an unhelpful error about an appliance failing to start.
- `--install qemu-guest-agent` mounts the image, installs the package inside it, and unmounts. The guest agent is how Proxmox learns a running VM's IP address and how it shuts a VM down gracefully instead of pulling the virtual power cord.
- `--run-command 'systemctl enable qemu-guest-agent'` makes sure the service actually starts at boot rather than just sitting there installed.
- `--truncate /etc/machine-id` blanks the system's unique identifier so every clone generates a fresh one.

**⚠ Don't skip the machine-id line.** If every clone carries the same ID, they all present the same identity to your DHCP server — and it hands them all the same IP address. It's a miserable problem to diagnose and a one-flag problem to prevent.

**What you'll see:** a minute or two of progress output. A warning that a random seed could not be set is normal on Ubuntu cloud images and can be ignored. The four lines that matter are the machine ID, the package install, the service enable, and the truncate.

## 05Create the VM Shell

Create an empty VM with no disk attached yet

```
qm create 9000 --name ubuntu-2404-template --memory 2048 --cores 2 --cpu x86-64-v3 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26 --agent enabled=1
```

This returns silently when it works. Don't try to start the VM — there's nothing on it yet.

**Reading the flags left to right:**

- `9000` is the VM ID. Templates live in the 9000s by convention so they never get confused with real VMs. Your next template becomes 9001.
- `--memory 2048 --cores 2` are just the defaults clones inherit. You override them per clone, so there's no need to agonize.
- `--cpu x86-64-v3` sets a defined CPU feature baseline instead of passing your physical processor straight through.
- `--net0 virtio,bridge=vmbr0` is a paravirtualized network card — the fastest option. Leave it untagged even if you run VLANs; it's cleaner to add the tag per clone than to strip an unwanted one out later.
- `--scsihw virtio-scsi-single` is the current-generation disk controller, and it's required for the TRIM setting in the next step.
- `--ostype l26` tells Proxmox this is a modern Linux guest so it picks sensible defaults.
- `--agent enabled=1` turns on Proxmox's half of the guest agent you installed in step 04. Both halves are needed.

**Why not `--cpu host`:** passing the real CPU through is marginally faster, but it locks the VM to that exact chip. Move it to a different machine later and it can crash on an instruction it wasn't expecting. A baseline like `x86-64-v3` keeps every VM free to move around a cluster. Use `x86-64-v2-AES` instead if you're mixing in older hardware.

## 06Import the Image as a Disk

Convert the downloaded image and attach it as the VM's primary disk

```
qm set 9000 --scsi0 vmdata:0,import-from=/root/images/ubuntu-24.04-server-cloudimg-amd64.img,discard=on,ssd=1
```

You'll see a transfer progress readout as it works.

**What each part does:**`vmdata:0` picks the storage pool, and the zero means "don't specify a size, take it from the image." `import-from=` is the modern one-shot form — older guides use a separate `qm importdisk` command and then attach the resulting unused disk through the web interface, which is the same result with two extra steps. `discard=on` passes TRIM through so blocks freed inside the VM get released back to the pool instead of staying allocated forever. `ssd=1` tells the guest it's on solid state so Linux doesn't schedule pointless spinning-disk optimizations.

**Don't panic at the size.** When it finishes, the disk is only around 3.5 GB. That's the entire Ubuntu install. It grows in step 09.

## 07Add the Cloud-Init Drive

Attach the virtual CD-ROM that carries your settings into the guest

```
qm set 9000 --ide2 vmdata:cloudinit
```

**What this is:** the entire delivery mechanism for cloud-init. Proxmox writes your settings onto this tiny disc as an ISO, and the guest reads them during boot. Nothing clever, nothing over the network. `ide2` is the conventional slot and cloud images expect to find it there.

**Where to see it:** in the web interface, click the VM in the tree on the far left. The column beside the tree is that VM's own menu — Summary, Console, Hardware, and so on. You'll now see a **Cloud-Init** entry sitting between **Hardware** and **Options** that wasn't there a moment ago. Adding this drive is what makes it appear.

## 08Set Boot Order and Serial Console

Boot from the disk, and point the console at a serial port

```
qm set 9000 --boot order=scsi0 --serial0 socket --vga serial0
```

**What each one does:**`--boot order=scsi0` boots from the disk and nothing else, so the VM doesn't try the cloud-init CD-ROM first and hang. `--serial0 socket` adds a virtual serial port to the machine. `--vga serial0` points the Proxmox console at that port instead of at an emulated graphics card.

**⚠ This is the one everybody gets wrong.** Cloud images are built for headless servers in a data center — nothing inside them writes output to a graphical display. Leave the default video setting and you'll open the console, see a completely black screen, and reasonably conclude the VM is broken. It's actually running perfectly and talking to a serial port nobody is listening to. These two flags connect the console to where the output really goes.

## 09Grow the Disk

Add 30 GB to the template's disk

```
qm disk resize 9000 scsi0 +30G
```

This takes it from roughly 3.5 GB up to about 33 GB, and returns silently when it works.

**What's actually happening:** you're only growing the virtual disk. The filesystem inside is still small — but cloud-init expands it automatically on the first boot of every clone, so you never touch it manually.

**Pick a modest number.** This is the default size every clone inherits, and you can always grow a clone further afterward. You cannot shrink one. Anything that needs real capacity should be pointed at network storage rather than given a huge local disk. On a thin-provisioned pool this costs almost nothing today anyway, since the disk only consumes what's actually written to it.

## 10Prepare Your SSH Key

Cloud-init authenticates you by injecting a public key into every clone, so you need a key pair. Where you generate it decides where you'll be able to connect from.

**Generate it on the machine you actually sit at** — your desktop or laptop, not the Proxmox host. Make the key on the host and only the host can reach your VMs, which means hopping through it every single time.

First, check whether you already have a key — PowerShell on Windows

```
ls $env:USERPROFILE\.ssh
```

**Reading the result:** if you see `id_ed25519` and `id_ed25519.pub` in that list, you already have a key pair and don't need to make another one. On Linux or macOS the equivalent is `ls -la ~/.ssh`.

Already have one? Display it — you don't need to remember it, just read it back

```
cat $env:USERPROFILE\.ssh\id_ed25519.pub
```

**What to do next:** copy that single line, **skip the generate step below**, and go straight to pasting it onto the Proxmox host. A key pair doesn't expire and there's no reason to make a second one — the same key can unlock as many servers as you like.

**⚠ Already have a key? Don't generate over it.** If you run `ssh-keygen` and it asks whether to overwrite, answer **n**. Overwriting replaces the pair, and every server that trusts your old public key immediately stops recognising you — including any machine you can now only reach with that key.

Only if you don't have one yet — generate a new key pair

```
ssh-keygen -t ed25519 -C "you@workstation"
```

Press Enter through all three prompts to accept the default location and skip the passphrase.

**What the flags mean:**`-t ed25519` picks the key algorithm — it's the modern one, shorter and stronger than the old RSA default, which is why the result is a single line rather than a seven-line wall. `-C` is just a comment stuck on the end so you can tell your keys apart later; put your machine name in there. It has no effect on how the key works.

Display the public half and copy the single line it outputs

```
cat $env:USERPROFILE\.ssh\id_ed25519.pub
```

**What you're looking at:** one line starting with `ssh-ed25519` and ending with your comment. That's the half that gets handed out. On Linux or macOS the path is `~/.ssh/id_ed25519.pub`.

Back on the Proxmox host, paste that line into a dedicated file

```
nano /root/.ssh/cloudinit_keys.pub
```

Save and exit nano: press **Ctrl+X**, then **Y**, then **Enter**.

**⚠ Public key versus private key.** The file ending in `.pub` is the public key. It's designed to be handed out freely — it goes on every server you want to reach, and millions of people publish theirs openly. The matching file with no extension is the _private_ key and it must never leave the machine that generated it. Anyone who gets that file can log in as you everywhere the public half has been installed.

**Why a dedicated file:** don't reuse the host's existing `authorized_keys`. On Proxmox that's a symlink into the cluster filesystem and it gets managed automatically when nodes join a cluster — not somewhere you want your own keys living. A separate file also lets you add more keys later, one per line, for a laptop or a second workstation.

## 11Set the Cloud-Init Defaults

Set the default user, key, network mode, and first-boot patching

```
qm set 9000 --ciuser youruser --sshkeys /root/.ssh/cloudinit_keys.pub --ipconfig0 ip=dhcp --ciupgrade 1
```

**Fill in the blank:** replace `youruser` with whatever login name you want.

**What each flag sets:**

- `--ciuser` is the account cloud-init creates on every clone. It gets passwordless sudo automatically. Note no password is being set at all — key-only is the cleaner default, and you can add one to an individual clone later if you need console access.
- `--sshkeys` reads that key file _right now_ and stores its contents in the VM's config. This is a snapshot, not a live link — edit the file later to add another key and you have to run this command again.
- `--ipconfig0 ip=dhcp` uses DHCP by default. You can override it per clone with a static address, but DHCP with a reservation on your router is usually the better habit.
- `--ciupgrade 1` runs a package upgrade on first boot. It costs about a minute of boot time and means every VM comes up fully patched instead of however stale the downloaded image happened to be.

**Don't worry about the output.** It echoes your key back with `%20` and `%40` in place of spaces and the at sign. That's just URL encoding inside the config file. The VM receives it decoded correctly.

## 12Convert It to a Template

Freeze the VM into a read-only master image

```
qm template 9000
```

**What changes:** the icon changes in the web interface, the Start button greys out, and from here the only thing you can do with it is clone. That's the point — a golden image you can accidentally boot and modify isn't a reliable baseline.

**It's a one-way conversion.** If you later need a bigger default disk, a newer base image, or another package baked in, the normal move is to delete the template and rebuild it. That sounds heavier than it is — once you've done this twice it's about four minutes of work. Your golden image isn't precious, it's reproducible.

## 13Clone It and Prove It Works

Clone the template and start the new VM

```
qm clone 9000 201 --name test-clone --full && qm start 201
```

**Or do it in the web interface**, which is how you'll normally work: right-click the template, choose **Clone**, set an ID and a name, pick **Full Clone**, and hit the button. Then check the **Cloud-Init** tab if you want to override anything, and start it.

**⚠ Always choose Full Clone.** A full clone copies the whole disk, so the resulting VM is completely independent and can be moved to another node freely. A _linked_ clone is instant and uses almost no space, but it's a thin layer permanently dependent on the template — it can't move anywhere the template doesn't exist, and the template can't be deleted while it lives. Linked clones are great for a dozen throwaway test machines and wrong for anything you intend to keep.

Give it sixty to ninety seconds. Cloud-init is expanding the filesystem, creating your user, installing your key, configuring the network, and applying updates.

Ask the guest agent what IP address it came up on

```
qm guest cmd 201 network-get-interfaces
```

**Easier option:** the VM's **Summary** tab shows the same address far more legibly. Either way, that IP is only visible because of the guest agent you baked in back at step 04.

From your workstation, connect with your key

```
ssh youruser@THE-IP-FROM-ABOVE
```

**Why there's no fixed address here:** the template defaults to DHCP, so that address isn't something you chose — it's whatever your router handed out, and it's the one you just read off the guest agent or the Summary tab. Substitute it along with the username from step 11.

You should land at a shell prompt with no password requested. That's the whole thing working.

### Pinning an address the tidy way

Once a VM is one you intend to keep, set a **DHCP reservation on your router** rather than a static address inside the VM. The machine still boots and asks for an address like normal, but always gets the same one back.

**Why that's better:** every address in your lab stays managed in one place, your router knows the address is taken so it never hands it to something else, and your template's network config never has to change. Set a static inside a VM and your DHCP server has no idea it exists.

## Where This Leads

Once the template exists, building a new server stops being a task and becomes a decision. Need a box for a new service? Clone, name it, start it, SSH in. Under a minute, and every machine comes out identical — same user, same key, same patch level, same configuration.

That consistency is what makes the next layer possible. Ansible works beautifully against cloud-init machines because your key is already present on first boot, so there's no manual bootstrapping to do. And if you ever move toward defining your infrastructure as code, a cloud-init template is the required foundation.

**Same steps, any distribution.** Every distro that publishes cloud images works exactly like this. Change the download URL and everything else is identical.

## Troubleshooting — The Common Snags

These are the issues almost everyone hits. If something's not working, it's probably one of these.

### The console opens to a completely black screen

The VM is running fine — you just aren't looking at where its output goes. Cloud images write to a serial port, not to an emulated graphics card. This is step 08. If you skipped it or ran it after converting to a template, set it on the clone instead:

```
qm set 201 --serial0 socket --vga serial0
```

Then reboot the VM and reopen the console.

### virt-customize fails with an error about the appliance

The toolkit is trying to reach libvirt, which isn't installed on a Proxmox host. You missed the environment variable in step 04. Set it and run the command again:

```
export LIBGUESTFS_BACKEND=direct
```

The variable only lasts for your current shell session, so if you closed the terminal and came back, set it again.

### Every clone comes up on the same IP address

They're all handing your DHCP server the same identity because the machine ID wasn't cleared. That's the `--truncate /etc/machine-id` flag in step 04. The fix on an existing clone is to blank it and regenerate, then reboot:

```
sudo truncate -s 0 /etc/machine-id && sudo systemd-machine-id-setup && sudo reboot
```

Do it properly in the template and this stops happening to every future clone.

### The clone says "storage does not exist" when importing

Your pool isn't called `vmdata`. Every storage name in this guide is an example. Run `pvesm status` and use the name from the first column exactly as it appears — it's case sensitive.

### SSH says "Permission denied (publickey)"

Three usual causes, in the order worth checking. First, the username — it has to match the `--ciuser` you set in step 11, not your Windows username. Second, the key file was empty or had the wrong thing in it when you ran the `qm set` command; `--sshkeys` takes a snapshot at the moment you run it, so fixing the file afterward changes nothing until you run it again. Third, you pasted the private key instead of the public one — the public half is the file ending in `.pub` and starts with `ssh-ed25519`.

Check what the template actually stored:

```
qm config 9000 | grep -E 'ciuser|sshkeys'
```

### Proxmox never shows the VM's IP address

That reading comes from the guest agent, and it needs both halves. Inside the guest the package has to be installed and enabled (step 04), and on the Proxmox side the VM needs `--agent enabled=1` (step 05). Confirm the Proxmox half with `qm config 201 | grep agent`, and the guest half by SSH-ing in and running `systemctl status qemu-guest-agent`.

### The clone's disk is still tiny inside the VM

Proxmox shows 33 GB but `df -h` inside the guest shows a few gigabytes. The virtual disk grew, the filesystem didn't. Cloud-init normally handles this on first boot, so if it didn't run, check `cloud-init status` inside the guest. The likely cause is that you resized the template _after_ converting it, so the clone inherited the old size — in which case resize the clone itself and reboot.

### I changed the Cloud-Init settings and nothing happened

Cloud-init runs once, on the very first boot, then marks itself complete and never runs again. Changing a setting afterward does nothing on its own. Press **Regenerate Image** on the Cloud-Init tab and reboot, and accept that some settings still won't re-apply cleanly. In practice, deleting the clone and cloning again is faster than fighting it. Set what you want _before_ the first start.

### The password I set in Cloud-Init won't work over SSH

Ubuntu cloud images ship with password authentication disabled in the SSH daemon, so a cloud-init password is rejected remotely no matter how many times you retype it. It only works at the console. Key-based access is the intended path, which is what step 10 is for.

**Proxmox VM Template & Cloud-Init Guide · The Rambling Tech**

Replace `vmdata`, `youruser`, and the clone's IP address with your own values.

[Subscribe](https://theramblingtech.com/proxmox-cloud-init-template-guide/#) [Subscribe](https://theramblingtech.com/proxmox-cloud-init-template-guide/#)
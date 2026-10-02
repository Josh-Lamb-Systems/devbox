# JLS persistent Ubuntu developer VM

## What this builds

The attached `jls-ubuntu-dev-vendor-data.yaml` turns a clean Ubuntu 24.04 cloud image into a persistent development runtime with:

- Docker Engine from Docker's official apt repository, Buildx, `docker compose` v2, and Docker Sandboxes (`sbx`);
- Mise with the current Node.js LTS and `uv` selected globally;
- Claude Code on Anthropic's stable native channel;
- Codex from OpenAI's standalone installer;
- Paseo's headless server/CLI, plus GitHub CLI;
- Git, curl, jq, ripgrep, fd, fzf, tmux, build tools, Python/venv, and common diagnostics;
- QEMU guest agent, a small `jls-doctor` check, version recording, and bounded Docker logs.

It deliberately contains no model, GitHub, Paseo, repository, or software-factory credentials.

Research retrieved September 30, 2026.

## Why this is vendor-data

Proxmox generates cloud-init user-data from `ciuser`, `sshkeys`, hostname, and related VM settings. Setting `cicustom user=...` replaces that generated user-data; it does not merge field-by-field. The bootstrap is therefore a custom **vendor-data** snippet. Cloud-init merges user-supplied user-data over vendor-data, preserving the Proxmox identity and network workflow while adding packages and scripts.

The bootstrap discovers the normal `/home` login user at runtime, so it works whether `ciuser` is `josh`, `ubuntu`, or another name. If a guest intentionally has several normal users, run the bootstrap manually with `sudo JLS_DEV_USER=name /usr/local/sbin/jls-bootstrap-dev-vm` or hard-code the intended user in a derived copy.

## Proxmox installation

The commands below run on the Proxmox host. They assume an existing Ubuntu 24.04 cloud-init template with VM ID `9000` and snippet-capable `local` storage.

1. Copy the `jls-ubuntu-dev-vendor-data.yaml` file into snippet storage:

   ```bash
   install -m 0644 jls-ubuntu-dev-vendor-data.yaml \
     /var/lib/vz/snippets/jls-ubuntu-dev-vendor-data.yaml
   ```

   If `local` does not accept snippets, enable the **Snippets** content type for that storage or use another snippet-capable storage shared by the node that will run the VM.

2. Clone and configure a persistent VM. Replace the VM ID, name, SSH-key path, sizing, and network values:

   ```bash
   qm clone 9000 120 --name jls-dev --full 1
   qm set 120 --cores 8 --memory 16384
   qm set 120 --agent enabled=1
   qm disk resize 120 scsi0 100G
   qm set 120 --ciuser josh
   qm set 120 --sshkey /root/.ssh/josh.pub
   qm set 120 --ipconfig0 ip=dhcp
   qm set 120 --cicustom \
     'vendor=local:snippets/jls-ubuntu-dev-vendor-data.yaml'
   qm start 120
   ```

   Use a full clone for this persistent machine. Keep the reusable template unsigned-in and credential-free.

3. Wait for provisioning inside the guest:

   ```bash
   cloud-init status --wait
   sudo tail -n 200 /var/log/jls-dev-bootstrap.log
   jls-doctor
   ```

   First boot performs Ubuntu package upgrades and downloads several tools, so it can take several minutes. If `/var/run/reboot-required` exists, reboot once. If the first SSH session began before group membership was applied, log out and back in before using Docker without `sudo`.

## One-time interactive setup

Run these as the normal login user after cloud-init completes:

```bash
claude
codex login --device-auth
gh auth login
sbx login
paseo
```

- Claude Code handles an unreachable callback in SSH sessions by showing a login code that can be pasted back into the terminal.
- Codex's device-auth flow is designed for headless systems and uses an eligible ChatGPT subscription when that sign-in method is chosen.
- Paseo's native server/CLI is explicitly intended for headless machines and dev boxes. The first `paseo` run starts its daemon and offers an end-to-end encrypted relay with a pairing QR code; direct LAN, Tailscale, or another VPN is also supported.
- Paseo manages locally installed agents rather than bundling them, which is why the image installs Claude Code, Codex, and `gh` before Paseo is paired.

Do not automate these logins in cloud-init or bake their resulting credential files into a template or snapshot.

## Docker Sandboxes

The bootstrap installs `docker-sbx` from Docker's official apt repository and adds the login user to the `kvm` group. Log out and back in after provisioning, then run `sbx login` to authenticate interactively. From a project directory, start an agent with `sbx run claude` or `sbx run codex`.

Local sandboxes require Ubuntu 24.04 or later and accessible KVM hardware virtualization. Because this developer machine is a Proxmox guest, enable nested virtualization on the Proxmox host and expose the host CPU to the guest (`qm set <VMID> --cpu host` on the Proxmox host, with the VM stopped). Verify that `/dev/kvm` exists and that `jls-doctor` reports KVM access. CPU passthrough alone does not enable nested virtualization on the host. Cloud sandboxes can be used without local KVM.

For an existing VM, copy the updated bootstrap from the vendor-data into `/usr/local/sbin/jls-bootstrap-dev-vm` and rerun it. Updating the Proxmox snippet alone does not rerun cloud-init on an already provisioned VM.

## Project dependency pattern

The VM provides host capabilities, not every project's dependencies. Each repository should commit its own runtime and dependency contract:

```text
repo/
  mise.toml + mise.lock
  package.json + pnpm-lock.yaml      # when applicable
  pyproject.toml + uv.lock           # when applicable
  compose.yaml                       # project-specific services
  .env.example                       # names only, never secrets
```

Use a unique Compose project name and named volumes per repository. Shared download caches are fine; do not share mutable `node_modules`, Python virtual environments, or database volumes between projects.

The VM's user belongs to the `docker` group. That is convenient on a trusted personal runtime, but access to the Docker socket is effectively root access. Do not treat a container launched here as the boundary for hostile repositories; use a separate disposable VM/microVM lane for those.

## Updating and rerunning

The script is designed to be rerunnable:

```bash
sudo /usr/local/sbin/jls-bootstrap-dev-vm
```

Mise, Claude Code, Codex, and Paseo resolve to current supported releases when provisioned. The resolved versions are recorded in `/var/lib/jls-dev/versions.txt`. For a stricter production runtime, replace floating channels with tested exact versions and rebuild the template on a schedule.

To troubleshoot cloud-init:

```bash
cloud-init status --long
sudo journalctl -u cloud-final.service
sudo less /var/log/cloud-init-output.log
sudo less /var/log/jls-dev-bootstrap.log
```

## Research notes

A May 2026 Proxmox write-up describes almost the same pattern: a central persistent developer VM for Docker and long-running coding agents, bootstrapped with cloud-init and completed with interactive secret/agent login. Its author moved from the Telmate Terraform provider to BPG's Proxmox provider after cloud-init trouble and kept credentials outside initial provisioning. This supports the overall direction, although this implementation uses Mise instead of Linuxbrew and avoids SSH-agent forwarding by default.

Other current implementations reinforce the same layers:

- `katspaugh/machine` creates one Lima VM per GitHub project and preloads Docker, Node, Claude Code, Codex, and GitHub CLI.
- Gajus Kuizinas' agent-environment write-up uses cloud-init to make repeatable VMs and installs Claude Code after boot, but copies a long-lived OAuth token into each machine. That is appropriate only for trusted workers; this persistent-personal design keeps login interactive.
- Docker/cloud-init guides consistently recommend validating the YAML, using Docker's apt repository rather than the convenience script, waiting for `cloud-init status`, and checking cloud-init logs rather than assuming SSH readiness means provisioning is complete.

## Sources

- [Proxmox Cloud-Init support](https://pve.proxmox.com/wiki/Cloud-Init_Support)
- [cloud-init module reference](https://cloudinit.readthedocs.io/en/latest/reference/modules.html)
- [Docker Sandboxes installation](https://docs.docker.com/ai/sandboxes/install/)
- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Mise installation](https://mise.jdx.dev/installing-mise.html)
- [Claude Code setup](https://code.claude.com/docs/en/setup)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Codex CLI](https://developers.openai.com/codex/cli)
- [Codex authentication](https://developers.openai.com/codex/auth)
- [Paseo getting started](https://paseo.sh/docs)
- [Moving Development to the Cloud: The AI-First Home Server](https://hussainweb.me/blog/moving-dev-to-proxmox-ai-agents/)
- [`katspaugh/machine`](https://github.com/katspaugh/machine)
- [Isolated Development Environments for Agentic Development](https://gajus.com/blog/isolated-development-environments-for-agentic-development)
- [Docker Installation and Deployment with Cloud-Init](https://virtarix.com/blog/technical-guides/docker-installation-deployment-cloud-init/)

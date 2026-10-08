# JLS persistent Ubuntu developer VM

## What this builds

The attached `jls-ubuntu-dev-vendor-data.yaml` provisions an Ubuntu cloud image as a persistent development runtime with:

- Docker Engine from Docker's official apt repository, Buildx, `docker compose` v2, and Docker Sandboxes (`sbx`);
- Mise with the current Node.js LTS, `uv`, Go, stable Rust/Cargo, and Python 3.14 selected globally;
- Claude Code on Anthropic's stable native channel;
- Codex from OpenAI's standalone installer;
- Pi from its official installer (a managed install that updates with `pi update`);
- Paseo's headless server/CLI, plus GitHub CLI;
- Git/LFS, curl, jq, ripgrep, fd, fzf, tmux, CMake/Ninja, SQLite CLI/development headers, system Python/venv/development headers, and common diagnostics;
- QEMU guest agent, a small `jls-doctor` check, version recording, and bounded Docker logs.

It deliberately contains no model, GitHub, Paseo, repository, or software-factory credentials.

Research retrieved September 30, 2026.

## Why this is vendor-data

Proxmox generates cloud-init user-data from `ciuser`, `sshkeys`, hostname, and related VM settings. Setting `cicustom user=...` replaces that generated user-data; it does not merge field-by-field. The bootstrap is therefore a custom **vendor-data** snippet. Cloud-init merges user-supplied user-data over vendor-data, preserving the Proxmox identity and network workflow while adding packages and scripts.

The bootstrap discovers the normal `/home` login user at runtime, so it works whether `ciuser` is `josh`, `ubuntu`, or another name. If a guest intentionally has several normal users, run the bootstrap manually with `sudo JLS_DEV_USER=name /usr/local/sbin/jls-bootstrap-dev-vm` or hard-code the intended user in a derived copy.

### Other platforms

The vendor-data file is plain cloud-config and also works on other Ubuntu cloud-init platforms (for example AWS, GCP, Azure, Hetzner, Multipass, or LXD VMs). Those platforms usually accept only user-data, so supply it as user-data and rely on the image's default login user or add your own `users:` entry. The QEMU guest agent is installed everywhere but only started, and only checked by `jls-doctor`, when the hypervisor exposes its virtio channel.

## Build the template

`qmtemplatemaker.sh` downloads the latest **supported, released Ubuntu Server LTS
amd64 cloud image** using [Canonical's release metadata](https://cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json).
At verification on October 2, 2026, this selected Ubuntu 26.04 LTS. It uses a dated
image URL and checks its SHA-256 against metadata retrieved over HTTPS before
customizing the image. This is checksum verification, not detached-signature verification.

Copy `qmtemplatemaker.sh`, `devbox.sh`, and `jls-ubuntu-dev-vendor-data.yaml` into
the same directory on your **Proxmox host**, then run as root:

```bash
apt-get update
apt-get install -y libguestfs-tools curl python3 openssh-client
pvesm status
bash qmtemplatemaker.sh
```

Defaults match the original host configuration: VM ID **9000**, disk storage
**live**, snippet storage **local**, bridge **vmbr0**, user **josh**, public key
**/root/.ssh/macbook.pub**, 4 cores, 4096 MiB memory, and a 32 GiB disk. The SSH
public key must already be on the host. Enable **Snippets** under Datacenter →
Storage → local → Edit first; the script checks storage availability and content
support and does not change your storage configuration.

Override settings through environment variables; `--help` lists all options:

```bash
STORAGE=local-lvm SSH_KEY=/root/.ssh/laptop.pub bash qmtemplatemaker.sh
# Optional: select a supported older LTS and a separate template ID.
VMID=9001 UBUNTU_RELEASE=24.04 bash qmtemplatemaker.sh
```

Following the attached blog's approach, the builder installs and enables the
QEMU guest agent offline with `virt-customize`, clears cloud-init state, SSH host
keys and machine identity, enables TRIM and the serial console, grows the disk,
and converts the VM directly to a template without booting it. The vendor-data
file is copied unchanged into snippet storage and attached with `cicustom vendor=`;
Proxmox still generates the user, SSH keys and network configuration. Developer
tools install on **each clone's first boot**, so creating the template does not
prove that every package or upstream installer supports the newly selected LTS.

`CPU=host` is intentional for nested KVM/Docker Sandboxes. Enable nested
virtualization separately on the host. If migration between unlike CPUs matters
more, choose a suitable baseline such as `CPU=x86-64-v3`; local nested KVM may
then be unavailable. The script does not change host virtualization settings.

The host needs outbound HTTPS, and the libguestfs appliance needs network/DNS
access to Ubuntu package mirrors. Allow several GB of temporary space under
`/var/tmp` (override with `WORK_ROOT`). Temporary downloads are removed on exit.
Existing VM/container IDs are rejected cluster-wide. A partial VM is retained
on failure for inspection; resolve the cause and manually remove that partial
VM or choose a new ID before retrying.

An existing snippet is reused only when its bytes match. To change the bootstrap
without affecting other VMs, use a new `SNIPPET_NAME`, for example
`SNIPPET_NAME=jls-ubuntu-dev-v2.yaml`. Snippets must remain available to every
node that runs the clones, even when using full clones. Use shared snippet
storage or copy identical snippets to the destination nodes.

Then run `bash devbox.sh` on the host to create and start a full clone. It
inherits the template's vendor-data reference. If you changed template ID,
login user, or key path, update the constants at the top of `devbox.sh` as well.
Its default clone disk is 100 GiB, which must be at least the template disk size.
After first boot, use the provisioning checks below before authenticating tools.

Local verification: `bash -n qmtemplatemaker.sh devbox.sh` and
`python3 -m unittest discover -s tests -v`. The tests mock Proxmox, downloads,
and libguestfs; a real template build and clone boot must be verified on Proxmox.

## Proxmox installation with an existing template

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
jls-run claude
jls-run codex login --device-auth
jls-run pi
gh auth login
sbx login
jls-run paseo
```

- Claude Code handles an unreachable callback in SSH sessions by showing a login code that can be pasted back into the terminal.
- Codex's device-auth flow is designed for headless systems and uses an eligible ChatGPT subscription when that sign-in method is chosen.
- Pi supports subscription and API-key providers; run `/login` inside Pi to choose one. Credentials are stored in `~/.pi/agent/auth.json`.
- Paseo's native server/CLI is explicitly intended for headless machines and dev boxes. The first `paseo` run starts its daemon and offers an end-to-end encrypted relay with a pairing QR code; direct LAN, Tailscale, or another VPN is also supported.
- Paseo manages locally installed agents rather than bundling them, which is why the image installs Claude Code, Codex, Pi, and `gh` before Paseo is paired.

Do not automate these logins in cloud-init or bake their resulting credential files into a template or snapshot.

## Docker Sandboxes

The bootstrap installs `docker-sbx` from Docker's official apt repository and adds the login user to the `kvm` group. Log out and back in after provisioning, then run `sbx login` to authenticate interactively. From a project directory, start an agent with `sbx run claude` or `sbx run codex`.

Local sandboxes require Ubuntu 24.04 or later and accessible KVM hardware virtualization. Because this developer machine is a Proxmox guest, enable nested virtualization on the Proxmox host and expose the host CPU to the guest (`qm set <VMID> --cpu host` on the Proxmox host, with the VM stopped). Verify that `/dev/kvm` exists and that `jls-doctor` reports KVM access. CPU passthrough alone does not enable nested virtualization on the host. Cloud sandboxes can be used without local KVM.

For an existing VM, updating the Proxmox snippet alone does not rerun cloud-init.
This revision also adds supporting files: install the updated `jls-doctor`,
`jls-run`, `/usr/local/share/jls-dev/agent-context.md`, and
`/usr/local/lib/jls-dev/install-agent-context` from the YAML's `write_files`
alongside the updated `/usr/local/sbin/jls-bootstrap-dev-vm`, using the declared
owners and permissions, before rerunning the bootstrap. New clones receive
all these files automatically.
The maintenance revision also needs `/etc/apt/apt.conf.d/99-jls-security-updates`,
`/etc/systemd/journald.conf.d/99-jls-limits.conf`, and
`/etc/logrotate.d/jls-dev-bootstrap` from `write_files` before rerunning on an
existing VM. The bootstrap installs their required packages and enables timers.

## Agent awareness and headless launches

The bootstrap adds a managed environment guide to the discovered user's
`~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, and `~/.pi/agent/AGENTS.md`. An
existing Codex `AGENTS.override.md` also receives the guide because it takes
precedence over `AGENTS.md`. Pi loads only the first of `AGENTS.override.md`,
`AGENTS.md`, or `CLAUDE.md` in its agent directory, so the guide goes into
whichever of those already exists. Existing personal text, file permissions, and symlinks are preserved;
reruns replace only the block between the JLS markers. Malformed or duplicate
markers stop the update instead of guessing which text to replace.

The common source is `/usr/local/share/jls-dev/agent-context.md`. It describes
installed tools, mise runtime management, project isolation, troubleshooting,
and the distinction between installed and authenticated CLIs. It keeps machine
details out of repository instructions. Start a new agent session after updates.
For a separate Codex or Pi profile, run as the login user:

```bash
CODEX_HOME=/path/to/profile /usr/local/lib/jls-dev/install-agent-context
PI_CODING_AGENT_DIR=/path/to/agent-dir /usr/local/lib/jls-dev/install-agent-context
```

Use the launcher for direct or headless execution, as the normal login user:

```bash
jls-run codex
jls-run claude
jls-run pi
jls-run paseo
jls-run jls-doctor --json
```

`jls-run` explicitly prepends the user's local binaries, mise shims, and standard
system binary directories to PATH, then executes the command with its arguments
unchanged. It does not depend on `.bashrc`, start a login shell, change directory,
or inject a prompt. For a service, set the correct user and HOME and use an
absolute launcher path in its command, for example
`/usr/local/bin/jls-run <your-existing-agent-command>`. Restart an already running
launcher/service to pick up the new environment and group memberships. Installing
this file does not modify or restart existing Paseo or other services.

`jls-doctor --json` emits one JSON report and exits **0** when ready or **1** when
readiness checks fail; failure reports are still valid JSON. Maintenance warnings
appear separately in `warnings` and do not alone change the exit code. It checks current executable
paths and versions (including uv), Docker Compose/Buildx, Docker daemon access,
guest-agent and Docker services, provisioning completion, KVM access, and reboot
status. Each subprocess has a five-second timeout. Missing optional KVM access
and a pending reboot are reported but do not themselves fail the readiness check.
Authentication is not checked. `/var/lib/jls-dev/versions.txt` remains the
provisioning-time record rather than the source of live versions.

Run diagnostics as the agent user in its actual execution environment. Running
`jls-doctor` directly inspects the inherited PATH; running it through `jls-run`
checks the launcher's PATH. Root's Docker/KVM access does not prove user access,
and tools installed on the devbox are not necessarily available in a container
or sandbox. No automatic startup hook is installed: the short instruction block
directs agents to run diagnostics when needed.

## Security updates, log retention, and storage

The bootstrap ensures `unattended-upgrades`, `python3-apt`, and `logrotate` are
installed. It configures daily APT package-list refreshes and unattended upgrades,
explicitly disables automatic reboots, and enables `apt-daily.timer`,
`apt-daily-upgrade.timer`, and `logrotate.timer`. Ubuntu's existing allowed-origin
configuration is preserved. Third-party repositories and mise runtimes are not
automatically covered by this Ubuntu security-update policy.

`jls-doctor` reads effective APT configuration through Ubuntu's `apt_pkg` and checks
that a security origin is listed, daily jobs are configured, the update timers
are enabled/active, and automatic reboot is disabled. Drift or an unreadable
configuration produces a maintenance warning. This verifies configuration, not
successful installation of the latest security updates. For a deeper check on
the guest, inspect `journalctl -u apt-daily-upgrade.service` and
`/var/log/unattended-upgrades/`, or run
`sudo unattended-upgrade --dry-run --debug`.

Journald is configured for **512 MiB** of persistent journal usage, **128 MiB**
of runtime journal usage, **14 days** of retention, and free-space reserves of
1 GiB on disk and 64 MiB in runtime storage. Existing persistence behavior is
preserved. These are journald retention targets; active journal files and other
logs mean they are not a strict cap on all of `/var/log`.

The bootstrap log rotates daily, with a **10 MiB** size trigger at rotation checks
and **seven archives**, using compression and `copytruncate` so an ongoing
bootstrap can keep writing. Size is checked when logrotate runs, so the active
file can exceed 10 MiB between daily checks. `copytruncate` has a small window
in which concurrent log lines may be lost. Existing Docker log limits remain in
place. The bootstrap parses the rotation configuration with `logrotate --debug`
before declaring completion; it does not force a rotation.

Storage diagnostics inspect `/`, the calling user's home, `/var/log`, and Docker's
reported data directory. If Docker cannot report its path, the report explicitly
marks `/var/lib/docker` as an unverified fallback. Absent paths use their nearest
existing parent; permission failures are reported as unknown. Multiple paths
may refer to the same filesystem and their capacity must not be added together.

- **Warning:** less than 5 GiB available, 10% of disk capacity available, or 10%
  of inodes available.
- **Critical / readiness failure:** less than 1 GiB available, 2% of disk capacity
  available, or 2% of inodes available.
- Filesystems without a fixed inode count report inode percentage as unknown.

Diagnostics do not delete data, prune containers/volumes, or run upgrades.

## Language runtimes and Python isolation

The bootstrap selects global defaults through mise:

```bash
mise use --global node@lts uv@latest go@latest rust@latest python@3.14
```

These are user-owned development runtimes. Project `mise.toml` files can override
those defaults; commit project pins and lockfiles for reproducibility.

| Runtime | Default policy | Support meaning |
|---|---|---|
| Node.js | `node@lts` | Upstream LTS channel |
| Python | `python@3.14` | Latest available patch in the 3.14 series; upstream security support scheduled through October 2030 |
| Go | `go@latest` | Latest stable at provisioning; upstream supports its two newest major release lines |
| Rust | `rust@latest` | Latest stable at provisioning; upstream uses a six-week stable release cycle |

Python, Go, and Rust do **not** have upstream LTS channels equivalent to Node or
Ubuntu. These defaults favor supported stable releases without inventing `lts`
aliases. Python will not automatically jump to 3.15. Go and Rust may advance
release lines on a new provisioning run. Already provisioned VMs need deliberate
runtime upgrades; Ubuntu apt upgrades do not update mise-managed installations.
Review pins before their support windows expire. Support policies checked
October 2, 2026: [Python](https://devguide.python.org/versions/),
[Go](https://go.dev/doc/devel/release#policy), and
[Rust](https://doc.rust-lang.org/book/appendix-07-nightly-rust.html).

Mise's Rust backend manages rustup under the hood; no independent apt Rust
toolchain or rustup installer is added. Use mise shims or `mise exec -- cargo build`.
For existing `rust-toolchain.toml` projects, enable mise's Rust idiomatic-file
discovery rather than adding a conflicting version pin.

Ubuntu still maintains `python3`, `python3-pip`, `python3-venv`, and `python3-dev`.
`/usr/bin/python3` stays untouched and runs the JLS diagnostic and instruction
installer scripts. `python3-dev` supplies headers for Ubuntu's interpreter only.
The separate mise Python is selected through user PATH/mise execution. Diagnostics
and `versions.txt` report both system and development interpreters separately.

**Mise chooses Python; uv manages the project environment and dependencies.** For
a new project (choose a version matching its requirements):

```bash
mise use python@3.14
uv venv --python "$(mise which python)" --no-python-downloads
```

For an existing uv project:

```bash
mise install
uv sync --python "$(mise which python)" --no-python-downloads
uv run --python "$(mise which python)" --no-python-downloads python --version
```

Honor `requires-python` and the lockfile. For repositories using only
`.python-version`, enable mise Python idiomatic-file discovery or add a matching
mise project pin; do not silently fall back to the global version. Stop and resolve
incompatible pins before recreating an existing environment.

Do not use `uv python install` or `--managed-python` for this workflow: those
select uv-owned interpreters. Passing the explicit mise interpreter avoids
ambiguity, and `--no-python-downloads` prevents uv from downloading a second one.
Keep dependencies in `.venv`; do not use `sudo pip`, `--break-system-packages`, or
replace `/usr/bin/python3`. See [mise Python](https://mise.jdx.dev/lang/python.html)
and [uv interpreter selection](https://docs.astral.sh/uv/concepts/python-versions/).

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

Mise, Claude Code, Codex, Pi, and Paseo resolve to current supported releases when provisioned. The resolved versions are recorded in `/var/lib/jls-dev/versions.txt`. For a stricter production runtime, replace floating channels with tested exact versions and rebuild the template on a schedule.

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
- [Pi](https://pi.dev) ([source](https://github.com/earendil-works/pi))
- [Paseo getting started](https://paseo.sh/docs)
- [Moving Development to the Cloud: The AI-First Home Server](https://hussainweb.me/blog/moving-dev-to-proxmox-ai-agents/)
- [`katspaugh/machine`](https://github.com/katspaugh/machine)
- [Isolated Development Environments for Agentic Development](https://gajus.com/blog/isolated-development-environments-for-agentic-development)
- [Docker Installation and Deployment with Cloud-Init](https://virtarix.com/blog/technical-guides/docker-installation-deployment-cloud-init/)

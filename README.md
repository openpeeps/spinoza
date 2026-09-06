<p align="center">
  <img src="https://github.com/openpeeps/spinoza/blob/main/.github/spinoza-logo.png" width="120px"><br>
  Spinoza – Spin up Virtual Machines like a PRO<br>
  A super lightweight alternative to Vagrant, VMWare or VirtualBox
</p>

<p align="center">
  <code>nimble install spinoza</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/spinoza">API reference</a><br>
  <img src="https://github.com/openpeeps/spinoza/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/spinoza/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About

Spinoza is a lightweight, fast VM manager written in [Nim](https://nim-lang.org). It manages virtual machines using **libvirt** and **QEMU**, with built-in SSH connectivity powered by **libssh2**. Define your VMs in a simple `Spinozafile` and spin them up with a single command.

Inspired by Vagrant, but without the Ruby overhead. Spinoza talks directly to libvirt, no intermediary layers, no heavy dependencies. It works with any qcow2 box image compatible with libvirt (including Vagrant boxes for the libvirt provider).

> [!NOTE]
> Spinoza is still in progress. Core VM lifecycle (up, halt, reload, destroy, suspend, resume), SSH, and box management are working. Some features like KVM auto-detection and NAT networking via virtnetworkd are not yet available on all platforms.

## Key Features
- Super fast and easy to use
- **Single-file configuration** `Spinozafile` in YAML defines your VM specs
- **Libvirt + QEMU backend** direct integration with the virtualization stack
- **Built-in SSH** interactive shell sessions via libssh2, no external `ssh` or `expect` needed
- **VM registry** named VMs stored in a local boogie KV store
- **Full VM lifecycle** boot, halt, reload, destroy, suspend, and resume
- **Box management** download, list, and remove qcow2 box images (local files and URLs)
- **Shared folders** mount host directories inside the VM via virtiofs (Linux) or 9p (macOS)
- **Memory validation** enforces minimum 1 GB, checks against host RAM, warns at 70% usage
- **QEMU TCG fallback** auto-generated wrapper on macOS when hardware acceleration is unavailable
- **Pluggable networking** SLIRP with dynamic forwarded ports, or true per-VM `192.168.x.x` IPs via libvirt NAT/isolated networks (Linux: `spz-shared`/`spz-host` on `qemu:///system`) or [socket_vmnet](https://github.com/lima-vm/socket_vmnet) on macOS
- **Live console logs** `spinoza logs` streams guest boot output from a file-backed serial console

### Prerequisites

You will need **Nim >= 2.2.10** and a few system libraries.

#### Linux (Debian/Ubuntu)

```bash
# Compile-time dependencies
sudo apt-get update
sudo apt-get install -y \
  libvirt-dev \
  libssh2-1-dev \
  libssl-dev \
  qemu-system-x86 \
  pkg-config

# Runtime: libvirtd, dnsmasq (for NAT/DHCP), and iproute2
sudo apt-get install -y libvirt-daemon-system dnsmasq-base net-tools

# Enable the libvirt daemon (socket activation is also sufficient)
sudo systemctl enable --now libvirtd

# Allow your user to manage system VMs/networks via qemu:///system
sudo usermod -aG libvirt $(whoami)
# IMPORTANT: log out completely and back in (or reboot) so the new
# supplementary group is visible in `id`. `groups` alone is not enough —
# `id` must show `libvirt` before spinoza `shared`/`host` will work.

# Bridged modes (shared/host) run via `qemu:///system`. Spinoza injects
# `<seclabel type='dynamic' model='dac' relabel='yes'>` with `+uid:+gid`
# so QEMU runs as your user and `~/.spinoza/boxes/*.img` is auto-relabeled
# — no manual `chmod` needed. System pool `/var/lib/libvirt/images` also works.
```

> [!NOTE]
> If `qemu:///system` still returns `Permission denied` on the libvirt socket,
> add a polkit rule (no groups needed) as a fallback:
> ```bash
> sudo tee /etc/polkit-1/rules.d/49-libvirt.rules >/dev/null <<'EOF'
> polkit.addRule(function(action, subject) {
>   if (action.id == "org.libvirt.unix.manage" && subject.user == "YOUR_USER") {
>     return polkit.Result.YES;
>   }
> });
> EOF
> ```
> Replace `YOUR_USER` with `$(whoami)`. After creating the rule, `virsh -c qemu:///system list` should succeed without being in `libvirt`.

#### macOS

Install via [Homebrew](https://brew.sh) or [MacPorts](https://www.macports.org):

```bash
# Homebrew
brew install libvirt libssh2

# MacPorts
sudo port install libvirt libssh2
```

QEMU is bundled with Spinoza on macOS via a TCG wrapper when KVM is unavailable.

> [!NOTE]
> Browse available boxes on [HashiCorp Cloud](https://portal.cloud.hashicorp.com). For example, [Generic Boxes](https://portal.cloud.hashicorp.com/vagrant/discover/generic) with libvirt support work seamlessly with Spinoza.

## Quick Start

**1. Initialize a Spinozafile**

```bash
spinoza init
```

This will interactively prompt for box name, VM name, memory, CPUs, SSH settings, and optional shared folders.

**2. Add a box image**

```bash
spinoza box add https://example.com/debian-11.qcow2
spinoza box add /path/to/local/debian-11.img
```

**3. Boot the VM**

```bash
spinoza up
```

**4. SSH into the VM**

```bash
spinoza ssh
```

**5. Mount shared folders (inside guest)**

```bash
# If shared_folders are configured in Spinozafile:
# Linux (virtiofs):
sudo mount -t virtiofs <tag> /mnt/<tag>
# macOS (9p):
sudo mount -t 9p -o trans=virtio <tag> /mnt/<tag>
```

**6. Shut down**

```bash
spinoza halt
```

## Spinozafile Format

```yaml
box: debian-11                # Name of the qcow2 box image
name: spinoza-debian          # Unique VM identifier
memory: 2048                  # RAM in megabytes (min 1024)
cpus: 2                       # Number of virtual CPUs
network:
  mode: user                  # user | shared | host (see Networking)
ssh_config:
  user: vagrant               # SSH username
  password: vagrant           # SSH password
shared_folders:               # Optional: mount host dirs
  - host: /Users/<username>/code    # Host directory path
    tag: code                       # Mount tag used in guest
  - host: /Users/<username>/data
    tag: data
provision:                    # Optional: shell commands run over SSH, in order
  - sudo apt-get update
  - sudo apt-get install -y nginx
provision_script:             # Optional: local scripts piped to remote `bash -s`
  - ./scripts/bootstrap.sh    # Paths resolve relative to the Spinozafile
```

Box images are stored in `~/.spinoza/boxes/`. VM state is tracked in `~/.spinoza/vms/`. Console logs are written to `~/.spinoza/logs/<name>.log`.

## Provisioning

Provisioners run inside the guest over SSH. All `provision:` commands execute first (in order), then every `provision_script:` file is piped to `bash -s` on the guest.

```bash
spinoza up --provision        # boot, then provision
spinoza reload --provision    # restart with the current Spinozafile, then provision
spinoza provision             # re-run provisioners on an already-running VM
```

Output streams live as each step runs. Provisioning stops at the first failing command and reports its exit code; the VM itself stays up. Running without a configured `provision:` section is a no-op.

## Networking

Spinoza supports three network modes via `network.mode` in the Spinozafile:

| Mode | Guest IP | Internet (guest) | Host → guest access | Requires |
|---|---|---|---|---|
| `user` (default) | `127.0.0.1` + auto-allocated forwarded port | Yes | Yes (forwarded port) | Nothing, works everywhere |
| `shared` | Real DHCP'd IP (e.g. `192.168.124.x` Linux / `192.168.105.x` macOS) | Yes | Yes, direct IP | Linux: libvirtd + `qemu:///system` / macOS: socket_vmnet daemon |
| `host` | Real DHCP'd IP on isolated bridge (`192.168.125.x` Linux / `192.168.122.x` macOS) | No | Yes, direct IP | Linux: libvirtd + `qemu:///system` / macOS: socket_vmnet daemon |

With `user` mode there is never a port conflict: at boot Spinoza asks the kernel for a free TCP port and forwards it to guest SSH. The endpoint is stored per VM, so `spinoza ssh` just works.

With the vmnet modes every VM gets a genuine routable IP on your macOS host — the same model as VirtualBox host-only / Vagrant private networks.

### macOS setup: socket_vmnet

The `shared` and `host` modes use Apple's `vmnet` framework through [socket_vmnet](https://github.com/lima-vm/socket_vmnet), which is packaged by MacPorts. One-time setup:

```bash
# 1. Install
sudo port selfupdate
sudo port install socket_vmnet

# 2. Start the shared-mode daemon (internet-enabled network)
sudo port load socket_vmnet

# 3. Verify it's listening
ls -l /opt/local/var/run/socket_vmnet
```

MacPorts installs under `/opt/local`: binaries in `/opt/local/bin`, socket at `/opt/local/var/run/socket_vmnet` (gateway `192.168.105.1`, log at `/opt/local/var/log/socket_vmnet.log`). Spinoza detects the MacPorts layout automatically; upstream or Homebrew installs using `/var/run/socket_vmnet` work too, or set `network.socket_path` explicitly. To stop the daemon: `sudo port unload socket_vmnet`.

**Host-only mode (pinned subnet):** create a second daemon instance on a fixed subnet by installing a plist like this as `/Library/LaunchDaemons/io.spinoza.socket-vmnet-host.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.spinoza.socket-vmnet-host</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/local/bin/socket_vmnet</string>
    <string>--vmnet-mode=host</string>
    <string>--vmnet-gateway=192.168.122.1</string>
    <string>/opt/local/var/run/socket_vmnet-host</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>Sockets</key>
  <dict>
    <key>Listeners</key>
    <dict>
      <key>SockPathMode</key><integer>448</integer>
      <key>SockPathName</key><string>/opt/local/var/run/socket_vmnet-host</string>
      <key>SockType</key><string>stream</string>
    </dict>
  </dict>
</dict>
</plist>
```

```bash
sudo mkdir -p /var/run
sudo chown root:daemon /var/run
sudo launchctl bootstrap system /Library/LaunchDaemons/io.spinoza.socket-vmnet-host.plist
sudo launchctl enable system/io.spinoza.socket-vmnet-host
sudo launchctl kickstart -kp system/io.spinoza.socket-vmnet-host
```

**Static IPs:** each VM derives a deterministic MAC from its UUID (prefix `52:54:00`). To pin an IP, add a reservation to `/etc/bootptab` (keep the `%%` header):

```
%%
# hostname      hwtype  hwaddr              ipaddr
spinoza-debian  1       52:54:00:xx:yy:zz   192.168.122.10
```

then reload DHCP: `sudo /bin/launchctl kickstart -kp system/com.apple.bootpd`.

Spinoza discovers each VM's IP automatically after boot by matching its MAC in the host ARP table; with a bootptab reservation you get the same address on every boot.

**Troubleshooting:** if guests never get an IP, make sure `bootpd` isn't blocked by the application firewall:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/bootpd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock /usr/libexec/bootpd
```

Daemon-side debug output goes to `/opt/local/var/log/socket_vmnet.log` (MacPorts) or `/var/log/socket_vmnet/stderr` (upstream/Homebrew launchd).

### Linux networking: shared and host modes

On Linux, `shared` and `host` are implemented natively via libvirt virtual networks — the same `192.168.x.x` per-VM IP model as on macOS, without `socket_vmnet`.

- `shared` → NAT network `spinoza-192.168.124` on bridge `spz-shared` (`192.168.124.1/24`, DHCP `192.168.124.100-200`, `<forward mode='nat'/>`). Guest has internet, host reaches guest by IP.
- `host` → isolated bridge `spz-host` (`192.168.125.1/24`, DHCP `192.168.125.100-200`, no `<forward>`). Guest ↔ host only, no internet.

Both modes use `qemu:///system` (system libvirtd) and are discovered via `ip neigh` matched against the deterministic MAC `52:54:00:xx:yy:zz` derived from the VM UUID. A single shared bridge is reused for all VMs of the same mode (verified: `spz-shared` / `spz-host`, `virsh -c qemu:///system net-list`).

**One-time setup** is the prerequisites above (group + relogin — no `chmod` needed, DAC seclabel handles it). Verify with:
```bash
id | grep -q libvirt || echo "re-login needed"
virsh -c qemu:///system net-list --all   # should list spinoza-192.168.124 when active
ip addr show spz-shared                  # 192.168.124.1/24
virsh -c qemu:///system net-dhcp-leases spinoza-192.168.124
ip neigh | grep 192.168.124
```

**Troubleshooting:**

- `Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied` — `id` doesn't show `libvirt` after `usermod`; do a full logout (or `loginctl terminate-user $USER` / reboot) or create the polkit rule above. `sg`/`newgrp` are not installed in this base image.
- `Cannot access storage file '.../boxes/*.img' (as uid:64055, gid:991): Permission denied` — seclabel not applied (old libvirt or `qemu:///session` misconfig). Spinoza on Linux `shared`/`host` injects DAC `seclabel +uid:+gid` so QEMU runs as you and the image is relabeled. Fallback: `chmod 711 $HOME && chmod 644 ~/.spinoza/boxes/*.img` or move image to `/var/lib/libvirt/images`.
- `error creating bridge interface ...: Numerical result out of range` — bridge names are capped at 15 chars (`IFNAMSIZ`); Spinoza uses `spz-shared` / `spz-host`.
- Guest never gets an IP — ensure `dnsmasq-base` is installed, the default libvirt network `default` is not conflicting on `192.168.124.0/24`, and `spz-shared` exists. Check `journalctl -u libvirtd` and `virsh -c qemu:///system net-dumpxml spinoza-192.168.124`.

### Live console logs

Every VM writes its serial console to `~/.spinoza/logs/<name>.log`. Stream it live (Ctrl-C to stop watching; the log file itself keeps growing):

```bash
spinoza logs            # VM from Spinozafile
spinoza logs my-vm      # named VM from registry
```

> [!NOTE]
> Console output only appears if the guest OS writes to its first serial port (`ttyS0`). Most cloud/Vagrant images do; stock installs may need it enabled once. For Debian/Ubuntu guests:
>
> ```bash
> spinoza ssh
> sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0"/' /etc/default/grub
> sudo update-grub
> exit
> spinoza halt && spinoza up
> ```
>
> From then on, kernel and init output streams live into `spinoza logs` and into the `spinoza up` boot view.

## libvirt XML API

Spinoza uses a typed object model for building libvirt domain XML. Instead of DSL macros, you work with plain Nim objects and call `toXML()` to render:

```nim
import libvirt

var domain = LibvirtDomain(
  virtType: "qemu",
  metadata: LibvirtMetadata(name: "my-vm"),
  memory: LibvirtMemory(value: "2048", unit: "MiB"),
  currentMemory: LibvirtMemory(value: "2048", unit: "MiB"),
  vcpu: LibvirtVcpu(value: "2", placement: "static"),
  os: LibvirtOS(
    osType: "hvm",
    arch: "x86_64",
    machine: "pc",
    boot: @[bdHardDisk]
  ),
  clock: LibvirtClock(offset: "utc"),
  events: LibvirtEvents(
    onPoweroff: oaDestroy,
    onReboot: oaRestart,
    onCrash: oaDestroy
  ),
  emulator: "/usr/bin/qemu-system-x86_64",
  disks: @[LibvirtDisk(
    diskType: "file",
    device: "disk",
    driverName: "qemu",
    driverType: "qcow2",
    sourceFile: "/path/to/box.img",
    targetDev: "sda",
    targetBus: "virtio"
  )],
  serials: @[LibvirtSerial(sourceType: "pty", targetPort: "0")],
  consoles: @[LibvirtConsole(
    sourceType: "pty",
    targetType: "serial",
    targetPort: "0"
  )],
  qemuArgs: @[
    "-netdev", "user,id=hostnet0",
    "-device", "virtio-net-pci,netdev=hostnet0"
  ]
)

echo toXML(domain)
```

With shared folders (virtiofs on Linux):

```nim
domain.memoryBacking = LibvirtMemoryBacking(
  sourceType: "memfd",
  accessMode: "shared"
)
domain.filesystems.add LibvirtFilesystem(
  fsType: "mount",
  accessmode: "passthrough",
  driverType: "virtiofs",
  driverQueue: "1024",
  sourceDir: "/Users/george/code",
  targetDir: "code"
)
```

## Roadmap

- [ ] Auto-detection of KVM/TCG acceleration
- [ ] Snapshot and restore support
- [ ] Provisioning scripts (shell, Ansible)
- [ ] Multi-VM environments (linked VMs)
- [ ] Custom box creation from existing VMs
- [ ] Windows support (via WSL2 or native libvirt)
- [ ] Plugin system for custom provisioners
- [ ] Private networking between VMs

## Architecture

```
spinoza CLI (kapsis)
    │
    ├── config.nim    ── Spinozafile YAML parsing + memory validation
    ├── paths.nim     ── Filesystem layout (flysystem)
    ├── store.nim     ── VM registry (boogie KV store)
    ├── init.nim      ── Interactive Spinozafile creation
    ├── vm.nim        ── Domain lifecycle (libvirt), TCG wrapper
    ├── ssh.nim       ── Interactive SSH sessions (libssh2)
    └── box.nim       ── Box image management (flysystem)
```

## Contributing

- Found a bug? [Create a new Issue](https://github.com/openpeeps/spinoza/issues)
- Want to help? [Fork it!](https://github.com/openpeeps/spinoza/fork)

## License

GPL-v3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.

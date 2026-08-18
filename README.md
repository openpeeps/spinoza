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
- **Shared folders** mount host directories inside the VM via virtiofs
- **Memory validation** enforces minimum 1 GB, checks against host RAM, warns at 70% usage
- **QEMU TCG fallback** auto-generated wrapper on macOS when hardware acceleration is unavailable
- **Flysystem-backed storage** atomic file operations for boxes and VM state

### Prerequisites
You will need to install `libvirt`, `QEMU`, and `libssh2`.

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
sudo mount -t virtiofs <tag> /mnt/shared
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
  subnet: 192.168.122         # Subnet for NAT network
ssh_config:
  port: 2222                  # Host port forwarded to guest SSH
  user: vagrant               # SSH username
  password: vagrant           # SSH password
shared_folders:               # Optional: mount host dirs via virtiofs
  - host: /Users/<username>/code    # Host directory path
    tag: code                       # Mount tag used in guest
  - host: /Users/<username>/data
    tag: data
```

Box images are stored in `~/.spinoza/boxes/`. VM state is tracked in `~/.spinoza/vms/`.

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
    "-netdev", "user,id=hostnet0,hostfwd=tcp::2222-:22",
    "-device", "virtio-net-pci,netdev=hostnet0"
  ]
)

echo toXML(domain)
```

With shared folders (virtiofs):

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
- [ ] Port forwarding configuration in Spinozafile
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
    ├── network.nim   ── NAT network management (libvirt)
    ├── ssh.nim       ── Interactive SSH sessions (libssh2)
    └── box.nim       ── Box image management (flysystem)
```

## Contributing

- Found a bug? [Create a new Issue](https://github.com/openpeeps/spinoza/issues)
- Want to help? [Fork it!](https://github.com/openpeeps/spinoza/fork)

## License

GPL-v3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.

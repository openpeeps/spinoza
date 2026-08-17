<p align="center">
  <img src="https://github.com/openpeeps/spinoza/blob/main/.github/spinoza-logo.png" width="60px"><br>
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

## Key Features

- **Single-file configuration** `Spinozafile` in YAML defines your VM specs
- **Libvirt + QEMU backend** direct integration with the Linux virtualization stack
- **Built-in SSH** interactive shell sessions via libssh2, no external `ssh` or `expect` needed
- **NAT networking** automatic subnet allocation with DHCP via libvirt
- **Box management** download, list, and remove qcow2 box images
- **QEMU TCG fallback** works on macOS without hardware acceleration
- **Real-time boot output** tails QEMU log during VM startup
- **Flysystem-backed storage** atomic file operations for boxes and VM state
- **Written in Nim** single binary, no runtime dependencies beyond libvirt/libssh2

### Prerequisites
You will need to install `libvirt`, `QEMU`,  and `libssh2`.

> [!NOTE]
> Browse available boxes on [HashiCorp Cloud](https://portal.cloud.hashicorp.com). For example, [Generic Boxes](https://portal.cloud.hashicorp.com/vagrant/discover/generic) with libvirt support work seamlessly with Spinoza.

## Quick Start

**1. Initialize a Spinozafile**

```bash
spinoza init
```

This will interactively prompt for box name, VM name, memory, CPUs, and SSH settings.

**2. Add a box image**

```bash
spinoza box add https://example.com/debian-11.qcow2
```

**3. Boot the VM**

```bash
spinoza up
```

**4. SSH into the VM**

```bash
spinoza ssh
```

**5. Shut down**

```bash
spinoza halt
```

## Commands

### Setup

| Command | Description |
|---|---|
| `spinoza init` | Create a Spinozafile in the current directory |

### Virtual Machines

| Command | Description |
|---|---|
| `spinoza up` | Boot a VM from the Spinozafile |
| `spinoza up <name>` | Boot a named VM from the registry |
| `spinoza halt` | Gracefully shut down the running VM |
| `spinoza halt <name>` | Shut down a named VM |
| `spinoza halt --force` | Force power-off the VM |
| `spinoza destroy` | Destroy the VM and remove its definition |
| `spinoza ssh` | Connect to the VM via interactive SSH |
| `spinoza status` | List all managed VMs and their state |

### Box Management

| Command | Description |
|---|---|
| `spinoza box add <url>` | Download and add a qcow2 box image |
| `spinoza box remove <name>` | Remove a box image |
| `spinoza box list` | List available box images |

## Spinozafile Format

```yaml
box: <box-name>              # Name of the qcow2 box image
name: <vm-name>              # Unique VM identifier
memory: <MB>                 # RAM in megabytes
cpus: <count>                # Number of virtual CPUs
network:
  subnet: <ip-prefix>        # Subnet for NAT network (e.g. 192.168.122)
ssh_config:
  port: <port>               # Host port forwarded to guest SSH
  user: <username>           # SSH username
  password: <password>       # SSH password
```

Box images are stored in `~/.spinoza/boxes/`. VM state is tracked in `~/.spinoza/vms/`.

## Roadmap

- [ ] Snapshot and restore support
- [ ] Port forwarding configuration in Spinozafile
- [ ] Provisioning scripts (shell, Ansible)
- [ ] Multi-VM environments (linked VMs)
- [ ] Custom box creation from existing VMs
- [ ] Windows support (via WSL2 or native libvirt)
- [ ] Plugin system for custom provisioners
- [ ] Auto-detection of KVM/TGX acceleration
- [ ] `spinoza reload` restart VM with updated config
- [ ] `spinoza suspend` / `spinoza resume` save/restore VM state
- [ ] Shared folders between host and guest
- [ ] Private networking between VMs

## Architecture

```
spinoza CLI (kapsis)
    │
    ├── config.nim    ── Spinozafile YAML parsing (openparser)
    ├── paths.nim     ── Filesystem layout (flysystem)
    ├── store.nim     ── VM registry (boogie KV store)
    ├── init.nim      ── Interactive Spinozafile creation
    ├── vm.nim        ── Domain lifecycle (libvirt)
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

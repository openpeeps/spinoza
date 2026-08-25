# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[net, options, os, osproc, posix, strutils, times]
import libvirt
import flysystem
import pkg/kapsis/interactive/prompts

import ./config
import ./logs
import ./network
import ./paths
import ./provision as provisionModule
import ./store
import ./ssh as sshModule

const qemuTcgWrapper = """#!/bin/sh
set -e
QEMU_BIN="__QEMU_BIN__"
rewrite() {
  case "$1" in
    *accel=hvf*)
      printf '%s' "$1" | sed 's/accel=hvf:tcg/accel=tcg/g; s/accel=hvf/accel=tcg/g'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}
i=1
for arg in "$@"; do
  set -- "$@" "$(rewrite "$arg")"
  shift
  i=$((i + 1))
done
exec "$QEMU_BIN" "$@"
"""

const qemuVmnetWrapper = """#!/bin/sh
# Spinoza vmnet networking wrapper.
# - Routes through socket_vmnet_client ONLY when the command line actually
#   references the vmnet netdev (fd=3), so libvirt's capability probes
#   (-help/-machine help/etc.) never require the daemon.
# - Rewrites accel=hvf to accel=tcg for hosts without working Hypervisor.framework.
set -e
QEMU_BIN="__QEMU_BIN__"
CLIENT="__VMNET_CLIENT__"
SOCKET="__VMNET_SOCKET__"

rewrite() {
  case "$1" in
    *accel=hvf*)
      printf '%s' "$1" | sed 's/accel=hvf:tcg/accel=tcg/g; s/accel=hvf/accel=tcg/g'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

NEEDS_NET=0
for arg in "$@"; do
  case "$arg" in
    *fd=3*|*id=hostnet0*) NEEDS_NET=1 ;;
  esac
  set -- "$@" "$(rewrite "$arg")"
  shift
done

if [ "$NEEDS_NET" = "1" ]; then
  exec "$CLIENT" "$SOCKET" "$QEMU_BIN" "$@"
else
  exec "$QEMU_BIN" "$@"
fi
"""

proc wrapperPath(): string =
  let p = getEnv("LIBVIRT_QEMUWrapper")
  if p.len > 0: p
  elif defined(macosx):
    let wrapper = getHomeDir() / ".spinoza" / "qemu-tcg.sh"
    if not fileExists(wrapper):
      let qemuBin = findExe("qemu-system-x86_64")
      if qemuBin.len == 0:
        raise newException(IOError, "qemu-system-x86_64 not found in PATH")
      writeFile(wrapper, qemuTcgWrapper.replace("__QEMU_BIN__", qemuBin))
      discard execShellCmd("chmod +x " & wrapper)
    wrapper
  else:
    findExe("qemu-system-x86_64")

proc pathPresent(p: string): bool =
  ## True for any existing path (files, dirs, unix sockets).
  var s: Stat
  result = stat(p.cstring, s) == 0

proc vmnetWrapperPath(socketPath: string): string =
  ## Emulator shim routing QEMU through socket_vmnet_client for vmnet modes.
  when defined(macosx):
    if not pathPresent(socketPath):
      raise newException(IOError,
        "socket_vmnet socket not found at " & socketPath & ".\n" &
        "Start the daemon with: sudo port load socket_vmnet\n" &
        "(see the Networking section of the README)")
    let client = findExe("socket_vmnet_client")
    if client.len == 0:
      raise newException(IOError,
        "socket_vmnet_client not found in PATH.\n" &
        "Install it with: sudo port install socket_vmnet")
    let qemuBin = findExe("qemu-system-x86_64")
    if qemuBin.len == 0:
      raise newException(IOError, "qemu-system-x86_64 not found in PATH")
    let wrapper = getHomeDir() / ".spinoza" / "qemu-vmnet.sh"
    writeFile(wrapper, qemuVmnetWrapper
      .replace("__VMNET_CLIENT__", client)
      .replace("__VMNET_SOCKET__", socketPath)
      .replace("__QEMU_BIN__", qemuBin))
    discard execShellCmd("chmod +x " & wrapper)
    wrapper
  else:
    raise newException(NotImplementedError,
      "vmnet networking is only available on macOS")

proc freeTcpPort*(): int =
  ## Ask the kernel for a free TCP port by binding port 0 on loopback.
  var sock = newSocket()
  sock.bindAddr(Port(0), "127.0.0.1")
  let port = sock.getLocalAddr()[1].int
  sock.close()
  port

proc resolveBoxPath*(config: SpinozaConfig): string =
  let disk = fs.rawDisk("boxes")
  disk.root / boxPath(config.box)

proc isVmnetMode*(mode: string): bool = mode in ["shared", "host"]

proc netdevArgs(mode: string, forwardedPort: int, mac: string): seq[string] =
  ## QEMU networking args for the requested mode.
  if mode == "user":
    @["-netdev", "user,id=hostnet0,hostfwd=tcp::" & $forwardedPort & "-:22",
      "-device", "virtio-net-pci,netdev=hostnet0,addr=0x7"]
  else:
    var dev = "virtio-net-pci,netdev=hostnet0,addr=0x7"
    if mac.len > 0:
      dev.add ",mac=" & mac
    # fd 3 is handed over by socket_vmnet_client (see qemu-vmnet.sh wrapper)
    @["-netdev", "socket,id=hostnet0,fd=3", "-device", dev]

proc domainXml*(config: SpinozaConfig, boxPath: string,
                vmUuid: string, forwardedPort: int): string =
  let mem = $(config.memory * 1024)
  let mode = config.network.netMode()
  let mac = deriveMac(vmUuid)
  var d = LibvirtDomain(
    virtType: "qemu",
    metadata: LibvirtMetadata(name: config.name),
    memory: LibvirtMemory(value: mem, unit: "KiB"),
    currentMemory: LibvirtMemory(value: mem, unit: "KiB"),
    vcpu: LibvirtVcpu(value: $config.cpus, placement: "static"),
    os: LibvirtOS(
      osType: "hvm", arch: "x86_64", machine: "pc",
      boot: @[bdHardDisk]
    ),
    clock: LibvirtClock(offset: "utc"),
    events: LibvirtEvents(
      onPoweroff: oaDestroy, onReboot: oaRestart, onCrash: oaDestroy),
    emulator: if isVmnetMode(mode): vmnetWrapperPath(config.network.resolveSocketPath())
              else: wrapperPath(),
    disks: @[LibvirtDisk(
      diskType: "file", device: "disk",
      driverName: "qemu", driverType: "qcow2",
      sourceFile: boxPath,
      targetDev: "vda", targetBus: "virtio"
    )],
    serials: @[LibvirtSerial(
      sourceType: "file", sourcePath: vmLogPath(config.name), targetPort: "0"
    )],
    channels: @[LibvirtChannel(
      channelType: "unix", sourceMode: "bind",
      targetType: "virtio", targetName: "org.qemu.guest_agent.0"
    )],
    qemuArgs: netdevArgs(mode, forwardedPort, mac)
  )
  when defined(macosx):
    if config.shared_folders.len > 0:
      for i, f in config.shared_folders:
        let fsId = "fsdev" & $i
        d.qemuArgs.add "-fsdev"
        d.qemuArgs.add "local,path=" & f.host & ",id=" & fsId & ",security_model=none"
        d.qemuArgs.add "-device"
        d.qemuArgs.add "virtio-9p-pci,fsdev=" & fsId & ",mount_tag=" & f.tag & ",addr=0x8"
  else:
    if config.shared_folders.len > 0:
      d.memoryBacking = LibvirtMemoryBacking(sourceType: "memfd", accessMode: "shared")
      for f in config.shared_folders:
        d.filesystems.add LibvirtFilesystem(
          fsType: "mount", accessmode: "passthrough",
          driverType: "virtiofs", driverQueue: "1024",
          sourceDir: f.host, targetDir: f.tag)
  toXML(d)

proc cleanup*(conn: Connect, domainName: string) =
  try:
    let dom = conn.lookupDomainByName(domainName)
    if dom.isActive:
      dom.destroy
    dom.undefine
  except LibvirtError:
    discard

proc autoMountSharedFolders(host: string, port: int, user, pass: string,
                            folders: seq[SharedFolder]) =
  ## Mount configured shared folders inside the guest over SSH.
  for f in folders:
    let mkdirCmd = "sudo mkdir -p /mnt/" & f.tag
    let mountCmd =
      when defined(macosx):
        "sudo mount -t 9p -o trans=virtio " & f.tag & " /mnt/" & f.tag
      else:
        "sudo mount -t virtiofs " & f.tag & " /mnt/" & f.tag
    discard sshModule.sshExec(host, port, user, pass, mkdirCmd)
    discard sshModule.sshExec(host, port, user, pass, mountCmd)

proc waitUntilReady(spinny: ptr Spinny, name: string, host: string,
                    port: int, user, pass: string, timeoutSec = 120): bool =
  ## Poll SSH readiness while streaming guest serial-console output
  ## above the spinner, so slow (TCG) boots never look stuck.
  var lf: File = nil
  var lpos = 0
  var hinted = false
  var seenBytes = false

  proc onWait(seconds: int) =
    let chunk = pumpLog(vmLogPath(name), lf, lpos)
    if chunk.len > 0:
      seenBytes = true
      for line in chunk.splitLines():
        if line.strip().len > 0:
          spinny[].log(line)
    if not hinted and not seenBytes and seconds >= 15:
      spinny[].log("no serial output yet - this box may need console=ttyS0 (see README)")
      hinted = true

  defer:
    if not lf.isNil: lf.close()

  result = sshModule.probeSsh(host, port, user, pass, timeoutSec, onWait)

proc resolveEndpoint(mode, name, uuid: string,
                     forwardedPort: int): tuple[host: string, port: int] =
  ## SSH endpoint for a VM. vmnet IPs are empty until discovered post-boot.
  if isVmnetMode(mode):
    result = ("", 22)
  else:
    result = ("127.0.0.1", forwardedPort)

proc discoverEndpoint(spinny: var Spinny, mode, name,
                      mac: string): tuple[host: string, port: int] =
  ## Resolve the guest IP for vmnet modes via ARP; passthrough otherwise.
  if isVmnetMode(mode):
    let ip = discoverVmIp(mac)
    if ip.len == 0:
      spinny.error("Could not discover the guest IP for " & name &
        ".\nIs socket_vmnet running? For a static IP, reserve the MAC " &
        mac & " in /etc/bootptab (see README).")
      return ("", 0)
    updateEndpoint(name, ip, 22)
    return (ip, 22)
  let state = loadVm(name)
  if state.isSome:
    return (state.get().sshHost, state.get().sshPort)
  return ("127.0.0.1", 22)

proc up*(config: SpinozaConfig, provision = false) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  let bpath = resolveBoxPath(config)
  if not fileExists(bpath):
    raise newException(IOError, "Box image not found: " & bpath)

  let mode = config.network.netMode()
  let uuid =
    block:
      let existing = loadVm(config.name)
      if existing.isSome: existing.get().uuid else: newVmUuid()
  let hostPort = if isVmnetMode(mode): 0 else: freeTcpPort()

  cleanup(conn, config.name)
  let dom = conn.defineDomainXML(domainXml(config, bpath, uuid, hostPort))
  dom.create

  let (sshHost, sshPort) = resolveEndpoint(mode, config.name, uuid, hostPort)
  var state = VmState(
    uuid: uuid,
    box: config.box,
    name: config.name,
    memory: config.memory,
    cpus: config.cpus,
    netMode: mode,
    sshHost: sshHost,
    sshPort: sshPort,
    sshUser: config.ssh_config.user,
    sshPass: config.ssh_config.password,
    sharedFolders: config.shared_folders,
    status: "running"
  )
  saveVm(state)

  var spinny = newSpinny("Spinning up " & config.name & "...", "dots", time = true)
  spinny.start()

  var (host, port) = (sshHost, sshPort)
  if isVmnetMode(mode):
    (host, port) = spinny.discoverEndpoint(mode, config.name, deriveMac(uuid))
    if host.len == 0:
      return
    spinny.setText("Guest at " & host & " - waiting for sshd...")
  else:
    spinny.setText("Waiting for SSH on " & host & ":" & $port & "...")

  let vmReady = waitUntilReady(addr spinny, config.name, host, port,
    config.ssh_config.user, config.ssh_config.password)

  if vmReady:
    autoMountSharedFolders(host, port,
      config.ssh_config.user, config.ssh_config.password, config.shared_folders)
    if provision:
      let ok = provisionModule.runProvisions(addr spinny, host, port,
        config.ssh_config.user, config.ssh_config.password,
        config.provision, config.provision_script)
      if not ok: return
      spinny.setText("Provisioning complete")
    spinny.success(config.name & " is ready on " & host & ":" & $port)
  else:
    spinny.error("Timed out waiting for " & config.name & " to start")

proc halt*(config: SpinozaConfig, force: bool = false) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(config.name)
    if dom.isActive:
      dom.destroy
      updateStatus(config.name, "stopped")
    elif not force:
      return
  except LibvirtError:
    discard

proc destroy*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  cleanup(conn, config.name)

proc status*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(config.name)
    let state = if dom.isActive: "running" else: "stopped"
    echo config.name & ": " & state
  except LibvirtError:
    echo config.name & ": not found"

proc domainXmlFromState*(state: VmState, boxPath: string): string =
  let mem = $(state.memory * 1024)
  var d = LibvirtDomain(
    virtType: "qemu",
    metadata: LibvirtMetadata(name: state.name),
    memory: LibvirtMemory(value: mem, unit: "KiB"),
    currentMemory: LibvirtMemory(value: mem, unit: "KiB"),
    vcpu: LibvirtVcpu(value: $state.cpus, placement: "static"),
    os: LibvirtOS(
      osType: "hvm", arch: "x86_64", machine: "pc",
      boot: @[bdHardDisk]
    ),
    clock: LibvirtClock(offset: "utc"),
    events: LibvirtEvents(
      onPoweroff: oaDestroy, onReboot: oaRestart, onCrash: oaDestroy),
    emulator: if isVmnetMode(state.netMode): vmnetWrapperPath(state.netMode.defaultSocketPath())
              else: wrapperPath(),
    disks: @[LibvirtDisk(
      diskType: "file", device: "disk",
      driverName: "qemu", driverType: "qcow2",
      sourceFile: boxPath,
      targetDev: "vda", targetBus: "virtio"
    )],
    serials: @[LibvirtSerial(
      sourceType: "file", sourcePath: vmLogPath(state.name), targetPort: "0"
    )],
    channels: @[LibvirtChannel(
      channelType: "unix", sourceMode: "bind",
      targetType: "virtio", targetName: "org.qemu.guest_agent.0"
    )],
    qemuArgs: netdevArgs(state.netMode, state.sshPort, deriveMac(state.uuid))
  )
  when defined(macosx):
    if state.sharedFolders.len > 0:
      for i, f in state.sharedFolders:
        let fsId = "fsdev" & $i
        d.qemuArgs.add "-fsdev"
        d.qemuArgs.add "local,path=" & f.host & ",id=" & fsId & ",security_model=none"
        d.qemuArgs.add "-device"
        d.qemuArgs.add "virtio-9p-pci,fsdev=" & fsId & ",mount_tag=" & f.tag & ",addr=0x8"
  else:
    if state.sharedFolders.len > 0:
      d.memoryBacking = LibvirtMemoryBacking(sourceType: "memfd", accessMode: "shared")
      for f in state.sharedFolders:
        d.filesystems.add LibvirtFilesystem(
          fsType: "mount", accessmode: "passthrough",
          driverType: "virtiofs", driverQueue: "1024",
          sourceDir: f.host, targetDir: f.tag)
  toXML(d)

proc resolveBoxPathFromState*(state: VmState): string =
  let disk = fs.rawDisk("boxes")
  disk.root / boxPath(state.box)

proc upFromStore*(state: VmState) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  let bpath = resolveBoxPathFromState(state)
  if not fileExists(bpath):
    raise newException(IOError, "Box image not found: " & bpath)

  cleanup(conn, state.name)
  let dom = conn.defineDomainXML(domainXmlFromState(state, bpath))
  dom.create
  updateStatus(state.name, "running")

  var spinny = newSpinny("Spinning up " & state.name & "...", "dots", time = true)
  spinny.start()

  var (host, port) = (state.sshHost, state.sshPort)
  if isVmnetMode(state.netMode):
    (host, port) = spinny.discoverEndpoint(state.netMode, state.name,
      deriveMac(state.uuid))
    if host.len == 0:
      return
    spinny.setText("Guest at " & host & " - waiting for sshd...")
  else:
    spinny.setText("Waiting for SSH on " & host & ":" & $port & "...")

  let vmReady = waitUntilReady(addr spinny, state.name, host, port,
    state.sshUser, state.sshPass)

  if vmReady:
    autoMountSharedFolders(host, port, state.sshUser, state.sshPass,
      state.sharedFolders)
    spinny.success(state.name & " is ready on " & host & ":" & $port)
  else:
    spinny.error("Timed out waiting for " & state.name & " to start")

proc haltFromStore*(state: VmState, force: bool = false) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(state.name)
    if dom.isActive:
      dom.destroy
      updateStatus(state.name, "stopped")
    elif not force:
      return
  except LibvirtError:
    discard

proc reload*(config: SpinozaConfig, provision = false) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  var spinny = newSpinny("Reloading " & config.name & "...", "dots", time = true)
  spinny.start()

  try:
    let dom = conn.lookupDomainByName(config.name)
    if dom.isActive:
      # Try graceful guest-agent shutdown first, fall back to ACPI
      try:
        dom.shutdown(cuint(VIR_DOMAIN_SHUTDOWN_GUEST_AGENT))
      except LibvirtError:
        dom.shutdown
      let deadline = now() + initDuration(seconds = 30)
      while now() < deadline:
        try:
          let domState = conn.lookupDomainByName(config.name)
          if not domState.isActive:
            break
        except LibvirtError:
          break
        sleep(100)
      try:
        let dom2 = conn.lookupDomainByName(config.name)
        if dom2.isActive:
          dom2.destroy
      except LibvirtError:
        discard
    conn.cleanup(config.name)
  except LibvirtError:
    discard

  let bpath = resolveBoxPath(config)
  if not fileExists(bpath):
    spinny.error("Box image not found: " & bpath)
    return

  let mode = config.network.netMode()
  let uuid =
    block:
      let existing = loadVm(config.name)
      if existing.isSome: existing.get().uuid else: newVmUuid()
  let hostPort = if isVmnetMode(mode): 0 else: freeTcpPort()

  let dom = conn.defineDomainXML(domainXml(config, bpath, uuid, hostPort))
  dom.create

  let (sshHost, sshPort) = resolveEndpoint(mode, config.name, uuid, hostPort)
  block persistState:
    var state = VmState(
      uuid: uuid,
      box: config.box,
      name: config.name,
      memory: config.memory,
      cpus: config.cpus,
      netMode: mode,
      sshHost: sshHost,
      sshPort: sshPort,
      sshUser: config.ssh_config.user,
      sshPass: config.ssh_config.password,
      sharedFolders: config.shared_folders,
      status: "running"
    )
    saveVm(state)

  var (host, port) = (sshHost, sshPort)
  if isVmnetMode(mode):
    (host, port) = spinny.discoverEndpoint(mode, config.name, deriveMac(uuid))
    if host.len == 0:
      return
    spinny.setText("Guest at " & host & " - waiting for sshd...")
  else:
    spinny.setText("Waiting for SSH on " & host & ":" & $port & "...")

  updateStatus(config.name, "running")

  let vmReady = waitUntilReady(addr spinny, config.name, host, port,
    config.ssh_config.user, config.ssh_config.password)

  if vmReady:
    if provision:
      let ok = provisionModule.runProvisions(addr spinny, host, port,
        config.ssh_config.user, config.ssh_config.password,
        config.provision, config.provision_script)
      if not ok: return
    spinny.success(config.name & " reloaded and ready on " & host & ":" & $port)
  else:
    spinny.error("Timed out waiting for " & config.name & " to restart")

proc reloadFromStore*(state: VmState) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  var spinny = newSpinny("Reloading " & state.name & "...", "dots", time = true)
  spinny.start()

  try:
    let dom = conn.lookupDomainByName(state.name)
    if dom.isActive:
      # Try graceful guest-agent shutdown first, fall back to ACPI
      try:
        dom.shutdown(cuint(VIR_DOMAIN_SHUTDOWN_GUEST_AGENT))
      except LibvirtError:
        dom.shutdown
      let deadline = now() + initDuration(seconds = 30)
      while now() < deadline:
        try:
          let domState = conn.lookupDomainByName(state.name)
          if not domState.isActive:
            break
        except LibvirtError:
          break
        sleep(100)
      try:
        let dom2 = conn.lookupDomainByName(state.name)
        if dom2.isActive:
          dom2.destroy
      except LibvirtError:
        discard
    conn.cleanup(state.name)
  except LibvirtError:
    discard

  let bpath = resolveBoxPathFromState(state)
  if not fileExists(bpath):
    spinny.error("Box image not found: " & bpath)
    return

  let dom = conn.defineDomainXML(domainXmlFromState(state, bpath))
  dom.create
  updateStatus(state.name, "running")

  var (host, port) = (state.sshHost, state.sshPort)
  if isVmnetMode(state.netMode):
    (host, port) = spinny.discoverEndpoint(state.netMode, state.name,
      deriveMac(state.uuid))
    if host.len == 0:
      return
    spinny.setText("Guest at " & host & " - waiting for sshd...")
  else:
    spinny.setText("Waiting for SSH on " & host & ":" & $port & "...")

  let vmReady = waitUntilReady(addr spinny, state.name, host, port,
    state.sshUser, state.sshPass)

  if vmReady:
    spinny.success(state.name & " reloaded and ready on " & host & ":" & $port)
  else:
    spinny.error("Timed out waiting for " & state.name & " to restart")

proc suspend*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(config.name)
    if dom.isActive:
      dom.suspend
      updateStatus(config.name, "suspended")
      displaySuccess(config.name & " suspended")
    else:
      displayWarning(config.name & " is not running")
  except LibvirtError:
    displayError("Failed to suspend " & config.name)

proc suspendFromStore*(state: VmState) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(state.name)
    if dom.isActive:
      dom.suspend
      updateStatus(state.name, "suspended")
      displaySuccess(state.name & " suspended")
    else:
      displayWarning(state.name & " is not running")
  except LibvirtError:
    displayError("Failed to suspend " & state.name)

proc resume*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(config.name)
    let (s, _) = dom.state()
    if s == VIR_DOMAIN_PAUSED:
      dom.resume
      updateStatus(config.name, "running")
      displaySuccess(config.name & " resumed")
    else:
      displayWarning(config.name & " is not paused")
  except LibvirtError:
    displayError("Failed to resume " & config.name)

proc resumeFromStore*(state: VmState) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(state.name)
    let (s, _) = dom.state()
    if s == VIR_DOMAIN_PAUSED:
      dom.resume
      updateStatus(state.name, "running")
      displaySuccess(state.name & " resumed")
    else:
      displayWarning(state.name & " is not paused")
  except LibvirtError:
    displayError("Failed to resume " & state.name)

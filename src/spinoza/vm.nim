# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, times, strutils]
import libvirt
import flysystem
import pkg/kapsis/interactive/prompts

import ./config
import ./paths
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

proc resolveBoxPath*(config: SpinozaConfig): string =
  let disk = fs.rawDisk("boxes")
  disk.root / boxPath(config.box)

proc domainXml*(config: SpinozaConfig, boxPath: string): string =
  let mem = $(config.memory * 1024)
  let sshPort = $config.ssh_config.port
  let d = domain(`type`="qemu"):
    name: config.name
    memory unit="KiB": mem
    currentMemory unit="KiB": mem
    vcpu placement="static": $config.cpus
    os:
      `type` arch="x86_64", machine="pc": "hvm"
      boot dev="hd"
    clock offset="utc"
    on_poweroff: "destroy"
    on_reboot: "restart"
    on_crash: "destroy"
    devices:
      emulator: wrapperPath()
      disk `type`="file", device="disk":
        driver name="qemu", `type`="qcow2"
        source file=boxPath
        target dev="sda", bus="scsi"
      serial `type`="pty":
        target port="0"
      console `type`="pty":
        target `type`="serial", port="0"
      channel `type`="unix":
        source mode="bind"
        target `type`="virtio", name="org.qemu.guest_agent.0"
    qemu_commandline:
      qemu_arg value="-netdev"
      qemu_arg value="user,id=hostnet0,hostfwd=tcp::" & sshPort & "-:22"
      qemu_arg value="-device"
      qemu_arg value="virtio-net-pci,netdev=hostnet0,addr=0x7"
  $d

proc cleanup*(conn: Connect, domainName: string) =
  try:
    let dom = conn.lookupDomainByName(domainName)
    if dom.isActive:
      dom.destroy
    dom.undefine
  except LibvirtError:
    discard

proc up*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  let bpath = resolveBoxPath(config)
  if not fileExists(bpath):
    raise newException(IOError, "Box image not found: " & bpath)

  cleanup(conn, config.name)
  let dom = conn.defineDomainXML(domainXml(config, bpath))
  dom.create

  let uuid = newVmUuid()
  var state = VmState(
    uuid: uuid,
    box: config.box,
    name: config.name,
    memory: config.memory,
    cpus: config.cpus,
    sshPort: config.ssh_config.port,
    sshUser: config.ssh_config.user,
    sshPass: config.ssh_config.password,
    subnet: config.network.subnet,
    status: "running"
  )
  saveVm(state)

  var spinny = newSpinny("Spinning up " & config.name & "...", "dots")
  spinny.start()

  let vmReady = sshModule.probeSsh("127.0.0.1", config.ssh_config.port,
    config.ssh_config.user, config.ssh_config.password)

  if vmReady:
    spinny.success(config.name & " is ready on 127.0.0.1:" & $config.ssh_config.port)
  else:
    spinny.error("Timed out waiting for " & config.name & " to start")

proc halt*(config: SpinozaConfig, force: bool = false) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  try:
    let dom = conn.lookupDomainByName(config.name)
    if dom.isActive:
      dom.destroy
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
  let sshPort = $state.sshPort
  let d = domain(`type`="qemu"):
    name: state.name
    memory unit="KiB": mem
    currentMemory unit="KiB": mem
    vcpu placement="static": $state.cpus
    os:
      `type` arch="x86_64", machine="pc": "hvm"
      boot dev="hd"
    clock offset="utc"
    on_poweroff: "destroy"
    on_reboot: "restart"
    on_crash: "destroy"
    devices:
      emulator: wrapperPath()
      disk `type`="file", device="disk":
        driver name="qemu", `type`="qcow2"
        source file=boxPath
        target dev="sda", bus="scsi"
      serial `type`="pty":
        target port="0"
      console `type`="pty":
        target `type`="serial", port="0"
      channel `type`="unix":
        source mode="bind"
        target `type`="virtio", name="org.qemu.guest_agent.0"
    qemu_commandline:
      qemu_arg value="-netdev"
      qemu_arg value="user,id=hostnet0,hostfwd=tcp::" & sshPort & "-:22"
      qemu_arg value="-device"
      qemu_arg value="virtio-net-pci,netdev=hostnet0,addr=0x7"
  $d

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

  var spinny = newSpinny("Spinning up " & state.name & "...", "dots")
  spinny.start()

  let vmReady = sshModule.probeSsh("127.0.0.1", state.sshPort, state.sshUser, state.sshPass)

  if vmReady:
    spinny.success(state.name & " is ready on 127.0.0.1:" & $state.sshPort)
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

proc reload*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  var spinny = newSpinny("Reloading " & config.name & "...", "dots")
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

  let dom = conn.defineDomainXML(domainXml(config, bpath))
  dom.create
  updateStatus(config.name, "running")

  let vmReady = sshModule.probeSsh("127.0.0.1", config.ssh_config.port,
    config.ssh_config.user, config.ssh_config.password)

  if vmReady:
    spinny.success(config.name & " reloaded and ready on 127.0.0.1:" & $config.ssh_config.port)
  else:
    spinny.error("Timed out waiting for " & config.name & " to restart")

proc reloadFromStore*(state: VmState) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  var spinny = newSpinny("Reloading " & state.name & "...", "dots")
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

  let vmReady = sshModule.probeSsh("127.0.0.1", state.sshPort, state.sshUser, state.sshPass)

  if vmReady:
    spinny.success(state.name & " reloaded and ready on 127.0.0.1:" & $state.sshPort)
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

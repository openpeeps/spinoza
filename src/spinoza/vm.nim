# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, osproc, times, strutils]
import libvirt
import flysystem

import ./config
import ./paths

const
  consolePollIntervalMs = 50

proc wrapperPath(): string =
  let p = getEnv("LIBVIRT_QEMUWrapper")
  if p.len > 0: p
  else:
    let localPath = getCurrentDir() / "qemu-tcg.sh"
    if fileExists(localPath): localPath
    else: findExe("qemu-system-x86_64")

proc resolveBoxPath*(config: SpinozaConfig): string =
  let disk = fs.rawDisk("boxes")
  disk.root / boxPath(config.box)

proc qemuLogPath*(config: SpinozaConfig): string =
  getHomeDir() / ".cache" / "libvirt" / "qemu" / "log" / (config.name & ".log")

proc domainXml*(config: SpinozaConfig, boxPath: string): string =
  let emu = wrapperPath()
  let mem = $(config.memory * 1024)
  let sshPort = $config.ssh_config.port
  "<domain type='qemu'>\n" &
  "  <name>" & config.name & "</name>\n" &
  "  <memory unit='KiB'>" & mem & "</memory>\n" &
  "  <currentMemory unit='KiB'>" & mem & "</currentMemory>\n" &
  "  <vcpu placement='static'>" & $config.cpus & "</vcpu>\n" &
  "  <os>\n" &
  "    <type arch='x86_64' machine='pc'>hvm</type>\n" &
  "    <boot dev='hd'/>\n" &
  "  </os>\n" &
  "  <clock offset='utc'/>\n" &
  "  <on_poweroff>destroy</on_poweroff>\n" &
  "  <on_reboot>restart</on_reboot>\n" &
  "  <on_crash>destroy</on_crash>\n" &
  "  <devices>\n" &
  "    <emulator>" & emu & "</emulator>\n" &
  "    <controller type='scsi' index='0' model='virtio-scsi'/>\n" &
  "    <disk type='file' device='disk'>\n" &
  "      <driver name='qemu' type='qcow2'/>\n" &
  "      <source file='" & boxPath & "'/>\n" &
  "      <target dev='sda' bus='scsi'/>\n" &
  "    </disk>\n" &
  "    <serial type='pty'>\n" &
  "      <target port='0'/>\n" &
  "    </serial>\n" &
  "    <console type='pty'>\n" &
  "      <target type='serial' port='0'/>\n" &
  "    </console>\n" &
  "  </devices>\n" &
  "  <qemu:commandline xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>\n" &
  "    <qemu:arg value='-netdev'/>\n" &
  "    <qemu:arg value='user,id=hostnet0,hostfwd=tcp::" & sshPort & "-:22'/>\n" &
  "    <qemu:arg value='-device'/>\n" &
  "    <qemu:arg value='virtio-net-pci,netdev=hostnet0,addr=0x4'/>\n" &
  "  </qemu:commandline>\n" &
  "</domain>"

proc cleanup*(conn: Connect, domainName: string) =
  try:
    let dom = conn.lookupDomainByName(domainName)
    if dom.isActive:
      dom.destroy
    dom.undefine
  except LibvirtError:
    discard

proc waitForSsh*(port: int, timeoutSec = 120): bool =
  let deadline = now() + initDuration(seconds = timeoutSec)
  while now() < deadline:
    let rc = execCmd("nc -z -w 1 127.0.0.1 " & $port)
    if rc == 0:
      return true
    sleep(3000)
  false

proc tailQemuLog*(config: SpinozaConfig, logSize: int64, timeoutSec = 120) =
  let logFile = qemuLogPath(config)
  let sshPort = config.ssh_config.port
  let deadline = now() + initDuration(seconds = timeoutSec)
  var pos = logSize
  var sshReady = false

  while now() < deadline:
    if fileExists(logFile):
      let content = readFile(logFile)
      if content.len > pos:
        let newContent = content[pos .. ^1]
        pos = content.len
        for line in newContent.splitLines():
          if line.len == 0: continue
          # Only show timestamped lines and char device info
          if line.startsWith("20"):
            echo line
          elif "char device" in line or "redirected" in line:
            echo line
          elif "tainted" in line:
            echo line
          elif "shutting down" in line or "terminated" in line:
            echo line
        stdout.flushFile()

    let rc = execCmd("nc -z -w 1 127.0.0.1 " & $sshPort)
    if rc == 0:
      sshReady = true
      break

    sleep(consolePollIntervalMs)

  if sshReady:
    echo "\nSSH is ready on 127.0.0.1:" & $sshPort
  else:
    echo "\nTimed out waiting for SSH on port " & $sshPort

proc up*(config: SpinozaConfig) =
  let conn = openConnect("qemu:///session")
  defer: conn.close

  let bpath = resolveBoxPath(config)
  if not fileExists(bpath):
    raise newException(IOError, "Box image not found: " & bpath)

  # Record log size before starting (new entries are QEMU output)
  let logFile = qemuLogPath(config)
  var logSize: int64 = 0
  if fileExists(logFile):
    logSize = getFileSize(logFile)

  cleanup(conn, config.name)
  let dom = conn.defineDomainXML(domainXml(config, bpath))
  dom.create
  echo config.name & ": starting..."

  # Brief pause for QEMU to write initial log entries
  sleep(200)

  # Tail the QEMU log while waiting for SSH
  tailQemuLog(config, logSize)

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

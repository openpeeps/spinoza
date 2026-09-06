# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os]
import flysystem

const
  spinozaDirName* = ".spinoza"
  boxesDirName* = "boxes"
  vmsDirName* = "vms"
  logsDirName* = "logs"
  settingsFileName* = "settings.json"
  defaultConfigName* = "Spinozafile"

var
  fs*: Filesystem

proc initFs*() =
  let base = getHomeDir() / spinozaDirName
  createDir(base)
  fs = newFilesystem(defaultDisk = "local")
  fs.addDisk("boxes", newLocalDriver(base / boxesDirName))
  fs.addDisk("vms", newLocalDriver(base / vmsDirName))
  fs.addDisk("settings", newLocalDriver(base))

proc settingsFile*(): string =
  settingsFileName

proc boxPath*(name: string): string =
  name & ".img"

proc vmStateFile*(name: string): string =
  name & ".json"

proc findConfig*(dir: string = getCurrentDir()): string =
  let path = dir / defaultConfigName
  if fileExists(path): path
  else: ""

proc vmDbPath*(): string =
  let base = getHomeDir() / spinozaDirName / vmsDirName
  createDir(base)
  base / "spinoza"

proc logsDir*(): string =
  let base = getHomeDir() / spinozaDirName / logsDirName
  createDir(base)
  base

proc vmLogPath*(name: string): string =
  logsDir() / (name & ".log")

proc vmDiskPath*(name, boxName: string): string =
  ## Per-VM overlay disk image path.
  let base = getHomeDir() / spinozaDirName / vmsDirName
  createDir(base)
  base / (name & "-" & boxName & ".qcow2")

proc ensureOverlay*(name, boxName: string): string =
  ## Create a standalone qcow2 disk for `name` from the base box image.
  ## Returns the disk path. If it already exists, returns it.
  let overlay = vmDiskPath(name, boxName)
  if not fileExists(overlay):
    let base = fs.rawDisk("boxes").root / boxPath(boxName)
    if not fileExists(base):
      raise newException(IOError, "Box image not found: " & base)
    # Create a standalone qcow2 to avoid AppArmor issues with
    # qcow2 backing-file chains on per-domain profiles.
    discard execShellCmd("qemu-img convert -f qcow2 -O qcow2 " &
      quoteShell(base) & " " & quoteShell(overlay))
    if not fileExists(overlay):
      raise newException(IOError, "Failed to create disk: " & overlay)
  overlay

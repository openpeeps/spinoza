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

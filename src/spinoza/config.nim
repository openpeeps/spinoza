# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os]
import pkg/openparser/yaml

import ./paths

export paths

type
  SshConfig* = object
    port*: int
    user*: string
    password*: string

  NetworkConfig* = object
    subnet*: string

  SpinozaConfig* = object
    box*: string
    name*: string
    memory*: int
    cpus*: int
    network*: NetworkConfig
    ssh_config*: SshConfig

proc loadConfig*(path: string): SpinozaConfig =
  parseYAML(readFile(path), SpinozaConfig)

proc findAndLoadConfig*(dir: string = getCurrentDir()): SpinozaConfig =
  let path = findConfig(dir)
  if path.len == 0:
    raise newException(IOError, "Spinozafile not found in " & dir)
  loadConfig(path)

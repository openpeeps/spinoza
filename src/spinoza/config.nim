# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, osproc, strformat, strutils]
import pkg/openparser/yaml
import pkg/kapsis/interactive/prompts

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

proc getHostRamMB*(): int =
  ## Get total host physical RAM in MB.
  when defined(macosx):
    let output = execProcess("sysctl -n hw.memsize")
    result = parseInt(output.strip()) div (1024 * 1024)
  elif defined(linux):
    for line in lines("/proc/meminfo"):
      if line.startsWith("MemTotal:"):
        let parts = line.split()
        result = parseInt(parts[1]) div 1024
        break
  else:
    result = 0

proc validateConfig*(config: SpinozaConfig) =
  ## Validate memory requirements against host RAM.
  let hostRam = getHostRamMB()

  if config.memory < 1024:
    raise newException(ValueError,
      "Memory must be at least 1024 MB (1 GB). Got: " & $config.memory & " MB")

  if hostRam > 0 and config.memory > hostRam:
    raise newException(ValueError,
      fmt"Memory {config.memory} MB exceeds host RAM ({hostRam} MB)")

  if hostRam > 0 and config.memory > int(hostRam.float * 0.70):
    displayWarning(fmt"Memory {config.memory} MB uses more than 70% of host RAM ({hostRam} MB)")

proc loadConfig*(path: string): SpinozaConfig =
  parseYAML(readFile(path), SpinozaConfig)

proc findAndLoadConfig*(dir: string = getCurrentDir()): SpinozaConfig =
  let path = findConfig(dir)
  if path.len == 0:
    raise newException(IOError, "Spinozafile not found in " & dir)
  loadConfig(path)

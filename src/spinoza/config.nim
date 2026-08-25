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

proc parseHook*(p: var YamlParser, v: var seq[string]) =
  ## Override openparser's generic sequence parser for string items.
  ## The stock implementation consumes exactly one token per item, so
  ## multi-word plain scalars (`- echo hello world`) break parsing.
  ## Rebuild each block-sequence item from every token on its line.
  v.setLen(0)
  case p.curr.kind
  of ytkLB:
    # Inline sequence: [a, b, c]
    p.advance() # '['
    while p.curr.kind != ytkRB:
      if p.curr.kind == ytkEOF:
        p.error("Unexpected end of file in inline sequence")
      var item: string
      p.parseHook(item)
      v.add(item)
      if p.curr.kind == ytkComma:
        p.advance()
      elif p.curr.kind != ytkRB:
        p.error("Expected comma or ] in inline sequence")
    p.advance() # ']'
  of ytkDash:
    # Block sequence:
    # - item one
    # - item two
    let seqIndent = p.curr.indent
    while p.curr.kind == ytkDash and p.curr.indent == seqIndent:
      let dashLine = p.curr.line
      p.advance() # '-'
      var parts: seq[string] = @[]
      while p.curr.kind != ytkEOF and p.curr.line == dashLine:
        parts.add(p.curr.value)
        p.advance()
      v.add(parts.join(" "))
  else:
    p.error("Expected a sequence")

type
  SshConfig* = object
    user*: string
    password*: string

  NetworkConfig* = object
    mode*: string          ## "user" (SLIRP + forwarded port) | "shared" | "host" (socket_vmnet)
    socket_path*: string   ## Optional override of the socket_vmnet unix socket

  SharedFolder* = object
    host*: string
    tag*: string

  SpinozaConfig* = object
    box*: string
    name*: string
    memory*: int
    cpus*: int
    network*: NetworkConfig
    ssh_config*: SshConfig
    shared_folders*: seq[SharedFolder]
    provision*: seq[string]         ## Inline shell commands, run in order over SSH
    provision_script*: seq[string]  ## Local script paths, piped to remote `bash -s`

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

proc netMode*(n: NetworkConfig): string =
  ## Normalized network mode. Defaults to "user".
  let m = n.mode.toLowerAscii()
  if m.len == 0: "user" else: m

proc defaultSocketPath*(mode: string): string =
  ## Default socket_vmnet unix socket for a given mode name.
  ## MacPorts installs under /opt/local; upstream and Homebrew use /var/run.
  let prefix =
    if fileExists("/opt/local/bin/socket_vmnet_client"): "/opt/local/var/run"
    else: "/var/run"
  case mode
  of "host": prefix & "/socket_vmnet-host"
  else: prefix & "/socket_vmnet"

proc resolveSocketPath*(n: NetworkConfig): string =
  ## Resolve the socket_vmnet unix socket for vmnet modes.
  if n.socket_path.len > 0:
    return n.socket_path
  n.netMode().defaultSocketPath()

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

  let mode = config.network.netMode()
  if mode notin ["user", "shared", "host"]:
    raise newException(ValueError,
      "Invalid network.mode '" & mode &
      "' (expected: user, shared, or host)")

  for script in config.provision_script:
    if not fileExists(script):
      raise newException(IOError, "Provision script not found: " & script)

proc loadConfig*(path: string): SpinozaConfig =
  var config = parseYAML(readFile(path), SpinozaConfig)
  # Resolve provision script paths relative to the Spinozafile directory
  let baseDir = parentDir(absolutePath(path))
  for i, s in mpairs(config.provision_script):
    if not isAbsolute(s):
      config.provision_script[i] = joinPath(baseDir, s)
  config

proc findAndLoadConfig*(dir: string = getCurrentDir()): SpinozaConfig =
  let path = findConfig(dir)
  if path.len == 0:
    raise newException(IOError, "Spinozafile not found in " & dir)
  loadConfig(path)

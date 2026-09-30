# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, strutils]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts
import pkg/kapsis/interactive/widgets

import ./box
import ./config
import ./paths

const
  spinozafileTemplate* = """box: $1
name: $2
type: $3
memory: $4
cpus: $5
network:
  mode: $6
ssh_config:
  user: $7
  password: $8
$9# Provisioners run with 'spinoza up --provision', 'spinoza reload --provision',
# or 'spinoza provision' on a running VM:
# provision:
#   - sudo apt-get update
#   - sudo apt-get install -y nginx
# provision_script:
#   - ./scripts/bootstrap.sh"""

  defaultVmName = "my-vm"
  defaultMemory = "2048"
  defaultCpus = "2"
  defaultSshUser = "vagrant"
  defaultSshPassword = "vagrant"
  defaultBoxName = "debian-11"

  # Any of these switches `init` out of interactive mode.
  valueArgs = [
    "boxName", "--name", "--memory", "--cpus", "--network",
    "--ssh-user", "--ssh-password", "--type", "--shared-folder"
  ]

proc isScripted*(v: Values): bool =
  ## True when `init` was given explicit values on the command line.
  for arg in valueArgs:
    if v.has(arg): return true
  false

proc flagOrPrompt*(v: Values, flag, label, default: string): string =
  ## Use the flag when present, the default when running scripted.
  if v.has(flag):
    v.get(flag).getStr.strip()
  elif isScripted(v):
    default
  else:
    prompt(label, default = default)

proc promptBox(): BoxInfo =
  ## Pick an installed box from a dropdown. Falls back to a free-text
  ## prompt when no boxes are installed yet.
  let boxes = availableBoxes()
  if boxes.len == 0:
    displayWarning("No boxes installed. Run 'spinoza box add <image>' first.")
    let name = prompt("Box image name", default = defaultBoxName)
    return BoxInfo(name: name, kind: bkQemu)

  var labels: seq[string]
  for box in boxes:
    let kind = case box.kind
      of bkQemu: "vm"
      of bkContainer: "container"
    labels.add box.name & " (" & kind & ")"

  let choice = promptInteractive("Box image", labels)
  if choice < 0:
    displayInfo("Aborted")
    quit(0)
  boxes[choice]

proc scriptedBox*(v: Values): BoxInfo =
  ## Resolve the box from the command line, defaulting to the first
  ## installed box when none was named.
  let installed = availableBoxes()
  var name =
    if v.has("boxName"): v.get("boxName").getStr.strip()
    else: ""
  if name.len == 0:
    if installed.len == 0:
      displayError("No boxes installed. Run 'spinoza box add <image>' first.",
        quitProcess = true)
      return
    name = installed[0].name
    displayInfo("Using box: " & name)

  for box in installed:
    if box.name == name: return box
  displayWarning("Box not installed yet: " & name & " (assuming vm)")
  BoxInfo(name: name, kind: bkQemu)

proc resolveKind*(v: Values, box: BoxInfo): BoxKind =
  ## Box kind, honouring an explicit `--type` override.
  if not v.has("--type"):
    return box.kind
  let raw = v.get("--type").getStr.strip().toLowerAscii
  case raw
  of "vm", "qemu": bkQemu
  of "container", "lxc": bkContainer
  else:
    displayError("Invalid --type '" & raw & "' (expected: vm or container)",
      quitProcess = true)
    bkQemu

proc parseFolderSpec*(spec: string): seq[SharedFolder] =
  ## Parse `--shared-folder` values: `host:tag`, comma separated.
  for item in spec.split(','):
    let trimmed = item.strip()
    if trimmed.len == 0: continue
    let parts = trimmed.split(':')
    if parts.len < 2:
      displayError("Invalid --shared-folder '" & trimmed &
        "' (expected host/path,tag)", quitProcess = true)
    let tag = parts[^1]
    let host = parts[0 ..< parts.len - 1].join(":")
    if host.len == 0 or tag.len == 0:
      displayError("Invalid --shared-folder '" & trimmed &
        "' (expected host/path,tag)", quitProcess = true)
    result.add SharedFolder(host: host, tag: tag)

proc renderFolders*(folders: seq[SharedFolder]): string =
  ## Render the `shared_folders:` block for the Spinozafile template.
  if folders.len == 0: return ""
  result = "shared_folders:\n"
  for folder in folders:
    result.add "  - host: " & folder.host & "\n    tag: " & folder.tag & "\n"

proc validateMemory*(memory: string): bool =
  ## Validate a requested memory size. Returns false on a fatal error.
  let memVal =
    try: parseInt(memory)
    except ValueError:
      displayError("Memory must be a positive integer (MB). Got: " & memory)
      return false
  if memVal <= 0:
    displayError("Memory must be a positive integer (MB). Got: " & memory & " MB")
    return false
  let hostRam = getHostRamMB()
  if hostRam > 0 and memVal > hostRam:
    displayError("Memory " & memory & " MB exceeds host RAM (" & $hostRam & " MB)")
    return false
  if hostRam > 0 and memVal > int(hostRam.float * 0.70):
    displayWarning("Memory " & memory & " MB uses more than 70% of host RAM (" & $hostRam & " MB)")
  true

proc initCommand*(v: Values) =
  ## Create a Spinozafile in the current directory. Runs interactively
  ## with no arguments, or fully scripted when any value flag is given.
  initFs()
  let configFile = getCurrentDir() / "Spinozafile"
  if fileExists(configFile):
    if not v.has("--force"):
      displayError("Spinozafile already exists in " & getCurrentDir() &
        " (use --force to overwrite)")
      return
    displayWarning("Overwriting existing Spinozafile")

  let scripted = isScripted(v)
  if not scripted:
    displayInfo("Initializing new Spinozafile...")
    echo ""

  let box =
    if scripted: scriptedBox(v)
    else: promptBox()
  let isContainer = resolveKind(v, box) == bkContainer

  let name = flagOrPrompt(v, "--name", "VM name", defaultVmName)
  if name.len == 0:
    displayError("VM name cannot be empty")
    return
  let memory = flagOrPrompt(v, "--memory", "Memory (MB)", defaultMemory)
  if not validateMemory(memory): return
  let cpus = flagOrPrompt(v, "--cpus", "CPUs", defaultCpus)
  let cpuVal =
    try: parseInt(cpus)
    except ValueError:
      displayError("CPUs must be a positive integer. Got: " & cpus)
      return
  if cpuVal <= 0:
    displayError("CPUs must be a positive integer. Got: " & cpus)
    return

  let allowedModes =
    if isContainer: @["shared", "host"] else: @["user", "shared", "host"]
  let netMode = flagOrPrompt(v, "--network",
    "Network mode (" & allowedModes.join("/") & ")",
    if isContainer: "shared" else: "user").toLowerAscii
  if netMode notin allowedModes:
    let expected =
      if isContainer: "shared or host (containers have no userspace networking)"
      else: "user, shared, or host"
    displayError("Invalid network mode '" & netMode & "' (expected: " & expected & ")")
    return

  let sshUser = flagOrPrompt(v, "--ssh-user", "SSH user", defaultSshUser)
  var sshPass: string
  if v.has("--ssh-password"):
    sshPass = v.get("--ssh-password").getStr.strip()
  elif scripted:
    sshPass = defaultSshPassword
  else:
    sshPass = promptSecret("SSH password")

  # Shared folders: flags when scripted, an interactive loop otherwise.
  var sharedFolders: seq[SharedFolder]
  if scripted:
    if v.has("--shared-folder"):
      sharedFolders = parseFolderSpec(v.get("--shared-folder").getStr)
  else:
    echo ""
    while true:
      let hostPath = prompt("Shared folder path (empty to skip)")
      if hostPath.len == 0: break
      let mountTag = prompt("Mount tag in guest")
      if mountTag.len == 0:
        displayWarning("Skipping shared folder with empty tag")
        continue
      sharedFolders.add SharedFolder(host: hostPath, tag: mountTag)

  let content = spinozafileTemplate % [
    box.name, name, if isContainer: "container" else: "vm", memory, cpus,
    netMode, sshUser,
    if sshPass.len > 0: sshPass else: defaultSshPassword,
    renderFolders(sharedFolders)
  ]

  writeFile(configFile, content)
  displaySuccess("Spinozafile created in " & getCurrentDir())
  if scripted:
    echo "box: " & box.name & "  name: " & name
    echo "Next: spinoza up"
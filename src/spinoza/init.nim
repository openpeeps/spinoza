# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, strutils]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ./config

const
  spinozafileTemplate = """box: $1
name: $2
memory: $3
cpus: $4
network:
  subnet: $5
ssh_config:
  port: $6
  user: $7
  password: $8
$9"""

proc initCommand*(v: Values) =
  ## Create a Spinozafile in the current directory
  let configFile = getCurrentDir() / "Spinozafile"
  if fileExists(configFile):
    displayError("Spinozafile already exists in " & getCurrentDir())
    return

  displayInfo("Initializing new Spinozafile...")
  echo ""

  let box = prompt("Box image name", default = "debian-11")
  let name = prompt("VM name", default = "my-vm")
  let memory = prompt("Memory (MB)", default = "2048")

  # Validate memory before proceeding
  let memVal = parseInt(memory)
  if memVal < 1024:
    displayError("Memory must be at least 1024 MB (1 GB). Got: " & memory & " MB")
    return
  let hostRam = getHostRamMB()
  if hostRam > 0 and memVal > hostRam:
    displayError("Memory " & memory & " MB exceeds host RAM (" & $hostRam & " MB)")
    return
  if hostRam > 0 and memVal > int(hostRam.float * 0.70):
    displayWarning("Memory " & memory & " MB uses more than 70% of host RAM (" & $hostRam & " MB)")

  let cpus = prompt("CPUs", default = "2")
  let subnet = prompt("Network subnet", default = "192.168.122")
  let sshPort = prompt("SSH port", default = "2222")
  let sshUser = prompt("SSH user", default = "vagrant")
  let sshPass = promptSecret("SSH password")

  # Shared folders (optional, loop until empty)
  echo ""
  var sharedFoldersBlock = ""
  var sharedFolders: seq[SharedFolder]
  while true:
    let hostPath = prompt("Shared folder path (empty to skip)")
    if hostPath.len == 0: break
    let mountTag = prompt("Mount tag in guest")
    if mountTag.len == 0:
      displayWarning("Skipping shared folder with empty tag")
      continue
    sharedFolders.add SharedFolder(host: hostPath, tag: mountTag)
    sharedFoldersBlock.add "  - host: " & hostPath & "\n    tag: " & mountTag & "\n"

  var sharedSection = ""
  if sharedFolders.len > 0:
    sharedSection = "shared_folders:\n" & sharedFoldersBlock

  let content = spinozafileTemplate % [
    box, name, memory, cpus, subnet, sshPort, sshUser,
    if sshPass.len > 0: sshPass else: "vagrant",
    sharedSection
  ]

  writeFile(configFile, content)
  displaySuccess("Spinozafile created in " & getCurrentDir())

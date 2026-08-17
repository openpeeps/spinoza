# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, strutils]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

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
"""

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
  let cpus = prompt("CPUs", default = "2")
  let subnet = prompt("Network subnet", default = "192.168.122")
  let sshPort = prompt("SSH port", default = "2222")
  let sshUser = prompt("SSH user", default = "vagrant")
  let sshPass = promptSecret("SSH password")

  let content = spinozafileTemplate % [
    box, name, memory, cpus, subnet, sshPort, sshUser,
    if sshPass.len > 0: sshPass else: "vagrant"
  ]

  writeFile(configFile, content)
  displaySuccess("Spinozafile created in " & getCurrentDir())

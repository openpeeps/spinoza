# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts
import std/[options, os]

import ./spinoza/config
import ./spinoza/paths
import ./spinoza/store
import ./spinoza/vm as vmModule
import ./spinoza/ssh as sshModule
import ./spinoza/box as boxModule
import ./spinoza/init as initModule
import ./spinoza/logs as logsModule
import ./spinoza/provision as provisionModule

proc initSpinoza() =
  initFs()
  openStore()

proc loadVmConfig(): SpinozaConfig =
  initSpinoza()
  let config = findAndLoadConfig()
  validateConfig(config)
  config

proc loadVmState(name: string): VmState =
  initSpinoza()
  let state = loadVm(name)
  if state.isNone:
    raise newException(IOError, "VM not found: " & name)
  state.get()

proc initCommand*(v: Values) =
  initModule.initCommand(v)

proc upCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  let provision = v.has("--provision")
  if vmName.len > 0:
    if provision:
      displayWarning("--provision with a named VM requires a Spinozafile in the current directory; skipping")
    let state = loadVmState(vmName)
    vmModule.upFromStore(state)
  else:
    let config = loadVmConfig()
    vmModule.up(config, provision)

proc haltCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  let force = v.has("--force")
  if vmName.len > 0:
    let state = loadVmState(vmName)
    vmModule.haltFromStore(state, force)
  else:
    let config = loadVmConfig()
    vmModule.halt(config, force)

proc destroyCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  if vmName.len > 0:
    let state = loadVmState(vmName)
    removeVm(state.name)
    echo state.name & ": destroyed"
  else:
    let config = loadVmConfig()
    vmModule.destroy(config)

proc sshCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  if vmName.len > 0:
    let state = loadVmState(vmName)
    sshModule.sshFromStore(state)
  else:
    let config = loadVmConfig()
    sshModule.ssh(config)

proc logsCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  if vmName.len > 0:
    discard loadVmState(vmName)
    logsModule.tail(vmLogPath(vmName))
  elif fileExists(findConfig()):
    let config = findAndLoadConfig()
    logsModule.tail(vmLogPath(config.name))
  else:
    displayError("No VM specified and no Spinozafile found")

proc statusCommand*(v: Values) =
  initSpinoza()
  let vms = listVms()
  if vms.len == 0:
    echo "No VMs registered"
  else:
    for state in vms:
      echo state.name & " (" & state.uuid[0..7] & "): " & state.status

proc boxAddCommand*(v: Values) =
  initSpinoza()
  let url = v.get("url").getStr
  boxModule.addBox(url)

proc boxRemoveCommand*(v: Values) =
  initSpinoza()
  let name = v.get("name").getStr
  boxModule.removeBox(name)

proc boxListCommand*(v: Values) =
  initSpinoza()
  boxModule.listBoxes()

proc reloadCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  let provision = v.has("--provision")
  if vmName.len > 0:
    if provision:
      displayWarning("--provision with a named VM requires a Spinozafile in the current directory; skipping")
    let state = loadVmState(vmName)
    vmModule.reloadFromStore(state)
  else:
    let config = loadVmConfig()
    vmModule.reload(config, provision)

proc provisionCommand*(v: Values) =
  initSpinoza()
  var state: VmState
  if v.has("vmName"):
    state = loadVmState(v.get("vmName").getStr)
  elif fileExists(findConfig()):
    state = loadVmState(findAndLoadConfig().name)
  else:
    raise newException(IOError, "No VM specified and no Spinozafile found")
  if state.status != "running":
    raise newException(IOError, state.name & " is not running (" & state.status & ")")
  # Provisioners always come from the Spinozafile next to the project
  let config = findAndLoadConfig()
  provisionModule.provisionRunning(state, config)

proc suspendCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  if vmName.len > 0:
    let state = loadVmState(vmName)
    vmModule.suspendFromStore(state)
  else:
    let config = loadVmConfig()
    vmModule.suspend(config)

proc resumeCommand*(v: Values) =
  initSpinoza()
  let vmName =
    if v.has("vmName"): v.get("vmName").getStr
    else: ""
  if vmName.len > 0:
    let state = loadVmState(vmName)
    vmModule.resumeFromStore(state)
  else:
    let config = loadVmConfig()
    vmModule.resume(config)

when isMainModule:
  import pkg/kapsis

  initKapsis do:
    commands:
      -- "Setup"
      init:
        ## Create a Spinozafile in the current directory

      -- "Virtual Machines"
      up ?string(vmName), ?bool("--provision"):
        ## Boot a VM from the Spinozafile (or named VM from registry)
      halt ?string(vmName), ?bool("--force"):
        ## Gracefully shut down the running VM
      reload ?string(vmName), ?bool("--provision"):
        ## Reload VM config and restart
      provision ?string(vmName):
        ## Run provisioners against a running VM
      destroy ?string(vmName):
        ## Destroy the VM and remove its definition
      suspend ?string(vmName):
        ## Suspend a running VM (pause in RAM)
      resume ?string(vmName):
        ## Resume a suspended VM
      ssh ?string(vmName):
        ## Connect to the VM via SSH
      logs ?string(vmName):
        ## Stream the VM console log (live)
      status:
        ## List all managed VMs and their state

      -- "Box Management"
      box:
        ## Manage libvirt box images
        add string(url):
          ## Download and add a box image
        remove string(name):
          ## Remove a box image
        list:
          ## List available box images

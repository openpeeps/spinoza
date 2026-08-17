# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import pkg/kapsis/runtime

import ./spinoza/config
import ./spinoza/paths
import ./spinoza/vm as vmModule
import ./spinoza/ssh as sshModule
import ./spinoza/box as boxModule

proc initSpinoza() =
  initFs()

proc loadVmConfig(): SpinozaConfig =
  initSpinoza()
  findAndLoadConfig()

proc upCommand*(v: Values) =
  let config = loadVmConfig()
  vmModule.up(config)

proc haltCommand*(v: Values) =
  let config = loadVmConfig()
  let force = v.has("--force")
  vmModule.halt(config, force)

proc destroyCommand*(v: Values) =
  let config = loadVmConfig()
  vmModule.destroy(config)

proc sshCommand*(v: Values) =
  let config = loadVmConfig()
  sshModule.ssh(config)

proc statusCommand*(v: Values) =
  let config = loadVmConfig()
  vmModule.status(config)

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

when isMainModule:
  import pkg/kapsis

  initKapsis do:
    commands:
      -- "Virtual Machines"
      up:
        ## Boot a VM from the Spinozafile
      halt ?bool("--force"):
        ## Gracefully shut down the running VM
      destroy:
        ## Destroy the VM and remove its definition
      ssh:
        ## Connect to the VM via SSH
      status:
        ## List all managed VMs

      -- "Box Management"
      box:
        ## Manage libvirt box images
        add string(url):
          ## Download and add a box image
        remove string(name):
          ## Remove a box image
        list:
          ## List available box images

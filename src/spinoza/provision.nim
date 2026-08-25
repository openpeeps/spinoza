# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import os, strutils

import pkg/kapsis/interactive/spinny

import ./config
import ./paths
import ./ssh as sshModule
import ./store

proc runProvisions*(spinny: ptr Spinny, host: string, port: int,
                    user, pass: string,
                    cmds: seq[string], scripts: seq[string]): bool =
  ## Run inline provision commands and local provision scripts against a
  ## running VM, streaming their output above the spinner. Stops at the
  ## first failing step. Returns true when every step succeeded.
  let total = cmds.len + scripts.len
  if total == 0:
    spinny[].log("nothing to provision")
    return true

  var step = 0
  proc onLine(line: string) =
    spinny[].log(line)

  for cmd in cmds:
    inc(step)
    spinny[].setText("[" & $step & "/" & $total & "] " & cmd)
    let (output, code) = sshModule.sshExecStream(
      host, port, user, pass, cmd, onLine = onLine)
    if code != 0:
      spinny[].error("Provisioning failed (exit " & $code & "): " & cmd &
        "\n" & output.strip())
      quit(1)
      return false

  for script in scripts:
    inc(step)
    let label = "[" & $step & "/" & $total & "] bash -s < " &
      script.lastPathPart()
    spinny[].setText(label)
    if not fileExists(script):
      spinny[].error("Provision script not found: " & script)
      quit(1)
      return false
    let content = readFile(script)
    let (output, code) = sshModule.sshExecStream(
      host, port, user, pass, "bash -s", stdinPayload = content,
      onLine = onLine)
    if code != 0:
      spinny[].error("Provisioning script failed (exit " & $code & "): " &
        script & "\n" & output.strip())
      quit(1)
      return false

  true

proc provisionRunning*(state: VmState, config: SpinozaConfig) =
  ## Run configured provisioners against an already-running VM.
  var spinny = newSpinny("Provisioning " & state.name & "...", "dots",
    time = true)
  spinny.start()
  let ok = runProvisions(addr spinny, state.sshHost, state.sshPort,
    state.sshUser, state.sshPass, config.provision, config.provision_script)
  if ok:
    spinny.success(state.name & " provisioned")

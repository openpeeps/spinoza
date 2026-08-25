# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[json, options, strutils]
import boogie/stores/kv
import pkg/openparser/uuid

import ./paths
import ./config

type
  VmState* = object
    uuid*: string
    box*: string
    name*: string
    memory*: int
    cpus*: int
    netMode*: string
    sshHost*: string
    sshPort*: int
    sshUser*: string
    sshPass*: string
    sharedFolders*: seq[SharedFolder]
    status*: string

var store*: KvStore

proc openStore*() =
  let dbPath = vmDbPath()
  store = newKvStore(dbPath, ksmDisk, enableWal = true)

proc closeStore*() =
  if store != nil:
    store.close()

proc vmKey*(name: string): string = "vm:" & name

proc newVmUuid*(): string =
  $v4()

proc saveVm*(state: VmState) =
  var folders: JsonNode
  if state.sharedFolders.len > 0:
    var arr = newJArray()
    for f in state.sharedFolders:
      arr.add(%*{"host": f.host, "tag": f.tag})
    folders = arr
  else:
    folders = newJArray()
  let data = $(%*{
    "uuid": state.uuid,
    "box": state.box,
    "name": state.name,
    "memory": state.memory,
    "cpus": state.cpus,
    "net_mode": state.netMode,
    "ssh_host": state.sshHost,
    "ssh_port": state.sshPort,
    "ssh_user": state.sshUser,
    "ssh_pass": state.sshPass,
    "shared_folders": folders,
    "status": state.status
  })
  store.put(vmKey(state.name), data)

proc loadVm*(name: string): Option[VmState] =
  let raw = store.get(vmKey(name))
  if raw.isNone:
    return none(VmState)
  let node = parseJson(raw.get())
  var folders: seq[SharedFolder]
  if node.hasKey("shared_folders"):
    for f in node["shared_folders"]:
      folders.add SharedFolder(
        host: f["host"].getStr,
        tag: f["tag"].getStr)
  some(VmState(
    uuid: node["uuid"].getStr,
    box: node["box"].getStr,
    name: node["name"].getStr,
    memory: node["memory"].getInt.int,
    cpus: node["cpus"].getInt.int,
    netMode: node{"net_mode"}.getStr("user"),
    sshHost: node{"ssh_host"}.getStr("127.0.0.1"),
    sshPort: node{"ssh_port"}.getInt(22).int,
    sshUser: node["ssh_user"].getStr,
    sshPass: node["ssh_pass"].getStr,
    sharedFolders: folders,
    status: node["status"].getStr
  ))

proc removeVm*(name: string) =
  discard store.delete(vmKey(name))

proc listVms*(): seq[VmState] =
  for k, v in store.pairsUnordered:
    if k.startsWith("vm:"):
      let node = parseJson(v)
      var folders: seq[SharedFolder]
      if node.hasKey("shared_folders"):
        for f in node["shared_folders"]:
          folders.add SharedFolder(
            host: f["host"].getStr,
            tag: f["tag"].getStr)
      result.add VmState(
        uuid: node["uuid"].getStr,
        box: node["box"].getStr,
        name: node["name"].getStr,
        memory: node["memory"].getInt.int,
        cpus: node["cpus"].getInt.int,
        netMode: node{"net_mode"}.getStr("user"),
        sshHost: node{"ssh_host"}.getStr("127.0.0.1"),
        sshPort: node{"ssh_port"}.getInt(22).int,
        sshUser: node["ssh_user"].getStr,
        sshPass: node["ssh_pass"].getStr,
        sharedFolders: folders,
        status: node["status"].getStr
      )

proc hasVm*(name: string): bool =
  store.hasKey(vmKey(name))

proc updateStatus*(name: string, status: string) =
  let state = loadVm(name)
  if state.isSome:
    var updated = state.get()
    updated.status = status
    saveVm(updated)

proc updateEndpoint*(name: string, host: string, port: int) =
  ## Persist the SSH endpoint (used after vmnet IP discovery).
  let state = loadVm(name)
  if state.isSome:
    var updated = state.get()
    updated.sshHost = host
    updated.sshPort = port
    saveVm(updated)

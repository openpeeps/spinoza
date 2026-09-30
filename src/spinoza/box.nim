# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[algorithm, httpclient, os, strutils]
import pkg/kapsis/interactive/prompts
import flysystem

import ./paths

type
  BoxKind* = enum
    bkQemu, bkContainer

  BoxInfo* = object
    name*: string
    kind*: BoxKind

proc isLocalPath*(input: string): bool =
  input.startsWith("/") or input.startsWith("./") or
  input.startsWith("../") or input.startsWith("~/")

proc addBox*(source: string) =
  let name = source.extractFilename().splitFile().name
  let dest = boxPath(name)
  let disk = fs.disk("boxes")
  if disk.exists(dest):
    displayWarning("Box already exists: " & name)
    return
  let content =
    if isLocalPath(source):
      let resolved = source.expandTilde().expandFilename()
      if not fileExists(resolved):
        displayError("File not found: " & resolved, quitProcess = true)
        return
      readFile(resolved)
    else:
      displayInfo("Downloading " & name & "...")
      let client = newHttpClient()
      let tmpFile = getTempDir() / (name & ".img")
      client.downloadFile(source, tmpFile)
      let data = readFile(tmpFile)
      removeFile(tmpFile)
      data
  disk.write(dest, content)
  displaySuccess("Added box: " & name)

proc removeBox*(name: string) =
  let disk = fs.disk("boxes")
  let path = boxPath(name)
  if not disk.exists(path):
    displayError("Box not found: " & name, quitProcess = true)
    return
  disk.delete(path)
  displaySuccess("Removed box: " & name)

proc availableBoxes*(): seq[BoxInfo] =
  ## Installed boxes, sorted by name. QEMU boxes are `*.img` images,
  ## container boxes are directories holding a `rootfs/`.
  let disk = fs.disk("boxes")
  for entry in disk.list("."):
    let name = entry.path.splitFile().name
    if entry.isDir:
      when defined(linux):
        if disk.exists(containerBaseRootfs(name)):
          result.add BoxInfo(name: name, kind: bkContainer)
    elif entry.path.endsWith(".img"):
      result.add BoxInfo(name: name, kind: bkQemu)
  result.sort(proc (a, b: BoxInfo): int = cmp(a.name, b.name))

proc listBoxes*() =
  let boxes = availableBoxes()
  if boxes.len == 0:
    displayInfo("No boxes installed")
    return
  for box in boxes:
    let kind = case box.kind
      of bkQemu: ""
      of bkContainer: " (container)"
    echo box.name & kind

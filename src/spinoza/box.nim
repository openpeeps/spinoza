# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[httpclient, os, strutils]
import pkg/kapsis/interactive/prompts
import flysystem

import ./paths

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

proc listBoxes*() =
  let disk = fs.disk("boxes")
  let entries = disk.list(".")
  var found = false
  for entry in entries:
    if entry.path.endsWith(".img") and not entry.isDir:
      echo entry.path.splitFile().name
      found = true
  if not found:
    displayInfo("No boxes installed")

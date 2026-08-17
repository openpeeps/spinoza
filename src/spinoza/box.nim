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

proc addBox*(url: string) =
  let name = url.extractFilename().splitFile().name
  let dest = boxPath(name)
  let disk = fs.disk("boxes")
  if disk.exists(dest):
    displayWarning("Box already exists: " & name)
    return
  displayInfo("Downloading " & name & "...")
  let client = newHttpClient()
  let tmpFile = getTempDir() / (name & ".img")
  client.downloadFile(url, tmpFile)
  let content = readFile(tmpFile)
  disk.write(dest, content)
  removeFile(tmpFile)
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

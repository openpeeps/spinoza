# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, times]
import pkg/kapsis/interactive/prompts

proc pumpLog*(path: string, f: var File, pos: var int): string =
  ## Incrementally return bytes appended to `path` since the previous call.
  ## Lazily opens the file (starting at its current end); returns "" when
  ## nothing new. Survives truncation/recreation between boots.
  ## For qemu:///system PTY consoles, the file is user-owned via stream thread (Option A).
  if f.isNil:
    if not fileExists(path):
      return ""
    try:
      f = open(path, fmRead)
    except IOError:
      return ""
    pos = f.getFileSize()
    return ""
  let size = f.getFileSize()
  if size > pos:
    f.setFilePos(pos)
    result = f.readAll()
    pos = f.getFilePos()
  elif size < pos:
    # Truncated or recreated (fresh boot): rewind
    f.setFilePos(0)
    pos = 0

proc tail*(path: string) =
  ## Stream a VM console log: print existing content, then follow
  ## appends until interrupted (Ctrl-C).
  var f: File
  if fileExists(path):
    stdout.write(readFile(path))
    flushFile(stdout)
  else:
    displayInfo("Waiting for console output (" & path & ") ...")

  while not fileExists(path):
    sleep(250)

  f = open(path, fmRead)
  defer: f.close()
  var pos = f.getFileSize()

  while true:
    let size = f.getFileSize()
    if size > pos:
      f.setFilePos(pos)
      stdout.write(f.readAll())
      flushFile(stdout)
      pos = f.getFilePos()
    elif size < pos:
      # Log was truncated or recreated (fresh boot)
      f.close()
      f = open(path, fmRead)
      pos = 0
    sleep(300)

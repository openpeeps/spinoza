# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, osproc, strutils, times]
import libvirt

proc networkXml*(subnet: string): string =
  "<network>\n" &
  "  <name>spinoza-" & subnet & "</name>\n" &
  "  <bridge name='virbr-spinoza' stp='on' delay='0'/>\n" &
  "  <ip address='" & subnet & ".1' netmask='255.255.255.0'>\n" &
  "    <dhcp>\n" &
  "      <range start='" & subnet & ".100' end='" & subnet & ".200'/>\n" &
  "    </dhcp>\n" &
  "  </ip>\n" &
  "</network>"

proc networkName*(subnet: string): string =
  "spinoza-" & subnet

proc ensureNetwork*(conn: Connect, subnet: string): Network =
  let name = networkName(subnet)
  try:
    result = conn.lookupNetworkByName(name)
    if not result.isActive:
      result.create
  except LibvirtError:
    result = conn.defineNetworkXML(networkXml(subnet))
    result.create

proc deriveMac*(uuid: string): string =
  ## Deterministic QEMU-conventional MAC address derived from a UUID.
  ## Same UUID always yields the same MAC, enabling ARP matching and
  ## /etc/bootptab DHCP reservations.
  var hex = uuid.replace("-", "")
  while hex.len < 6:
    hex = "0" & hex
  let tail = hex[^6 .. ^1]
  result = "52:54:00:" & tail[0 .. 1] & ":" & tail[2 .. 3] & ":" & tail[4 .. 5]

proc normalizeMac*(m: string): string =
  ## Canonical form for comparison: lowercase, leading zeros stripped per
  ## octet ("52:54:00:0a:1b:2c" == macOS arp's "52:54:0:a:1b:2c").
  let parts = m.toLowerAscii().split(":")
  result = ""
  for i in 0 ..< parts.len:
    var o = parts[i]
    while o.len > 1 and o[0] == '0':
      o = o[1 .. ^1]
    if i > 0:
      result.add ":"
    result.add o

proc extractArpMac(line: string): string =
  ## Pull the MAC out of an `arp -an` line: "... at de:ad:be:ef:00:01 on ..."
  let marker = line.find(" at ")
  if marker < 0:
    return ""
  let rest = line[marker + 4 .. ^1]
  let endIdx = rest.find(" ")
  if endIdx <= 0:
    return ""
  rest[0 ..< endIdx]

proc discoverVmIp*(mac: string, timeoutSec = 150): string =
  ## Poll the host ARP table until an entry for `mac` shows up (the guest
  ## announcing itself on the vmnet bridge), and return its IPv4 address.
  ## Returns "" on timeout.
  let deadline = now() + initDuration(seconds = timeoutSec)
  let wantMac = normalizeMac(mac)
  while now() < deadline:
    let outp = execProcess("arp -an")
    for line in outp.splitLines():
      let seenMac = extractArpMac(line)
      if seenMac.len > 0 and normalizeMac(seenMac) == wantMac:
        # macOS format: ? (192.168.105.123) at de:ad:be:ef:00:01 on bridge100 ...
        let startIdx = line.find("(")
        let endIdx = line.find(")")
        if startIdx >= 0 and endIdx > startIdx:
          return line[startIdx + 1 ..< endIdx]
    sleep(1000)
  return ""

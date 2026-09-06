# Spinoza – Spin up VMs like a PRO. A VM manager
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[os, osproc, strutils, times]
import libvirt

# ------------------------------------------------------------------
# Subnet and network name mapping
# ------------------------------------------------------------------

const
  subnetShared* = "192.168.124"
  subnetHost* = "192.168.125"

proc getNetworkSubnet*(mode: string): string =
  ## Map a network mode to its default subnet prefix.
  case mode
  of "shared": subnetShared
  of "host": subnetHost
  else: ""

proc networkName*(subnet: string): string =
  "spinoza-" & subnet

proc bridgeName*(mode: string): string =
  ## Per-mode kernel bridge device name (IFNAMSIZ ≤ 15).
  case mode
  of "shared": "spz-shared"
  of "host": "spz-host"
  else: "virbr-spinoza"

# ------------------------------------------------------------------
# Libvirt network XML
# ------------------------------------------------------------------

proc networkXml*(subnet: string, forwardMode = "nat"): string =
  ## Build libvirt <network> XML. `forwardMode` is "nat" (shared) or
  ## omitted for isolated (host-only). Omitting <forward> entirely
  ## gives an isolated bridge with no internet.
  var xml = "<network>\n"
  xml.add "  <name>" & networkName(subnet) & "</name>\n"
  xml.add "  <bridge name='" & bridgeName(
    if forwardMode == "nat": "shared" else: "host"
  ) & "' stp='on' delay='0'/>\n"
  if forwardMode == "nat":
    xml.add "  <forward mode='nat'/>\n"
  xml.add "  <ip address='" & subnet & ".1' netmask='255.255.255.0'>\n"
  xml.add "    <dhcp>\n"
  xml.add "      <range start='" & subnet & ".100' end='" & subnet & ".200'/>\n"
  xml.add "    </dhcp>\n"
  xml.add "  </ip>\n"
  xml.add "</network>"
  xml

proc ensureNetwork*(conn: Connect, subnet: string,
                    forwardMode = "nat"): Network =
  ## Idempotent: look up or define+create the libvirt network.
  let name = networkName(subnet)
  try:
    result = conn.lookupNetworkByName(name)
    if not result.isActive:
      result.create
  except LibvirtError:
    result = conn.defineNetworkXML(networkXml(subnet, forwardMode))
    result.create

# ------------------------------------------------------------------
# MAC helpers
# ------------------------------------------------------------------

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

# ------------------------------------------------------------------
# macOS IP discovery (arp -an)
# ------------------------------------------------------------------

when defined(macosx):
  proc extractArpMac(line: string): string =
    let marker = line.find(" at ")
    if marker < 0:
      return ""
    let rest = line[marker + 4 .. ^1]
    let endIdx = rest.find(" ")
    if endIdx <= 0:
      return ""
    rest[0 ..< endIdx]

  proc discoverVmIp*(mac: string, timeoutSec = 150): string =
    ## Poll the host ARP table until an entry for `mac` shows up.
    let deadline = now() + initDuration(seconds = timeoutSec)
    let wantMac = normalizeMac(mac)
    while now() < deadline:
      let outp = execProcess("arp -an")
      for line in outp.splitLines():
        let seenMac = extractArpMac(line)
        if seenMac.len > 0 and normalizeMac(seenMac) == wantMac:
          let startIdx = line.find("(")
          let endIdx = line.find(")")
          if startIdx >= 0 and endIdx > startIdx:
            return line[startIdx + 1 ..< endIdx]
      sleep(1000)
    return ""

# ------------------------------------------------------------------
# Linux IP discovery (ip neigh)
# ------------------------------------------------------------------

when defined(linux):
  proc parseIpNeigh(line: string): tuple[mac, ip: string] =
    ## Parse one line of `ip neigh` output.
    ## Format: "192.168.124.100 dev virbr-spinoza-shared lladdr 52:54:00:xx:yy:zz REACHABLE"
    ## or:     "192.168.124.100 dev virbr-spinoza-shared 52:54:00:xx:yy:zz REACHABLE"
    let parts = line.split()
    if parts.len < 4:
      return
    result.ip = parts[0]
    # Find "lladdr" keyword or treat the field after dev+name as MAC
    var macIdx = -1
    for i, p in parts:
      if p == "lladdr":
        macIdx = i + 1
        break
    if macIdx < 0 and parts.len >= 5:
      # No "lladdr" keyword — MAC is right after the interface name
      # "192.168.124.100 dev virbr 52:54:00:xx:yy:zz REACHABLE"
      macIdx = 3  # after IP + "dev" + ifname
    if macIdx >= 0 and macIdx < parts.len:
      result.mac = parts[macIdx]

  proc discoverVmIp*(mac: string, timeoutSec = 150): string =
    ## Poll `ip neigh` until an entry for `mac` appears.
    let deadline = now() + initDuration(seconds = timeoutSec)
    let wantMac = normalizeMac(mac)
    while now() < deadline:
      let outp = execProcess("ip neigh")
      for line in outp.splitLines():
        let (seenMac, ip) = parseIpNeigh(line)
        if seenMac.len > 0 and normalizeMac(seenMac) == wantMac and ip.len > 0:
          return ip
      sleep(1000)
    return ""

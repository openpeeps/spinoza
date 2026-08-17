# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

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

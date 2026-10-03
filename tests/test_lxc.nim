import unittest
import std/[os, strutils]
import pkg/openparser/yaml
import spinoza/config
import spinoza/store
import spinoza/paths

initFs()

const containerYaml = """
box: debian12
name: web
type: container
memory: 1024
cpus: 2
network:
  mode: shared
ssh_config:
  user: vagrant
  password: vagrant
"""

const vmYaml = """
box: debian12
name: web
memory: 2048
cpus: 2
network:
  mode: shared
ssh_config:
  user: vagrant
  password: vagrant
"""

suite "backend selection (type field)":
  test "type omitted defaults to vm":
    let c = parseYAML(vmYaml, SpinozaConfig)
    check c.vmKind() == "vm"
    check not c.isContainer

  test "type container parses":
    let c = parseYAML(containerYaml, SpinozaConfig)
    check c.vmKind() == "container"
    check c.isContainer

  test "invalid type rejected":
    var c = parseYAML(vmYaml, SpinozaConfig)
    c.`type` = "docker"
    expect ValueError:
      validateConfig(c)

  test "container with user networking rejected":
    var c = parseYAML(containerYaml, SpinozaConfig)
    c.network.mode = "user"
    expect ValueError:
      validateConfig(c)

  test "container with shared networking validates":
    let c = parseYAML(containerYaml, SpinozaConfig)
    validateConfig(c)

suite "VmState driver":
  test "driver defaults to qemu":
    var s = VmState(name: "x", status: "running")
    check not s.isContainer

  test "lxc driver detected":
    var s = VmState(name: "x", driver: "lxc", status: "running")
    check s.isContainer

when defined(linux):
  import spinoza/vm

  suite "lxc domain xml":
    test "container xml shape":
      let c = parseYAML(containerYaml, SpinozaConfig)
      let xml = lxcDomainXmlFromConfig(c, "/home/u/.spinoza/boxes/debian12/rootfs",
        "11111111-2222-3333-4444-555555555555")
      check "type='lxc'" in xml or "type=\"lxc\"" in xml
      check "<init>/sbin/init</init>" in xml
      check "exe" in xml
      check "/home/u/.spinoza/boxes/debian12/rootfs" in xml
      check "<emulator>" notin xml
      check "<disk" notin xml
      check "qemu:commandline" notin xml
      check "spinoza-192.168.124" in xml
      check "console" in xml

    test "shared folders become bind mounts":
      var c = parseYAML(containerYaml, SpinozaConfig)
      c.shared_folders = @[SharedFolder(host: "/home/u/proj", tag: "project")]
      let xml = lxcDomainXmlFromConfig(c, "/rootfs", "11111111-2222-3333-4444-555555555555")
      check "/home/u/proj" in xml
      check "/mnt/project" in xml

    test "connection routing":
      check connectionUriFor("lxc", "shared") == "lxc:///system"
      check connectionUriFor("qemu", "shared") == "qemu:///system"
      check connectionUriFor("qemu", "user") == "qemu:///session"

    test "container rootfs path layout":
      check containerBaseRootfs("debian12").endsWith("boxes/debian12/rootfs")
      check containerRootfsPath("web", "debian12").endsWith("web-debian12-rootfs")

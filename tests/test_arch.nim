import std/strutils
import unittest
import spinoza/config
import spinoza/vm
import spinoza/store

suite "guest arch":
  test "arch defaults to x86_64":
    let c = SpinozaConfig(box: "debian12", name: "web", memory: 2048, cpus: 2)
    check c.archNorm() == "x86_64"
    check not c.isArm()

  test "aarch64 and arm64 alias":
    var c = SpinozaConfig(box: "generic_debian12_arm", name: "arm",
      arch: "aarch64", memory: 2048, cpus: 2)
    check c.archNorm() == "aarch64"
    check c.isArm()
    c.arch = "arm64"
    check c.archNorm() == "aarch64"

  test "invalid arch rejected":
    var c = SpinozaConfig(box: "b", name: "n", arch: "riscv",
      memory: 2048, cpus: 2)
    expect ValueError:
      validateConfig(c)

  test "x86_64 domain XML unchanged":
    let c = SpinozaConfig(box: "debian12", name: "web", memory: 2048, cpus: 2,
      network: NetworkConfig(mode: "user"),
      ssh_config: SshConfig(user: "vagrant", password: "vagrant"))
    let xml = domainXml(c, "/boxes/debian12.img", "11111111-2222-3333-4444-555555555555", 2222)
    check "arch=\"x86_64\"" in xml
    check "machine=\"pc\"" in xml
    check "<loader>" notin xml
    check "<cpu>" notin xml
    check "qemu-tcg.sh" in xml

  test "aarch64 domain XML uses virt machine, UEFI, cortex-a57":
    let c = SpinozaConfig(box: "generic_debian12_arm", name: "arm",
      arch: "aarch64", memory: 2048, cpus: 2,
      network: NetworkConfig(mode: "user"),
      ssh_config: SshConfig(user: "vagrant", password: "vagrant"))
    let xml = domainXml(c, "/boxes/generic_debian12_arm.img", "11111111-2222-3333-4444-555555555555", 2222)
    check "arch=\"aarch64\"" in xml
    check "machine=\"virt\"" in xml
    check "edk2-aarch64-code.fd" in xml
    check "cortex-a57" in xml
    check "qemu-tcg-aarch64.sh" in xml

  test "VmState arch round-trips with x86_64 default":
    var s = VmState(uuid: "u", box: "b", name: "n", driver: "qemu",
      memory: 2048, cpus: 2)
    check s.archNorm() == "x86_64"
    check not s.isArm()
    s.arch = "aarch64"
    check s.isArm()

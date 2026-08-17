import unittest
import spinoza/config

test "SpinozaConfig defaults":
  let config = SpinozaConfig(
    box: "debian-11",
    name: "test",
    memory: 2048,
    cpus: 2,
    network: NetworkConfig(subnet: "192.168.123"),
    ssh_config: SshConfig(port: 2222, user: "vagrant", password: "vagrant")
  )
  check config.box == "debian-11"
  check config.memory == 2048
  check config.network.subnet == "192.168.123"
  check config.ssh_config.port == 2222

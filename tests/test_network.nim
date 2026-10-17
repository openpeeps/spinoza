import std/[os, strutils]
import unittest
import spinoza/network

when defined(macosx):
  import std/net

suite "macOS vmnet helpers":
  test "deriveMac is deterministic with QEMU prefix":
    let a = deriveMac("bbcf92e4-0105-4ced-badc-bbd66d5ef97d")
    check a == deriveMac("bbcf92e4-0105-4ced-badc-bbd66d5ef97d")
    check a.startsWith("52:54:00:")
    check a.split(':').len == 6
    check deriveMac("other-uuid") != a

  test "normalizeMac strips leading zeros per octet":
    check normalizeMac("52:54:00:0A:1B:2C") == "52:54:0:a:1b:2c"
    check normalizeMac("52:54:00:73:70:e2") == "52:54:0:73:70:e2"

  when defined(macosx):
    test "vmnetSocketAlive rejects a dead path":
      check not vmnetSocketAlive("/tmp/spinoza-test-no-such-socket.sock")

    test "vmnetSocketAlive accepts a live listener":
      const path = "/tmp/spinoza-test-alive.sock"
      try: removeFile(path)
      except OSError: discard
      var srv = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      srv.bindUnix(path)
      srv.listen()
      check vmnetSocketAlive(path)
      srv.close()
      removeFile(path)
      # Stale file with no listener must fail, not just exist
      writeFile(path, "")
      check not vmnetSocketAlive(path)
      removeFile(path)

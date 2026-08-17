# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "Spin up VMs like a Pro"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["spinoza"]

installDirs = @["spinoza"]


# Dependencies

requires "nim >= 2.2.10"
requires "libvirt >= 0.1.0"
requires "kapsis >= 0.4.3"
requires "openparser >= 0.1.9"
requires "flysystem >= 0.1.0"
requires "libssh2 >= 0.1.9"
requires "boogie >= 0.1.2"
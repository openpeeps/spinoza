# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[net, os, posix, termios, times, terminal]
import libssh2

import ./config

proc waitForSsh*(port: int, timeoutSec = 120): bool =
  let deadline = now() + initDuration(seconds = timeoutSec)
  while now() < deadline:
    var sock = newSocket()
    try:
      sock.connect("127.0.0.1", Port(port))
      sock.close()
      return true
    except CatchableError:
      discard
    sleep(3000)
  false

proc getTerminalSize(): (int, int) =
  result = (terminalWidth(), terminalHeight())

proc waitsocket(sockFd: SocketHandle, session: Session): cint =
  ## Wait on the SSH socket in the direction libssh2 needs.
  ## Pattern from libssh2 examples (sftp_write_nonblock.c / ssh2_echo.c).
  var fd: TFdSet
  FD_ZERO(fd)
  FD_SET(cint(sockFd), fd)

  var readFds: ptr TFdSet = nil
  var writeFds: ptr TFdSet = nil
  let dir = session.sessionBlockDirections()

  if (dir and LIBSSH2_SESSION_BLOCK_INBOUND) != 0:
    readFds = addr fd
  if (dir and LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0:
    writeFds = addr fd

  var timeout = Timeval(tv_sec: posix.Time(0), tv_usec: 50000) # 50ms
  result = select(cint(sockFd) + 1, readFds, writeFds, nil, addr timeout)

proc ssh*(config: SpinozaConfig) =
  if not waitForSsh(config.ssh_config.port):
    raise newException(IOError, "SSH on port " & $config.ssh_config.port & " never became reachable")

  let hostname = "127.0.0.1"
  let port = config.ssh_config.port
  let username = config.ssh_config.user
  let password = config.ssh_config.password

  # Initialize libssh2
  discard libssh2.init(0)
  defer: libssh2.exit()

  # Create TCP socket and connect
  var sock = newSocket()
  defer: sock.close()
  sock.connect(hostname, Port(port))
  let sockFd = sock.getFd()

  # Initialize SSH session
  var session = sessionInit()
  if session.sessionHandshake(sockFd) != 0:
    raise newException(IOError, "SSH handshake failed")
  defer:
    discard session.sessionDisconnect("bye")
    discard session.sessionFree()

  # Authenticate
  if session.userauthPassword(username, password, nil) != 0:
    raise newException(IOError, "SSH authentication failed for " & username)

  # Open channel
  var channel = session.channelOpenSession()
  if channel.isNil:
    raise newException(IOError, "Failed to open SSH channel")
  defer: discard channel.channelFree()

  # Request PTY with terminal size
  let (cols, rows) = getTerminalSize()
  if channel.channelRequestPty("xterm-256color") != 0:
    raise newException(IOError, "Failed to request PTY")
  discard channel.channelRequestPtySize(cols, rows)

  # Request shell
  if channel.channelShell() != 0:
    raise newException(IOError, "Failed to request shell")

  # Save terminal settings and switch to raw mode
  var origTerm: Termios
  discard tcGetAttr(0, addr origTerm)
  defer: discard tcSetAttr(0, TCSANOW, addr origTerm)

  var rawTerm = origTerm
  rawTerm.c_lflag = rawTerm.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  rawTerm.c_iflag = rawTerm.c_iflag and not (IXON or ICRNL or BRKINT or INLCR or IGNBRK or PARMRK or ISTRIP or IGNCR)
  rawTerm.c_oflag = rawTerm.c_oflag or OPOST
  rawTerm.c_cc[VMIN] = '\1'
  rawTerm.c_cc[VTIME] = '\0'
  discard tcSetAttr(0, TCSANOW, addr rawTerm)

  # Set channel and session to non-blocking
  channel.channelSetBlocking(0)
  session.sessionSetBlocking(0)

  # I/O loop — canonical libssh2 pattern
  var buf: array[4096, char]
  var stdinClosed = false

  while true:
    # Wait on SSH socket in the direction libssh2 needs
    discard waitsocket(sockFd, session)

    # Drain channel → stdout
    while true:
      let rc = channel.channelRead(addr buf[0], 4096)
      if rc > 0:
        discard write(1, addr buf[0], rc)
      elif rc == 0:
        # Channel EOF or closed
        return
      else:
        let err = session.sessionLastErrno()
        if err != LIBSSH2_ERROR_EAGAIN:
          return
        break

    # Read stdin → channel (POSIX poll on fd 0 only)
    if not stdinClosed:
      var stdinPoll: TPollfd
      stdinPoll.fd = cint(0)
      stdinPoll.events = POLLIN
      stdinPoll.revents = 0
      if posix.poll(addr stdinPoll, 1, 0) > 0:
        let n = read(0, addr buf[0], 4096)
        if n > 0:
          var written = 0
          while written < n:
            let rc = channel.channelWrite(cast[cstring](addr buf[written]), n - written)
            if rc > 0:
              written += rc
            elif rc == 0:
              stdinClosed = true
              break
            else:
              let err = session.sessionLastErrno()
              if err != LIBSSH2_ERROR_EAGAIN:
                stdinClosed = true
              break
        elif n == 0:
          discard channel.channelSendEof()
          stdinClosed = true

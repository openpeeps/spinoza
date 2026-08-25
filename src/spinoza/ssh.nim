# Spinoza – Spin up VMs like a PRO. A VM manager 
# written in Nim lang. Powered by libvirt, qemu and libssh.
#
# (c) 2026 George Lemon | GPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/spinoza

import std/[net, options, os, posix, termios, times, terminal]
import libssh2

import ./config
import ./store

proc setFdBlocking(fd: SocketHandle, blocking: bool) =
  let flags = fcntl(fd.cint, F_GETFL)
  if blocking:
    discard fcntl(fd.cint, F_SETFL, flags and not O_NONBLOCK)
  else:
    discard fcntl(fd.cint, F_SETFL, flags or O_NONBLOCK)

proc tryTcpConnect*(host: string, port: int, timeoutMs = 1000): Socket =
  ## Non-blocking TCP connect with a hard per-attempt timeout.
  ## Returns the connected (blocking again) socket or nil.
  var sock = newSocket()
  let fd = sock.getFd()
  setFdBlocking(fd, false)
  try:
    sock.connect(host, Port(port))
  except OSError:
    let err = osLastError()
    if err != EINPROGRESS.OSErrorCode:
      sock.close()
      return nil
    # Wait for writability within the timeout
    var wfds: TFdSet
    FD_ZERO(wfds)
    FD_SET(fd, wfds)
    var tv = Timeval(tv_sec: posix.Time(timeoutMs div 1000),
                     tv_usec: Suseconds((timeoutMs mod 1000) * 1000))
    let r = select(cint(fd) + 1, nil, addr wfds, nil, addr tv)
    if r <= 0:
      sock.close()
      return nil
    var soErr: cint
    var slen: SockLen = SockLen(sizeof(soErr))
    discard getsockopt(fd, SOL_SOCKET, SO_ERROR, addr soErr, addr slen)
    if soErr != 0:
      sock.close()
      return nil
  setFdBlocking(fd, true)
  return sock

proc probeSsh*(host: string, port: int, user, pass: string, timeoutSec = 120,
               onWait: proc(seconds: int) {.closure.} = nil): bool =
  ## Attempt an actual SSH handshake + auth to verify the VM is ready.
  ## Returns true once a full auth succeeds, false on timeout.
  ## `onWait` fires after each failed attempt with elapsed seconds.
  discard libssh2.init(0)
  defer: libssh2.exit()

  let start = now()
  let deadline = start + initDuration(seconds = timeoutSec)
  while now() < deadline:
    var sock = tryTcpConnect(host, port)
    if sock != nil:
      let sockFd = sock.getFd()

      var session = sessionInit()
      if session.sessionHandshake(sockFd) == 0:
        if session.userauthPassword(user, pass, nil) == 0:
          discard session.sessionDisconnect("probe")
          discard session.sessionFree()
          sock.close()
          return true
        discard session.sessionDisconnect("probe")
        discard session.sessionFree()

      sock.close()
    if onWait != nil:
      onWait((now() - start).inSeconds.int)
    sleep(500)
  false

proc sshExec*(host: string, port: int, user, pass, cmd: string): string =
  ## Execute a command via SSH and return stdout. Non-interactive.
  discard libssh2.init(0)
  defer: libssh2.exit()

  var sock = newSocket()
  defer: sock.close()
  sock.connect(host, Port(port))
  let sockFd = sock.getFd()

  var session = sessionInit()
  if session.sessionHandshake(sockFd) != 0:
    raise newException(IOError, "SSH handshake failed")
  defer:
    discard session.sessionDisconnect("bye")
    discard session.sessionFree()

  if session.userauthPassword(user, pass, nil) != 0:
    raise newException(IOError, "SSH authentication failed for " & user)

  var channel = session.channelOpenSession()
  if channel.isNil:
    raise newException(IOError, "Failed to open SSH channel")
  defer: discard channel.channelFree()

  if channel.channelExec(cmd) != 0:
    raise newException(IOError, "Failed to exec command: " & cmd)

  var buf: array[4096, char]
  var output = ""
  while true:
    let rc = channel.channelRead(addr buf[0], 4096)
    if rc > 0:
      output.add(cast[cstring](addr buf[0]))
    elif rc == 0:
      break
    else:
      let err = session.sessionLastErrno()
      if err != LIBSSH2_ERROR_EAGAIN:
        break

  discard channel.channelSendEof()
  output

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

proc sshFromStore*(state: VmState) =
  let hostname = state.sshHost
  let port = state.sshPort
  let username = state.sshUser
  let password = state.sshPass
  if hostname.len == 0:
    raise newException(IOError,
      "SSH endpoint unknown for '" & state.name & "'. Run 'spinoza up' first.")

  discard libssh2.init(0)
  defer: libssh2.exit()

  var sock = tryTcpConnect(hostname, port)
  if sock.isNil:
    raise newException(IOError,
      "Could not connect to " & hostname & ":" & $port &
      ". Is the VM running?")
  defer: sock.close()
  let sockFd = sock.getFd()

  var session = sessionInit()
  if session.sessionHandshake(sockFd) != 0:
    raise newException(IOError, "SSH handshake failed")
  defer:
    discard session.sessionDisconnect("bye")
    discard session.sessionFree()

  if session.userauthPassword(username, password, nil) != 0:
    raise newException(IOError, "SSH authentication failed for " & username)

  var channel = session.channelOpenSession()
  if channel.isNil:
    raise newException(IOError, "Failed to open SSH channel")
  defer: discard channel.channelFree()

  let (cols, rows) = getTerminalSize()
  if channel.channelRequestPty("xterm-256color") != 0:
    raise newException(IOError, "Failed to request PTY")
  discard channel.channelRequestPtySize(cols, rows)

  if channel.channelShell() != 0:
    raise newException(IOError, "Failed to request shell")

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

  channel.channelSetBlocking(0)
  session.sessionSetBlocking(0)

  var buf: array[4096, char]
  var stdinClosed = false

  while true:
    discard waitsocket(sockFd, session)

    while true:
      let rc = channel.channelRead(addr buf[0], 4096)
      if rc > 0:
        discard write(1, addr buf[0], rc)
      elif rc == 0:
        return
      else:
        let err = session.sessionLastErrno()
        if err != LIBSSH2_ERROR_EAGAIN:
          return
        break

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

proc ssh*(config: SpinozaConfig) {.used.} =
  ## Connect using the endpoint recorded by `spinoza up`.
  let stored = loadVm(config.name)
  if stored.isSome:
    sshFromStore(stored.get())
  else:
    raise newException(IOError,
      "No boot record for '" & config.name & "'. Run 'spinoza up' first.")

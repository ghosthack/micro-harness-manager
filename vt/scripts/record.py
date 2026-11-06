#!/usr/bin/env python3
"""Records a program's raw terminal output through a pseudo-terminal, for the vt corpus in
vt/src/test/resources/recordings/ (dev time only; the recordings are committed).

Usage:
    python3 -I vt/scripts/record.py OUT COLS ROWS [--send DELAY:TEXT]... -- CMD [ARGS...]

The child runs on a COLS x ROWS pty with TERM=xterm-256color and a UTF-8 locale. Each
--send writes TEXT (Python escapes such as \\r and \\x1b are decoded) DELAY seconds after
the previous one, e.g. --send 1.0::q\\r to quit vim. Output is read until the child exits
(or 20 s pass, then it is killed). Nothing is answered: queries such as DA1 go unanswered,
as on a terminal that does not support them, so programs fall back after their timeout.
"""
import codecs
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def main():
    args = sys.argv[1:]
    if '--' not in args or len(args) < 4:
        sys.exit(__doc__)
    split = args.index('--')
    out, cols, rows = args[0], int(args[1]), int(args[2])
    sends = []
    rest = args[3:split]
    while rest:
        if rest[0] != '--send' or len(rest) < 2:
            sys.exit(__doc__)
        delay, text = rest[1].split(':', 1)
        sends.append((float(delay), codecs.decode(text, 'unicode_escape').encode('utf-8')))
        rest = rest[2:]
    cmd = args[split + 1:]

    env = dict(os.environ)
    env.update({'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8',
                'COLUMNS': str(cols), 'LINES': str(rows)})
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(cmd[0], cmd, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    os.kill(pid, signal.SIGWINCH)

    data = bytearray()
    start = time.monotonic()
    next_send = start + (sends[0][0] if sends else 0)
    while True:
        now = time.monotonic()
        if sends and now >= next_send:
            os.write(fd, sends.pop(0)[1])
            next_send = now + (sends[0][0] if sends else 0)
        if now - start > 20:
            os.kill(pid, signal.SIGKILL)
        timeout = max(0.0, next_send - now) if sends else 0.2
        ready, _, _ = select.select([fd], [], [], min(timeout, 0.2))
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            data.extend(chunk)
        else:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done and not sends:
                # Drain what is left, then stop.
                while select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        chunk = b''
                    if not chunk:
                        break
                    data.extend(chunk)
                break
    with open(out, 'wb') as f:
        f.write(data)
    print('%s: %d bytes' % (out, len(data)))


if __name__ == '__main__':
    main()

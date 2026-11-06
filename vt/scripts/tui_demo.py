#!/usr/bin/env python3
"""A small full-screen and inline TUI used as a recording source (see record.py), standing in
for htop-style curses programs and for ratatui's inline viewport (Codex), without running
either. Usage: tui_demo.py curses | inline
"""
import curses
import sys
import time


def curses_demo(stdscr):
    curses.start_color()
    curses.use_default_colors()
    for i in range(1, 8):
        curses.init_pair(i, i, -1)
    curses.init_pair(8, curses.COLOR_BLACK, curses.COLOR_CYAN)
    rows, cols = stdscr.getmaxyx()
    for frame in range(6):
        stdscr.erase()
        stdscr.border()
        stdscr.addstr(0, 2, ' demo %d ' % frame, curses.A_BOLD | curses.color_pair(3))
        for i in range(1, rows - 3):
            bar = int((cols - 20) * ((i * 7 + frame * 13) % 100) / 100)
            stdscr.addstr(i, 2, 'cpu%-3d [' % i, curses.color_pair(i % 7 + 1))
            stdscr.addstr('|' * bar, curses.color_pair((i + frame) % 7 + 1) | curses.A_BOLD)
            stdscr.addstr(i, cols - 9, ']%5.1f%%' % (bar * 100.0 / (cols - 20)))
        stdscr.addstr(rows - 2, 1, ' F1Help  F10Quit ' + ' ' * (cols - 19), curses.color_pair(8))
        stdscr.refresh()
        time.sleep(0.05)
    # Scroll a region the way list views do.
    win = curses.newwin(rows - 6, cols - 4, 3, 2)
    win.scrollok(True)
    win.idlok(True)
    for i in range(30):
        win.addstr('line %d: %s\n' % (i, 'x' * (i % (cols - 20))), curses.color_pair(i % 7 + 1))
        win.refresh()
    time.sleep(0.05)


def inline_demo():
    out = sys.stdout
    rows = 24
    viewport = 5
    top = rows - viewport + 1  # 1-based first viewport row
    out.write('\x1b[?2026h')
    out.write('\r\n' * (viewport - 1))
    out.write('\x1b[?2026l')
    for n in range(12):
        out.write('\x1b[?2026h')
        # Insert a history line above the viewport: scroll region 1..top-1, write at its
        # bottom, then reset the region (ratatui's insert_before with a scroll region).
        out.write('\x1b[1;%dr' % (top - 1))
        out.write('\x1b[%d;1H' % (top - 1))
        out.write('\r\n\x1b[1;3%dm>\x1b[0m message %d \U0001f680 %s' % (n % 7 + 1, n, 'done ' * (n % 4)))
        out.write('\x1b[r')
        # Redraw the viewport.
        for r in range(viewport):
            out.write('\x1b[%d;1H\x1b[2K' % (top + r))
            if r == 0:
                out.write('\x1b[7m working %s \x1b[0m' % ('.' * (n % 4)))
            elif r == viewport - 1:
                out.write('\x1b[2m> type here\x1b[0m')
            else:
                out.write('  step %d/%d' % (r, viewport))
        out.write('\x1b[%d;3H' % (top + viewport - 1))
        out.write('\x1b[?2026l')
        out.flush()
        time.sleep(0.02)
    out.write('\x1b[%d;1H\x1b[0J' % top)
    out.flush()


if __name__ == '__main__':
    if sys.argv[1:] == ['curses']:
        curses.wrapper(curses_demo)
    else:
        inline_demo()

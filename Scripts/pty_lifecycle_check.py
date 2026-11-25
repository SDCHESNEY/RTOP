import os, pty, sys, time, signal, select, fcntl, termios, struct, re

# End-to-end terminal lifecycle check: runs the real binary in a pseudo-terminal and verifies
# render, input, resize, every exit path (exit code and terminal restoration).
# usage: python3 -I Scripts/pty_lifecycle_check.py .build/debug/rtop
BIN = sys.argv[1]

def run(label, actions, expect_code):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(BIN, [BIN, "--refresh-ms", "250"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = b""
    def pump(t):
        nonlocal out
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(fd, 65536)
                except OSError:
                    return
                if not d: return
                out += d
    pump(1.2)
    start_out = out
    for a in actions:
        a(fd, pid, pump)
    pump(1.0)
    # wait for exit
    code = None
    for _ in range(40):
        p, st = os.waitpid(pid, os.WNOHANG)
        if p:
            code = os.waitstatus_to_exitcode(st); break
        pump(0.1)
    if code is None:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); code = "HUNG"
    text = out.decode("utf8", "replace")
    restored = "\x1b[?1049l" in text and "\x1b[?25h" in text and text.rfind("\x1b[?1049l") > text.rfind("\x1b[?1049h")
    ok = (code == expect_code) and restored
    print(f"{'PASS' if ok else 'FAIL'} {label}: exit={code} restored={restored}")
    return start_out, text

def send(b): return lambda fd, pid, pump: (os.write(fd, b), pump(0.3))
def winsz(r, c):
    def f(fd, pid, pump):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0))
        os.kill(pid, signal.SIGWINCH); pump(0.4)
    return f
def sig(s): return lambda fd, pid, pump: (os.kill(pid, s), pump(0.3))

first, full = run("q quits", [send(b"jjj\x1b[B"), send(b"q")], 0)
ft = first.decode("utf8","replace"); print("  title:", "rtop" in ft, "| header:", "PID" in ft and "NAME" in ft, "| launchd row:", "launchd" in ft, "| CPU in title:", "CPU" in ft)
run("ctrl-c quits", [send(b"\x03")], 0)
run("escape quits", [send(b"\x1b")], 0)
run("SIGTERM", [sig(signal.SIGTERM)], 0)
run("SIGHUP", [sig(signal.SIGHUP)], 0)
run("SIGINT", [sig(signal.SIGINT)], 0)
run("resize storm incl 20x5, 5x2, 1x1, 0-ish then back", [winsz(5,20), winsz(2,5), winsz(1,1), winsz(40,120), winsz(5,20)] + [winsz(10+i%20, 30+i) for i in range(30)] + [send(b"q")], 0)
run("keys: paging, home, end, garbage", [send(b"\x1b[6~\x1b[5~\x1b[H\x1b[F\xff\xfe\x00\x1b[99~k"), send(b"q")], 0)
run("kill -TSTP does not suspend", [sig(signal.SIGTSTP), send(b"q")], 0)

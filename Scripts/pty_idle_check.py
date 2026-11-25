import os, pty, sys, time, select, termios, subprocess
# Idle-cost and termios-restoration check for the real binary in a pseudo-terminal.
# usage: python3 -I Scripts/pty_idle_check.py .build/debug/rtop
BIN = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execv(BIN, [BIN, "--refresh-ms", "1000"])
before = termios.tcgetattr(fd)
def pump(t):
    end = time.time() + t
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.05)
        if r:
            try: os.read(fd, 65536)
            except OSError: return
pump(1.0)
raw = termios.tcgetattr(fd)
samples = []
for i in range(3):
    pump(3.0)
    ps = subprocess.run(["ps","-o","%cpu=,rss=","-p",str(pid)],capture_output=True,text=True).stdout.split()
    samples.append(ps)
os.write(fd, b"q"); pump(0.5)
os.waitpid(pid, 0)
after = termios.tcgetattr(fd)
print("termios before==after:", before[:4] == after[:4], "| raw differed while running:", raw[:4] != before[:4])
print("ps samples (%cpu rss KB) at ~4s,7s,10s:", samples)

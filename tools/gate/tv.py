# tv.py <outfile> cmd...: run cmd, write wall seconds and max RSS (largest child, KiB) like time -v.
import resource, subprocess, sys, time
t = time.monotonic()
rc = subprocess.call(sys.argv[2:])
wall = time.monotonic() - t
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
with open(sys.argv[1], "w") as f:
    f.write(f"Elapsed (wall clock) time (s): {wall:.1f}\nMaximum resident set size (kbytes): {ru.ru_maxrss}\nUser time (s): {ru.ru_utime:.1f}\nExit status: {rc}\n")
sys.exit(rc)

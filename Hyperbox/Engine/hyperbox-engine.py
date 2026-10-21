#!/usr/bin/python3
# Hyperbox's container engine agent. The Mac writes it to the boot share before each boot, so it
# updates with the app; systemd runs it as hyperbox-engine.service.
#
# Everything between the Mac and this machine goes over vsock, so it works whatever the Mac's network
# looks like (VPNs that break macOS's NAT, no network at all):
#   vsock 2375  ->  Docker's socket
#   vsock 2376  ->  one line of JSON: memory, for the balloon
#   vsock 2377  ->  "port\n", then 127.0.0.1:port here (published ports, from the Mac's localhost)
#   tcp   3129  <-  outgoing TCP, redirected here by iptables, sent to the Mac on vsock 3129 as "ip port\n"
import json, os, socket, struct, subprocess, sys, threading

HOST_CID = 2
PROXY_PORT = 3129
# Docker's networks: traffic to them stays here. Everything else leaves through the Mac.
LOCAL_NETS = ["127.0.0.0/8", "172.16.0.0/12"]


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def pipe(a, b):
    """Copies both ways until both sides are done, passing half-closes on, then closes both."""
    def copy(src, dst, done):
        try:
            while True:
                data = src.recv(262144)
                if not data:
                    break
                dst.sendall(data)
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        except OSError:
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        done.release()

    done = threading.Semaphore(0)
    threading.Thread(target=copy, args=(a, b, done), daemon=True).start()
    threading.Thread(target=copy, args=(b, a, done), daemon=True).start()

    def close():
        done.acquire()
        done.acquire()
        a.close()
        b.close()
    threading.Thread(target=close, daemon=True).start()


def read_line(sock):
    line = b""
    while not line.endswith(b"\n"):
        c = sock.recv(1)
        if not c:
            raise OSError("closed")
        line += c
        if len(line) > 256:
            raise OSError("header too long")
    return line.decode().strip()


def serve(listener, handle):
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            continue
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


def vsock_listener(port):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.bind((socket.VMADDR_CID_ANY, port))
    s.listen(128)
    return s


def docker(conn):
    try:
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        up.connect("/run/docker.sock")
    except OSError:
        conn.close()
        return
    pipe(conn, up)


def info(conn):
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k] = int(v.split()[0]) * 1024
        conn.sendall(json.dumps({"memTotal": mem["MemTotal"], "memAvailable": mem["MemAvailable"]}).encode() + b"\n")
    except OSError:
        pass
    conn.close()


def forward(conn):
    try:
        port = int(read_line(conn))
        up = socket.create_connection(("127.0.0.1", port), timeout=10)
        up.settimeout(None)
    except (OSError, ValueError):
        conn.close()
        return
    pipe(conn, up)


def proxy(conn):
    try:
        # SO_ORIGINAL_DST: where the connection was going before iptables redirected it here.
        raw = conn.getsockopt(socket.SOL_IP, 80, 16)
        port, = struct.unpack("!H", raw[2:4])
        ip = socket.inet_ntoa(raw[4:8])
        up = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        up.connect((HOST_CID, PROXY_PORT))
        up.sendall(f"{ip} {port}\n".encode())
    except OSError:
        conn.close()
        return
    pipe(conn, up)


def iptables(*args):
    return subprocess.run(["iptables", "-w", *args], capture_output=True).returncode == 0


def redirect():
    """Sends outgoing TCP, from this machine and from containers, to the proxy."""
    iptables("-t", "nat", "-N", "HYPERBOX")
    iptables("-t", "nat", "-F", "HYPERBOX")
    for net in LOCAL_NETS:
        iptables("-t", "nat", "-A", "HYPERBOX", "-d", net, "-j", "RETURN")
    iptables("-t", "nat", "-A", "HYPERBOX", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "RETURN")
    iptables("-t", "nat", "-A", "HYPERBOX", "-p", "tcp", "-j", "REDIRECT", "--to-ports", str(PROXY_PORT))
    for chain in ("OUTPUT", "PREROUTING"):
        if not iptables("-t", "nat", "-C", chain, "-p", "tcp", "-j", "HYPERBOX"):
            iptables("-t", "nat", "-I", chain, "1", "-p", "tcp", "-j", "HYPERBOX")


def sync_kernel():
    """Hands the Mac this system's kernel and initrd, so it boots them directly next time."""
    d = "/mnt/hyperbox-boot"
    kernel = os.path.realpath("/vmlinuz")
    initrd = os.path.realpath("/initrd.img")
    version = os.path.basename(kernel)
    try:
        if open(f"{d}/version").read().strip() == version:
            return
    except OSError:
        pass
    root = subprocess.run(["findmnt", "-no", "UUID", "/"], capture_output=True, text=True).stdout.strip()
    if not root or not os.path.exists(kernel) or not os.path.exists(initrd):
        return
    with open(kernel, "rb") as f:
        data = f.read()
    if data[:2] == b"\x1f\x8b":
        import gzip
        data = gzip.decompress(data)
    with open(f"{d}/Image.new", "wb") as f:
        f.write(data)
    with open(initrd, "rb") as src, open(f"{d}/initrd.new", "wb") as dst:
        dst.write(src.read())
    with open(f"{d}/cmdline", "w") as f:
        f.write(f"root=UUID={root}\n")
    # The Image last: the Mac takes the three files as ready once it's there.
    os.replace(f"{d}/initrd.new", f"{d}/initrd")
    os.replace(f"{d}/Image.new", f"{d}/Image")
    with open(f"{d}/version", "w") as f:
        f.write(version + "\n")
    log("hyperbox-engine: handed the Mac kernel", version)


def rosetta():
    """Intel containers (--platform linux/amd64) run with Rosetta, when the Mac has it."""
    if not os.path.exists("/mnt/rosetta/rosetta") or os.path.exists("/proc/sys/fs/binfmt_misc/rosetta"):
        return
    magic = r"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"
    mask = r"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"
    try:
        if not os.path.exists("/proc/sys/fs/binfmt_misc/register"):
            subprocess.run(["mount", "-t", "binfmt_misc", "binfmt_misc", "/proc/sys/fs/binfmt_misc"])
        with open("/proc/sys/fs/binfmt_misc/register", "w") as f:
            f.write(f":rosetta:M::{magic}:{mask}:/mnt/rosetta/rosetta:CF")
    except OSError as e:
        log("hyperbox-engine: no Rosetta:", e)


def main():
    redirect()
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.bind(("0.0.0.0", PROXY_PORT))
    tcp.listen(512)
    for listener, handle in ((vsock_listener(2375), docker), (vsock_listener(2376), info),
                             (vsock_listener(2377), forward), (tcp, proxy)):
        threading.Thread(target=serve, args=(listener, handle), daemon=True).start()
    log("hyperbox-engine: ready")
    for task in (sync_kernel, rosetta):
        try:
            task()
        except Exception as e:
            log("hyperbox-engine:", task.__name__, e)
    threading.Event().wait()


if __name__ == "__main__":
    main()

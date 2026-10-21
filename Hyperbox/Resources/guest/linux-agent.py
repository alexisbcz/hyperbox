#!/usr/bin/python3
"""Hyperbox's agent in Linux guests: runs commands and passes files for the Mac, over vsock.

The protocol is in GuestAgent.swift on the host: one JSON object per line each way, on port 7070.
Hyperbox's automatic installs put this file at /usr/local/libexec/hyperbox/agent.py and run it as
the hyperbox-agent systemd service. Standard library only, so it runs on any distribution's Python 3.
"""

import base64
import glob
import json
import os
import pwd
import signal
import socket
import subprocess
import sys
import threading

VERSION = 1
PORT = 7070
CONFIG = "/etc/hyperbox/agent.json"
# Written by the first-boot setup with the boot it ran in, so `ready` waits for the reboot after it.
INSTALL_BOOT = "/var/lib/hyperbox/install-boot-id"
# The first-boot setup's reason for giving up, when it did.
SETUP_FAILED = "/var/lib/hyperbox/install-failed"
MAX_OUTPUT = 16 << 20


def log(*args):
    print("hyperbox-agent:", *args, file=sys.stderr, flush=True)


def desktop_user():
    """The user Hyperbox created, or else the first ordinary one (for machines installed from an ISO)."""
    try:
        with open(CONFIG) as f:
            return pwd.getpwnam(json.load(f)["user"])
    except (OSError, KeyError, ValueError):
        pass
    users = sorted((p for p in pwd.getpwall() if 1000 <= p.pw_uid < 60000), key=lambda p: p.pw_uid)
    return users[0] if users else None


def boot_id():
    with open("/proc/sys/kernel/random/boot_id") as f:
        return f.read().strip()


def ready():
    """False while a Hyperbox first-boot setup is running, or hasn't rebooted since."""
    if not os.path.exists("/var/lib/cloud/instance"):
        return True
    try:
        with open(INSTALL_BOOT) as f:
            return f.read().strip() != boot_id()
    except OSError:
        return False


def environment(user):
    """A login-like environment, plus the desktop session's display and bus when there is one."""
    path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if user is None:
        return {"HOME": "/root", "USER": "root", "LOGNAME": "root", "SHELL": "/bin/sh", "PATH": path, "LANG": "C.UTF-8"}
    env = {
        "HOME": user.pw_dir, "USER": user.pw_name, "LOGNAME": user.pw_name,
        "SHELL": user.pw_shell or "/bin/sh", "PATH": path, "LANG": system_lang(),
    }
    run = "/run/user/%d" % user.pw_uid
    if os.path.isdir(run):
        env["XDG_RUNTIME_DIR"] = run
        if os.path.exists(run + "/bus"):
            env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=%s/bus" % run
        waylands = sorted(glob.glob(run + "/wayland-[0-9]"))
        if waylands:
            env["WAYLAND_DISPLAY"] = os.path.basename(waylands[0])
    displays = sorted(glob.glob("/tmp/.X11-unix/X[0-9]*"))
    if displays:
        env["DISPLAY"] = ":" + displays[0].rsplit("X", 1)[1]
        auth = glob.glob(run + "/.mutter-Xwaylandauth.*") + glob.glob(run + "/gdm/Xauthority") + [user.pw_dir + "/.Xauthority"]
        auth = [a for a in auth if os.path.exists(a)]
        if auth:
            env["XAUTHORITY"] = auth[0]
    return env


def system_lang():
    for name in ("/etc/locale.conf", "/etc/default/locale"):
        try:
            with open(name) as f:
                for line in f:
                    if line.startswith("LANG="):
                        return line.split("=", 1)[1].strip().strip('"')
        except OSError:
            pass
    return "C.UTF-8"


def exec_command(request):
    command = request.get("command")
    if not isinstance(command, str):
        raise ValueError("exec needs a command")
    timeout = float(request.get("timeout") or 120)
    user = None if request.get("admin") else desktop_user()
    options = {}
    if user is not None:
        options = {"user": user.pw_uid, "group": user.pw_gid,
                   "extra_groups": os.getgrouplist(user.pw_name, user.pw_gid)}
    env = environment(user)
    process = subprocess.Popen(
        ["/bin/sh", "-c", command], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=env["HOME"] if os.path.isdir(env["HOME"]) else "/", env=env, start_new_session=True, **options)
    # Read in threads and stop at the shell's exit, not at the pipes' end: a command that starts
    # something in the background (an app, wl-copy) leaves it holding them open for as long as it runs.
    out, err = bytearray(), bytearray()
    readers = [threading.Thread(target=drain, args=(pipe, buffer), daemon=True)
               for pipe, buffer in ((process.stdout, out), (process.stderr, err))]
    for reader in readers:
        reader.start()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        for reader in readers:
            reader.join(1)
        return {"ok": True, "exitCode": 124, "stdout": text(out),
                "stderr": text(err) + "\nhyperbox: timed out after %g seconds" % timeout}
    for reader in readers:
        reader.join(0.5)
    return {"ok": True, "exitCode": process.returncode, "stdout": text(out), "stderr": text(err)}


def drain(pipe, buffer):
    for chunk in iter(lambda: pipe.read1(65536), b""):
        if len(buffer) < MAX_OUTPUT:
            buffer.extend(chunk)


def text(data):
    return bytes(data[:MAX_OUTPUT]).decode("utf-8", errors="replace")


def resolve(path):
    """`~` is the desktop user's home, not root's."""
    if not isinstance(path, str) or not path:
        raise ValueError("needs a path")
    user = desktop_user()
    if path == "~" or path.startswith("~/"):
        path = (user.pw_dir if user else "/root") + path[1:]
    if not os.path.isabs(path):
        path = os.path.join(user.pw_dir if user else "/root", path)
    return path, user


def write_file(request):
    path, user = resolve(request.get("path"))
    data = base64.b64decode(request.get("data") or "")
    directory = os.path.dirname(path)
    created = []
    walk = directory
    while walk and not os.path.exists(walk):
        created.append(walk)
        walk = os.path.dirname(walk)
    os.makedirs(directory, exist_ok=True)
    temporary = path + ".hyperbox-partial"
    with open(temporary, "wb") as f:
        f.write(data)
    mode = request.get("mode")
    os.chmod(temporary, int(mode) if mode is not None else 0o644)
    # Files in the user's home belong to the user, as if they had copied them there.
    if user and (path + "/").startswith(user.pw_dir.rstrip("/") + "/"):
        for p in created + [temporary]:
            os.chown(p, user.pw_uid, user.pw_gid)
    os.replace(temporary, path)
    return {"ok": True, "path": path}


def read_file(request):
    path, _ = resolve(request.get("path"))
    with open(path, "rb") as f:
        return {"ok": True, "data": base64.b64encode(f.read()).decode()}


def handle(request):
    op = request.get("op")
    if op == "ping":
        reply = {"ok": True, "os": "linux", "version": VERSION, "ready": ready()}
        try:
            with open(SETUP_FAILED) as f:
                reply["setupError"] = f.read().strip()
        except OSError:
            pass
        return reply
    if op == "exec":
        return exec_command(request)
    if op == "writeFile":
        return write_file(request)
    if op == "readFile":
        return read_file(request)
    if op in ("getClipboard", "setClipboard"):
        return {"ok": False, "error": "Linux guests share the clipboard through spice-vdagent."}
    return {"ok": False, "error": "unknown op %r" % op}


def serve(connection):
    with connection:
        stream = connection.makefile("rwb")
        for line in stream:
            try:
                reply = handle(json.loads(line))
            except Exception as error:  # Every failure goes back to the Mac rather than killing the agent.
                reply = {"ok": False, "error": str(error) or type(error).__name__}
            stream.write(json.dumps(reply).encode() + b"\n")
            stream.flush()


def main():
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((socket.VMADDR_CID_ANY, PORT))
    server.listen(16)
    log("listening on vsock port", PORT)
    while True:
        connection, _ = server.accept()
        threading.Thread(target=serve, args=(connection,), daemon=True).start()


if __name__ == "__main__":
    main()

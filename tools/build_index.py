#!/usr/bin/env python3
"""Generate index.json from catalog.json and the files on disk (run from the repo root)."""
import hashlib, json, os
cat = json.load(open('catalog.json'))
out = {"version": 1, "base": cat["base"], "entries": []}
def add(files, root):
    for dirpath, _, names in os.walk(root):
        for n in sorted(names):
            p = os.path.join(dirpath, n).replace(os.sep, '/')
            files.append(p)
for e in cat["entries"]:
    files = []
    root = ("modules/" if e["type"] == "module" else "bot/") + e["name"]
    add(files, root)
    files += e.get("extraFiles", [])
    entry = {k: e[k] for k in ("name", "type", "version", "title", "description") if k in e}
    if "requires" in e: entry["requires"] = e["requires"]
    if e.get("screenshot") and os.path.exists(e["screenshot"]):
        entry["screenshot"] = e["screenshot"]
        with open(e["screenshot"], 'rb') as fh:  # PNG IHDR: width/height big-endian at bytes 16..24
            head = fh.read(24)
        if head[:8] == b'\x89PNG\r\n\x1a\n':
            import struct
            w, h = struct.unpack('>II', head[16:24])
            entry["screenshotSize"] = [w, h]
        # the client caches images per URL for the whole session (and Pages caches too): the installer
        # appends this hash to the URL so a changed screenshot is a new URL
        entry["screenshotSha1"] = hashlib.sha1(open(e["screenshot"], 'rb').read()).hexdigest()
    entry["files"] = []
    for p in sorted(set(files)):
        data = open(p, 'rb').read()
        entry["files"].append({"path": p, "sha1": hashlib.sha1(data).hexdigest(), "size": len(data)})
    out["entries"].append(entry)
json.dump(out, open('index.json', 'w'), indent=1)
print("index.json:", sum(len(e["files"]) for e in out["entries"]), "files in", len(out["entries"]), "entries")

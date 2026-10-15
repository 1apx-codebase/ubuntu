#!/usr/bin/env python3
"""Generate docs/architecture.svg, the architecture diagram in the README.

Every label is placed from its box's geometry (centered horizontally, baselines on a
fixed grid), and its width is measured with Arimo's real glyph advances (Arimo has the
same metrics as Arial/Liberation Sans) so the script can fail if any label doesn't fit.
Usage: python3 docs/architecture.py docs/architecture.svg <path to Arimo[wght].ttf>
Arimo: https://github.com/google/fonts/tree/main/ofl/arimo (only its metrics are read).
ci/validate.sh downloads a pinned copy and fails if the committed SVG is not this script's output.
It exits with an error, writing nothing, if a label overflows its box or an arrow crosses a label.
"""
import struct
import sys

OUT, FONT = sys.argv[1], sys.argv[2]


# ---------- glyph advance widths from the TrueType file ----------
def load_metrics(path):
    data = open(path, "rb").read()
    num = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(num):
        tag, _, off, length = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
        tables[tag.decode()] = (off, length)
    upem = struct.unpack(">H", data[tables["head"][0] + 18:tables["head"][0] + 20])[0]
    n_hm = struct.unpack(">H", data[tables["hhea"][0] + 34:tables["hhea"][0] + 36])[0]
    hmtx = tables["hmtx"][0]
    adv = [struct.unpack(">H", data[hmtx + 4 * i:hmtx + 4 * i + 2])[0] for i in range(n_hm)]
    cmap_off = tables["cmap"][0]
    n_sub = struct.unpack(">H", data[cmap_off + 2:cmap_off + 4])[0]
    cmap = {}
    for i in range(n_sub):
        pid, eid, off = struct.unpack(">HHI", data[cmap_off + 4 + 8 * i:cmap_off + 12 + 8 * i])
        sub = cmap_off + off
        fmt = struct.unpack(">H", data[sub:sub + 2])[0]
        if fmt == 4 and pid == 3:
            segx2 = struct.unpack(">H", data[sub + 6:sub + 8])[0]
            seg = segx2 // 2
            ends = struct.unpack(f">{seg}H", data[sub + 14:sub + 14 + segx2])
            base = sub + 16 + segx2
            starts = struct.unpack(f">{seg}H", data[base:base + segx2])
            deltas = struct.unpack(f">{seg}h", data[base + segx2:base + 2 * segx2])
            ro_pos = base + 2 * segx2
            ros = struct.unpack(f">{seg}H", data[ro_pos:ro_pos + segx2])
            for s in range(seg):
                for c in range(starts[s], ends[s] + 1):
                    if c == 0xFFFF:
                        continue
                    if ros[s] == 0:
                        g = (c + deltas[s]) & 0xFFFF
                    else:
                        gp = ro_pos + 2 * s + ros[s] + 2 * (c - starts[s])
                        g = struct.unpack(">H", data[gp:gp + 2])[0]
                        g = (g + deltas[s]) & 0xFFFF if g else 0
                    cmap.setdefault(c, g)
    return upem, adv, cmap


UPEM, ADV, CMAP = load_metrics(FONT)
BOLD_FACTOR = 1.08  # bold Arial/Arimo glyphs are up to ~8% wider than regular


def text_width(s, size, bold=False):
    units = sum(ADV[min(CMAP.get(ord(ch), 0), len(ADV) - 1)] for ch in s)
    return units * size / UPEM * (BOLD_FACTOR if bold else 1.0)


# ---------- drawing helpers ----------
C = {
    "ink": "#1f2937", "muted": "#4b5563", "line": "#9ca3af", "frame": "#64748b",
    "vm": "#f8fafc", "pod": "#eff6ff", "podline": "#3b82f6", "pill": "#ffffff",
    "ns": "#2563eb", "user": "#2563eb", "db": "#c2410c", "admin": "#475569", "net": "#7c3aed",
    "ext": "#fefce8", "extline": "#ca8a04", "dbfill": "#fff7ed",
}
FONT_STACK = "Helvetica Neue, Helvetica, Arial, Liberation Sans, Arimo, sans-serif"
out = []
problems = []
text_boxes = []   # (left, right, top, bottom, label) of every label, for the overlap check
segments = []     # ((x1, y1), (x2, y2)) of every arrow segment


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def rect(x, y, w, h, fill, stroke, r=8, dash=None, sw=1.5):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    out.append(f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def text(x, y, s, size=13, bold=False, color=None, anchor="middle", box=None, italic=False):
    """Draw text with its baseline at y. box=(left, right) checks it fits with 8px padding."""
    w = text_width(s, size, bold)
    if box:
        left = x - w / 2 if anchor == "middle" else x if anchor == "start" else x - w
        right = left + w
        if left < box[0] + 8 or right > box[1] - 8:
            problems.append(f"'{s}' ({w:.0f}px) doesn't fit in {box[0]}..{box[1]} (text {left:.0f}..{right:.0f})")
    left = x - w / 2 if anchor == "middle" else x if anchor == "start" else x - w
    text_boxes.append((left, left + w, y - size * 0.8, y + size * 0.25, s))
    # Always explicit: SVG's default anchor is "start", not "middle"
    attrs = f'x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}"'
    if bold:
        attrs += ' font-weight="bold"'
    if italic:
        attrs += ' font-style="italic"'
    if color:
        attrs += f' fill="{color}"'
    out.append(f"  <text {attrs}>{esc(s)}</text>")


def labeled_box(x, y, w, h, lines, fill, stroke, r=8, dash=None, first_bold=True, size=13, gap=19):
    """A box with lines of text centered horizontally and the block centered vertically."""
    rect(x, y, w, h, fill, stroke, r, dash)
    sizes = [(size + 2 if (i == 0 and first_bold) else size) for i in range(len(lines))]
    block = (len(lines) - 1) * gap
    # baseline of the first line so the block's visual middle sits at the box's middle
    y0 = y + h / 2 - block / 2 + sizes[0] * 0.35
    for i, s in enumerate(lines):
        text(x + w / 2, round(y0 + i * gap, 1), s, sizes[i], bold=(i == 0 and first_bold),
             color=None if (i == 0 and first_bold) else C["muted"], box=(x, x + w))


def arrow(points, color, marker, dash=None):
    segments.extend(zip(points, points[1:]))
    d = " ".join(("M" if i == 0 else "L") + f"{px},{py}" for i, (px, py) in enumerate(points))
    da = f' stroke-dasharray="{dash}"' if dash else ""
    out.append(f'  <path d="{d}" fill="none" stroke="{color}" stroke-width="2"{da} marker-end="url(#{marker})"/>')


# ---------- layout ----------
# 1000 px wide and portrait, with 14-19 px text: GitHub scales README images down to its
# ~830-1000 px content column, so the text must still be readable after that.
W, H = 1000, 1390
MARKERS = {"m-user": C["user"], "m-db": C["db"], "m-admin": C["admin"], "m-net": C["net"]}
BODY, SMALL, LABEL = 15, 14, 14   # box text, secondary lines, arrow labels

out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'font-family="{FONT_STACK}" fill="{C["ink"]}" role="img" aria-labelledby="title desc">')
out.append('  <title id="title">k8-1apx: Kubernetes cluster for Oracle ORDS</title>')
out.append('  <desc id="desc">Three Ubuntu VMs on Proxmox: k8-control runs the control plane; '
           'k8-worker-1 and k8-worker-2 each run one ORDS pod in the ords namespace, behind a MetalLB '
           'LoadBalancer IP 192.168.1.180. Users reach https://www.1apx.com through Cloudflare and the '
           'router port forward. ORDS connects to the existing Oracle database node.1apx.com:1521.</desc>')
out.append("  <defs>")
for mid, col in MARKERS.items():
    out.append(f'    <marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
               f'<path d="M0,0 L10,5 L0,10 z" fill="{col}"/></marker>')
out.append("  </defs>")
rect(0.5, 0.5, W - 1, H - 1, "#ffffff", "#d1d5db", r=12, sw=1)

# Title
text(W / 2, 46, "k8-1apx: Kubernetes cluster for Oracle ORDS", 26, bold=True, box=(0, W))
text(W / 2, 74, "Kubernetes 1.36.5 · kubeadm · containerd · Calico · MetalLB · Ubuntu 26.04 on Proxmox",
     BODY, color=C["muted"], box=(0, W))

# Row 1: outside the Proxmox host
ROW_Y, ROW_H = 98, 82
admin = (30, ROW_Y, 260, ROW_H)
users = (330, ROW_Y, 280, ROW_H)
cflare = (690, ROW_Y, 280, ROW_H)
router = (690, 214, 280, 72)
labeled_box(*admin, ["Admin (<user>)", "kubectl · SSH · git"], C["vm"], C["frame"], size=BODY, gap=24)
labeled_box(*users, ["Users (internet and LAN)", "https://www.1apx.com/"], C["vm"], C["frame"], size=BODY, gap=24)
labeled_box(*cflare, ["Cloudflare", "www.1apx.com · proxied", "SSL/TLS Full (strict)"], C["ext"], C["extline"],
            size=BODY, gap=21)
labeled_box(*router, ["Router 192.168.1.1", "port 443 → 192.168.1.180"], C["vm"], C["frame"], size=BODY, gap=24)

# Proxmox host frame, with its label as a tag on the bottom edge
FX, FY, FW = 20, 300, 960
INNER_X, INNER_W = 70, 860           # content inside the frame; gutters carry the arrows

# k8-control: full width, components in a 3 x 2 grid
ctl = (INNER_X, 330, INNER_W, 236)
rect(*ctl, C["vm"], C["frame"], r=10)
text(W / 2, ctl[1] + 30, "k8-control", 19, bold=True, box=(ctl[0], ctl[0] + ctl[2]))
text(W / 2, ctl[1] + 52, "192.168.1.170 · control plane · 8 vCPU, 7.2 GB", SMALL, color=C["muted"],
     box=(ctl[0], ctl[0] + ctl[2]))
grid = [
    ["kube-apiserver :6443", "Secrets encrypted · audit log"],
    ["etcd", "firewalled: k8-control only"],
    ["scheduler", "controller-manager"],
    ["CoreDNS · Calico node", "kube-proxy"],
    ["kubelet · containerd", "tainted: runs no workloads"],
    ["etcd backups", "daily, kept 14 days"],
]
col_w, col_gap, row_h, row_gap = 262, 17, 56, 12
for i, lines in enumerate(grid):
    gx = ctl[0] + 20 + (i % 3) * (col_w + col_gap)
    gy = ctl[1] + 70 + (i // 3) * (row_h + row_gap)
    labeled_box(gx, gy, col_w, row_h, lines, C["pill"], C["line"], r=6, first_bold=False, size=BODY, gap=21)
text(W / 2, ctl[1] + 218, "ufw: SSH and the Kubernetes API from the LAN only", SMALL, color=C["muted"],
     italic=True, box=(ctl[0], ctl[0] + ctl[2]))

# Service (MetalLB), full width
svc = (INNER_X, 596, INNER_W, 92)
labeled_box(*svc, ["Service ords · LoadBalancer · 192.168.1.180",
                   "MetalLB layer 2 · admits only Cloudflare and the nodes",
                   ":443 → ORDS pods on port 8443 (HTTPS only)"],
            C["pod"], C["podline"], size=BODY, gap=22)

# Workers
VY, VH = 718, 450
w1 = (INNER_X, VY, 420, VH)
w2 = (INNER_X + 440, VY, 420, VH)
NS = (85, VY + 74, 830, 214)
for vm, name, ip in ((w1, "k8-worker-1", "192.168.1.171"), (w2, "k8-worker-2", "192.168.1.172")):
    x, y, w, h = vm
    rect(x, y, w, h, C["vm"], C["frame"], r=10)
    text(x + w / 2, y + 30, name, 19, bold=True, box=(x, x + w))
    text(x + w / 2, y + 52, f"{ip} · worker · 4 vCPU, 8 GB", SMALL, color=C["muted"], box=(x, x + w))
rect(*NS, "none", C["ns"], r=10, dash="6 4", sw=1.5)
POD_Y = NS[1] + 36
for vm in (w1, w2):
    x, _, w, _ = vm
    labeled_box(x + 30, POD_Y, w - 60, 160,
                ["ORDS pod", "ords:26.2.3 (pinned by digest)", "init: apex-images, config",
                 "ords serve · HTTPS on port 8443", "UID 54321 · no capabilities"],
                C["pod"], C["podline"], r=8, size=BODY, gap=25)
    for j, label in enumerate(["kubelet · containerd · kube-proxy", "Calico node · MetalLB speaker",
                               "/var/cache/ords-apex (APEX images)"]):
        labeled_box(x + 20, VY + 304 + j * 46, w - 40, 36, [label], C["pill"], C["line"], r=6,
                    first_bold=False, size=BODY)
# Namespace tag, centered on the namespace box's top edge
tag = "namespace ords · NetworkPolicy"
tw = text_width(tag, SMALL, bold=True) + 28
rect(round(W / 2 - tw / 2, 1), NS[1] - 13, round(tw, 1), 26, "#ffffff", C["ns"], r=13)
text(W / 2, NS[1] + 5, tag, SMALL, bold=True, color=C["ns"], box=(W / 2 - tw / 2, W / 2 + tw / 2))

FH = VY + VH + 24 - FY
rect(FX, FY, FW, FH, "none", C["frame"], r=12, dash="7 5", sw=1.5)
flabel = "Proxmox VE host · LAN 192.168.1.0/24 (bridge vmbr0)"
fw = text_width(flabel, SMALL, bold=True) + 28
fcx = 260
rect(round(fcx - fw / 2, 1), FY + FH - 13, round(fw, 1), 26, "#ffffff", C["frame"], r=13)
text(fcx, FY + FH + 5, flabel, SMALL, bold=True, color=C["frame"], box=(fcx - fw / 2, fcx + fw / 2))

# Bottom row: legend, database, internet
BY = FY + FH + 42
LX, LW, LH = 30, 280, 136
db = (330, BY, 340, 84)
inet = (690, BY, 280, 96)
labeled_box(*db, ["Oracle database (existing)", "node.1apx.com:1521 · service pdb1"], C["dbfill"], C["db"],
            size=BODY, gap=24)
labeled_box(*inet, ["Internet (HTTPS 443)", "container-registry.oracle.com", "download.oracle.com"],
            C["ext"], C["extline"], size=BODY, gap=22)

# ---------- arrows ----------
ax = admin[0] + admin[2] / 2
arrow([(ax, ROW_Y + ROW_H), (ax, ctl[1])], C["admin"], "m-admin")
text(ax + 10, FY - 18, "kubectl :6443 · SSH", LABEL, bold=True, color=C["admin"], anchor="start", box=(ax, ax + 200))
# Users to Cloudflare, Cloudflare to the router's public IP, then the router's port forward
# down the right gutter into the Service's right side
uy = ROW_Y + ROW_H / 2
arrow([(users[0] + users[2], uy), (cflare[0], uy)], C["user"], "m-user")
text((users[0] + users[2] + cflare[0]) / 2, uy - 13, "HTTPS", LABEL, bold=True, color=C["user"],
     box=(users[0] + users[2], cflare[0]))
cx_mid = cflare[0] + cflare[2] / 2
arrow([(cx_mid, ROW_Y + ROW_H), (cx_mid, router[1])], C["user"], "m-user")
gx_r = (INNER_X + INNER_W + FX + FW) / 2
arrow([(gx_r, router[1] + router[3]), (gx_r, svc[1] + svc[3] / 2), (svc[0] + svc[2], svc[1] + svc[3] / 2)],
      C["user"], "m-user")
# Service to each ORDS pod, on the workers' outer sides, clear of the centered titles
for cx in (w1[0] + 48, w2[0] + w2[2] - 48):
    arrow([(cx, svc[1] + svc[3]), (cx, POD_Y)], C["user"], "m-user")
# Pods to the database: down the gap between the workers
gx = W / 2
arrow([(gx, NS[1] + NS[3]), (gx, db[1])], C["db"], "m-db")
text(gx + 10, BY - 12, "JDBC :1521 · ORDS_PUBLIC_USER", LABEL, bold=True, color=C["db"], anchor="start",
     box=(gx, inet[0] + 120))
# Workers to the internet: image pulls and the APEX download
nx = inet[0] + 140
arrow([(nx, VY + VH), (nx, inet[1])], C["net"], "m-net", dash="6 4")

# ---------- legend ----------
rect(LX, BY, LW, LH, "#ffffff", C["line"], r=8, sw=1)
text(LX + 16, BY + 24, "Legend", BODY, bold=True, anchor="start", box=(LX, LX + LW))
items = [
    (C["user"], None, "m-user", "User traffic (HTTPS)"),
    (C["db"], None, "m-db", "Database (JDBC, 1521)"),
    (C["admin"], None, "m-admin", "Administration (kubectl, SSH)"),
    (C["net"], "6 4", "m-net", "Outbound HTTPS"),
]
for i, (col, dash, mk, label) in enumerate(items):
    y = BY + 52 + i * 24
    arrow([(LX + 16, y - 5), (LX + 56, y - 5)], col, mk, dash=dash)
    text(LX + 68, y, label, SMALL, anchor="start", box=(LX + 60, LX + LW))
out.append("</svg>")

# ---------- checks ----------
if BY + LH + 20 > H or inet[1] + inet[3] + 20 > H:
    problems.append("bottom row runs off the canvas")
if LX + LW + 10 > db[0] or db[0] + db[2] + 10 > inet[0]:
    problems.append("bottom-row boxes overlap")
# Every text element must carry an explicit anchor
if any("<text " in line and "text-anchor=" not in line for line in out):
    problems.append("a text element has no explicit text-anchor")
# Nothing smaller than 14 px, so the text stays readable after GitHub scales the image down
for line in out:
    if "<text " in line and float(line.split('font-size="')[1].split('"')[0]) < 14:
        problems.append(f"text below 14 px: {line.strip()[:80]}")
# No arrow segment may cross a label (6px clearance), except the legend's own samples
for (x1, y1), (x2, y2) in segments:
    if min(y1, y2) >= BY and max(x1, x2) <= LX + 60:
        continue
    for (l, r, t, b, s) in text_boxes:
        if (min(x1, x2) - 6 < r and max(x1, x2) + 6 > l and min(y1, y2) - 6 < b and max(y1, y2) + 6 > t):
            problems.append(f"arrow ({x1},{y1})-({x2},{y2}) crosses label '{s}'")

if problems:
    print("Layout problems:\n  " + "\n  ".join(problems), file=sys.stderr)
    sys.exit(1)
open(OUT, "w").write("\n".join(out) + "\n")
print(f"wrote {OUT}")

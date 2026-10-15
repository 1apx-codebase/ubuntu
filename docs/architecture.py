#!/usr/bin/env python3
"""Generate docs/architecture.svg, the architecture diagram in the README.

Every label is placed from its box's geometry (centered horizontally, baselines on a
fixed grid), and its width is measured with Arimo's real glyph advances (Arimo has the
same metrics as Arial/Liberation Sans) so the script can fail if any label doesn't fit.
Usage: python3 docs/architecture.py docs/architecture.svg <path to Arimo[wght].ttf>
Arimo: https://github.com/google/fonts/tree/main/ofl/arimo (only its metrics are read).
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


def arrow(points, color, marker, dash=None, both=False):
    segments.extend(zip(points, points[1:]))
    d = " ".join(("M" if i == 0 else "L") + f"{px},{py}" for i, (px, py) in enumerate(points))
    da = f' stroke-dasharray="{dash}"' if dash else ""
    ms = f' marker-start="url(#{marker}-start)"' if both else ""
    out.append(f'  <path d="{d}" fill="none" stroke="{color}" stroke-width="2"{da}{ms} marker-end="url(#{marker})"/>')


# ---------- layout ----------
W, H = 1200, 916
MARKERS = {"m-user": C["user"], "m-db": C["db"], "m-admin": C["admin"], "m-net": C["net"]}

out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'font-family="{FONT_STACK}" fill="{C["ink"]}" role="img" aria-labelledby="title desc">')
out.append('  <title id="title">k8-1apx: Kubernetes cluster for Oracle ORDS</title>')
out.append('  <desc id="desc">Three Ubuntu VMs on Proxmox: k8-control runs the control plane; '
           'k8-worker-1 and k8-worker-2 each run one ORDS pod in the ords namespace, behind a MetalLB '
           'LoadBalancer IP 192.168.1.180, connected to the existing Oracle database node.1apx.com:1521.</desc>')
out.append("  <defs>")
for mid, col in MARKERS.items():
    out.append(f'    <marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
               f'<path d="M0,0 L10,5 L0,10 z" fill="{col}"/></marker>')
    out.append(f'    <marker id="{mid}-start" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
               f'<path d="M0,0 L10,5 L0,10 z" fill="{col}"/></marker>')
out.append("  </defs>")
rect(0.5, 0.5, W - 1, H - 1, "#ffffff", "#d1d5db", r=12, sw=1)

# Title
text(W / 2, 40, "k8-1apx: Kubernetes cluster for Oracle ORDS", 22, bold=True, box=(0, W))
text(W / 2, 62, "Kubernetes 1.36.5 · kubeadm · containerd · Calico · MetalLB · Ubuntu 26.04 VMs on Proxmox",
     13, color=C["muted"], box=(0, W))

# Row 1: outside the Proxmox host
ROW_Y, ROW_H = 84, 72
admin = (40, ROW_Y, 250, ROW_H)
users = (330, ROW_Y, 250, ROW_H)
router = (620, ROW_Y, 230, ROW_H)
inet = (890, ROW_Y, 270, ROW_H)
labeled_box(*admin, ["Admin (vaviles)", "kubectl · SSH · git"], C["vm"], C["frame"])
labeled_box(*users, ["Users", "https://ords.1apx.com/apps/"], C["vm"], C["frame"])
labeled_box(*router, ["Router 192.168.1.1", "LAN gateway · DNS"], C["vm"], C["frame"])
labeled_box(*inet, ["Internet", "container-registry.oracle.com", "download.oracle.com"],
            C["ext"], C["extline"], gap=17)

# Proxmox host frame
FX, FY, FW, FH = 30, 196, 1140, 548
rect(FX, FY, FW, FH, "none", C["frame"], r=12, dash="7 5", sw=1.5)
# Frame label: a tag on the frame's bottom edge, centered under k8-control, clear of arrows
flabel = "Proxmox VE host · LAN 192.168.1.0/24 (bridge vmbr0)"
fw = text_width(flabel, 12.5, bold=True) + 24
fcx = 220
rect(round(fcx - fw / 2, 1), FY + FH - 12, round(fw, 1), 24, "#ffffff", C["frame"], r=12)
text(fcx, FY + FH + 4.5, flabel, 12.5, bold=True, color=C["frame"], box=(fcx - fw / 2, fcx + fw / 2))

# VMs
VY, VH = 300, 428
ctl = (55, VY, 330, VH)
w1 = (420, VY, 345, VH)
w2 = (800, VY, 345, VH)
for (x, y, w, h) in (ctl, w1, w2):
    rect(x, y, w, h, C["vm"], C["frame"], r=10)


def vm_header(vm, name, detail):
    x, y, w, _ = vm
    text(x + w / 2, y + 26, name, 16, bold=True, box=(x, x + w))
    text(x + w / 2, y + 46, detail, 12, color=C["muted"], box=(x, x + w))


def pill(vm, y, h, lines, size=12.5):
    x, _, w, _ = vm
    labeled_box(x + 20, y, w - 40, h, lines, C["pill"], C["line"], r=6, first_bold=False, size=size, gap=17)


vm_header(ctl, "k8-control", "192.168.1.170 · control plane · 8 vCPU, 7.2 GB")
pill(ctl, 362, 52, ["kube-apiserver :6443", "Secrets encrypted · audit log"])
pill(ctl, 424, 34, ["etcd (firewalled: k8-control only)"])
pill(ctl, 468, 34, ["scheduler · controller-manager"])
pill(ctl, 512, 34, ["CoreDNS · Calico · kube-proxy"])
pill(ctl, 556, 34, ["kubelet · containerd"])
pill(ctl, 600, 34, ["etcd backups (daily, 14 days)"])
text(ctl[0] + ctl[2] / 2, 668, "Tainted: runs no workloads", 12.5, color=C["muted"], italic=True,
     box=(ctl[0], ctl[0] + ctl[2]))
text(ctl[0] + ctl[2] / 2, 690, "ufw: SSH and API from the LAN only", 12.5, color=C["muted"], italic=True,
     box=(ctl[0], ctl[0] + ctl[2]))

# Namespace box spanning both workers' ORDS pods
NS_Y, NS_H = 362, 206
ns = (435, NS_Y, 695, NS_H)
for vm, name, ip in ((w1, "k8-worker-1", "192.168.1.171"), (w2, "k8-worker-2", "192.168.1.172")):
    vm_header(vm, name, f"{ip} · worker · 4 vCPU, 8 GB")
rect(*ns, "none", C["ns"], r=10, dash="6 4", sw=1.5)
for vm in (w1, w2):
    x, _, w, _ = vm
    labeled_box(x + 30, NS_Y + 38, w - 60, 152,
                ["ORDS pod", "ords:26.2.3 (pinned by digest)", "init: apex-images, config",
                 "ords serve · HTTPS 8443 · HTTP 8080", "UID 54321 · no capabilities"],
                C["pod"], C["podline"], r=8, gap=22)
# Namespace tag, centered on the box's top edge
tag = "namespace ords · NetworkPolicy"
tw = text_width(tag, 12.5, bold=True) + 24
tx = ns[0] + ns[2] / 2 - tw / 2
rect(round(tx, 1), NS_Y - 12, round(tw, 1), 24, "#ffffff", C["ns"], r=12)
text(ns[0] + ns[2] / 2, NS_Y + 4.5, tag, 12.5, bold=True, color=C["ns"], box=(tx, tx + tw))
for vm in (w1, w2):
    pill(vm, 582, 34, ["kubelet · containerd · kube-proxy"])
    pill(vm, 626, 34, ["Calico node · MetalLB speaker"])
    pill(vm, 670, 34, ["/var/cache/ords-apex (APEX images)"])

# Service (MetalLB) above the workers
svc = (420, 214, 725, 64)
labeled_box(*svc, ["Service ords · LoadBalancer · 192.168.1.180 (MetalLB, layer 2)",
                   ":443 → pods 8443 (HTTPS) · :80 → 8080 (redirects to HTTPS) · session affinity"],
            C["pod"], C["podline"], gap=20)

# Oracle database, outside the Proxmox host
db = (607, 784, 350, 64)
labeled_box(*db, ["Oracle database (existing)", "node.1apx.com:1521 · service pdb1"], C["dbfill"], C["db"])

# ---------- arrows ----------
ux = users[0] + users[2] / 2
arrow([(ux, ROW_Y + ROW_H), (ux, svc[1])], C["user"], "m-user")
text(ux + 8, 186, "HTTPS", 12, bold=True, color=C["user"], anchor="start", box=(ux, ux + 80))
# One arrow per worker, on the worker's outer side, clear of the centered titles and the
# namespace tag in the middle, landing on the ORDS pod's top edge
for cx in (w1[0] + 48, w2[0] + w2[2] - 48):
    arrow([(cx, svc[1] + svc[3]), (cx, NS_Y + 38)], C["user"], "m-user")
ax = admin[0] + admin[2] / 2
arrow([(ax, ROW_Y + ROW_H), (ax, ctl[1])], C["admin"], "m-admin")
text(ax + 8, 186, "kubectl :6443 · SSH", 12, bold=True, color=C["admin"], anchor="start", box=(ax, ax + 160))
# Workers to the database: down the gap between the two workers
gx = (w1[0] + w1[2] + w2[0]) / 2
arrow([(gx, NS_Y + NS_H), (gx, db[1])], C["db"], "m-db")
text(gx + 10, 772, "JDBC :1521 · ORDS_PUBLIC_USER", 12, bold=True, color=C["db"], anchor="start",
     box=(gx, W - 30))
# Workers to the internet: up the right margin
rx = 1158
arrow([(w2[0] + w2[2], 450), (rx, 450), (rx, ROW_Y + ROW_H)], C["net"], "m-net", dash="6 4")
text(rx - 8, 186, "HTTPS 443: ORDS image, APEX images", 12, bold=True, color=C["net"], anchor="end",
     box=(rx - 270, rx))

# ---------- legend ----------
LX, LY = 40, 786
rect(LX, LY - 8, 540, 116, "#ffffff", C["line"], r=8, sw=1)
text(LX + 16, LY + 14, "Legend", 13, bold=True, anchor="start", box=(LX, LX + 540))
items = [
    (C["user"], None, "User traffic (HTTPS through MetalLB to ORDS)"),
    (C["db"], None, "Database connection (JDBC, port 1521)"),
    (C["admin"], None, "Administration (kubectl, SSH)"),
    (C["net"], "6 4", "Outbound HTTPS (image pull, APEX download)"),
]
for i, (col, dash, label) in enumerate(items):
    y = LY + 38 + i * 19
    arrow([(LX + 16, y - 4), (LX + 56, y - 4)], col, {C["user"]: "m-user", C["db"]: "m-db",
          C["admin"]: "m-admin", C["net"]: "m-net"}[col], dash=dash)
    text(LX + 68, y, label, 12.5, anchor="start", box=(LX + 60, LX + 540))
out.append("</svg>")

# Overlap check: the legend and the database box must not touch
if LX + 540 + 10 > db[0]:
    problems.append("legend overlaps the database box")

# Every text element must carry an explicit anchor
if any("<text " in line and "text-anchor=" not in line for line in out):
    problems.append("a text element has no explicit text-anchor")
# No arrow segment may cross a label (6px clearance), except the legend's own samples
legend_top = LY - 8
for (x1, y1), (x2, y2) in segments:
    if min(y1, y2) >= legend_top and max(x1, x2) <= LX + 60:
        continue
    for (l, r, t, b, s) in text_boxes:
        if (min(x1, x2) - 6 < r and max(x1, x2) + 6 > l and min(y1, y2) - 6 < b and max(y1, y2) + 6 > t):
            problems.append(f"arrow ({x1},{y1})-({x2},{y2}) crosses label '{s}'")

if problems:
    print("Layout problems:\n  " + "\n  ".join(problems), file=sys.stderr)
    sys.exit(1)
open(OUT, "w").write("\n".join(out) + "\n")
print(f"wrote {OUT}")

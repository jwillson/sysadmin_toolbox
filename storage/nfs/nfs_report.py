#!/usr/bin/env python3
"""nfs_report.py — turn nfsbench.sh result directories into a side-by-side
HTML + Markdown report.

    python3 nfs_report.py results/baseline results/rdma -o nfs-report.html

The first directory is the reference; every later run gets a "% change vs
<first>" column. Works with Python 3.6+ (the python3 on EL7-EL10 and
Ubuntu 24.04/26.04), standard library only.
"""
import argparse
import datetime
import glob
import html
import json
import os
import re
import sys

TEST_ORDER = ["seq_read_1m", "seq_write_1m", "rand_read_4k", "rand_write_4k",
              "mixed_64k_70r", "lat_read_4k", "lat_write_4k"]
TEST_TITLES = {
    "seq_read_1m": "Sequential read, 1 MiB blocks (QD16 x 4 jobs)",
    "seq_write_1m": "Sequential write, 1 MiB blocks (QD16 x 4 jobs)",
    "rand_read_4k": "Random read, 4 KiB (QD32 x 8 jobs)",
    "rand_write_4k": "Random write, 4 KiB (QD32 x 8 jobs)",
    "mixed_64k_70r": "Mixed 70% read / 30% write, 64 KiB (QD16 x 4 jobs)",
    "lat_read_4k": "Latency probe: random read 4 KiB, QD1",
    "lat_write_4k": "Latency probe: random write 4 KiB, QD1",
}

# ------------------------------------------------------------------ parsing

def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def load_json_loose(path):
    """fio sometimes prefixes warnings before the JSON body."""
    txt = read_text(path)
    if not txt:
        return None
    i = txt.find("{")
    if i < 0:
        return None
    try:
        return json.loads(txt[i:])
    except ValueError:
        return None


def parse_kv(path):
    txt = read_text(path)
    if not txt:
        return {}
    out = {}
    for line in txt.split("#### RAW")[0].splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def fio_side(job, side):
    s = job.get(side) or {}
    if not s.get("io_bytes") and not s.get("iops"):
        return None
    clat = s.get("clat_ns") or {}
    pct = clat.get("percentile") or {}
    p99 = pct.get("99.000000")
    return {
        "bw_mib": s.get("bw", 0) / 1024.0,          # fio reports KiB/s
        "iops": s.get("iops", 0.0),
        "lat_mean_us": clat.get("mean", 0) / 1000.0,
        "lat_p99_us": (p99 / 1000.0) if p99 else None,
    }


def parse_fio(path):
    data = load_json_loose(path)
    if not data:
        return None
    jobs = data.get("jobs") or []
    if not jobs:
        return None
    job = jobs[0]  # --group_reporting => one aggregated entry
    return {"read": fio_side(job, "read"), "write": fio_side(job, "write")}


def aggregate_hosts(per_host):
    """Sum throughput across clients; IOPS-weighted mean latency; worst p99."""
    agg = {}
    for side in ("read", "write"):
        vals = [h[side] for h in per_host if h and h.get(side)]
        if not vals:
            agg[side] = None
            continue
        iops = sum(v["iops"] for v in vals)
        mean = (sum(v["lat_mean_us"] * v["iops"] for v in vals) / iops) if iops else 0
        p99s = [v["lat_p99_us"] for v in vals if v["lat_p99_us"] is not None]
        agg[side] = {"bw_mib": sum(v["bw_mib"] for v in vals), "iops": iops,
                     "lat_mean_us": mean, "lat_p99_us": max(p99s) if p99s else None}
    return agg


def parse_mpstat(path):
    """Average CPU busy % and kernel (sys+irq+soft) % from `mpstat 1 N`."""
    txt = read_text(path)
    if not txt:
        return None
    header = None
    for line in txt.splitlines():
        f = line.split()
        if len(f) > 2 and f[0] == "Average:":
            if f[1] == "CPU":
                header = f
            elif f[1] == "all" and header:
                row = dict(zip(header, f))
                try:
                    idle = float(row["%idle"])
                    kern = sum(float(row.get(k, 0)) for k in ("%sys", "%irq", "%soft"))
                    return {"busy": 100.0 - idle, "kernel": kern}
                except (KeyError, ValueError):
                    return None
    return None


def parse_pool_stats(path):
    txt = read_text(path)
    if not txt:
        return None
    cols, tot = None, {}
    for line in txt.splitlines():
        if line.startswith("#"):
            cols = line.lstrip("# ").split()
            continue
        f = line.split()
        if cols and len(f) == len(cols) and all(x.isdigit() for x in f):
            for k, v in zip(cols, f):
                if k != "pool":
                    tot[k] = tot.get(k, 0) + int(v)
    return tot or None


def nfsd_queue_pct(before, after):
    """% of arrivals that found no idle nfsd thread: (arrived - woken) / arrived.

    sockets-enqueued is not used: since EL8's 4.18 kernel it counts every
    enqueue (equal to, or above, packets-arrived), not only those that waited.
    threads-woken counts only wake-ups of a sleeping idle thread on every
    kernel from EL7's 3.10 to current upstream, so this works on all of them.
    """
    if not before or not after:
        return None
    arr = after.get("packets-arrived", 0) - before.get("packets-arrived", 0)
    woke = after.get("threads-woken", 0) - before.get("threads-woken", 0)
    if arr <= 0:
        return None
    return max(0.0, 100.0 * (arr - woke) / arr)


MOUNT_RE = re.compile(r"^device (\S+) mounted on (\S+) with fstype (nfs\S*)")
OP_RE = re.compile(r"^\s+([A-Z_]+):\s+([\d\s]+)$")


def parse_mountstats(path, mountpoint):
    """Per-op counters for the NFS mount covering `mountpoint`."""
    txt = read_text(path)
    if not txt:
        return None
    blocks, cur = [], None
    for line in txt.splitlines():
        m = MOUNT_RE.match(line)
        if m:
            cur = {"mnt": m.group(2).replace("\\040", " "), "ops": {}, "xprt": None}
            blocks.append(cur)
            continue
        if line.startswith("device "):
            cur = None
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("xprt:"):
            cur["xprt"] = s.split()[1]
        m = OP_RE.match(line)
        if m:
            cur["ops"][m.group(1)] = [int(x) for x in m.group(2).split()]
    best = None
    for b in blocks:
        mp = b["mnt"].rstrip("/") or "/"
        if mountpoint == mp or mountpoint.startswith(mp.rstrip("/") + "/"):
            if best is None or len(mp) > len(best["mnt"]):
                best = b
    return best


def rpc_times(before, after, op):
    """Average RTT and execute time (ms) per RPC between two snapshots."""
    if not before or not after:
        return None
    b, a = before["ops"].get(op), after["ops"].get(op)
    if not a or len(a) < 8:
        return None
    b = b or [0] * len(a)
    ops = a[0] - b[0]
    if ops <= 0:
        return None
    return {"ops": ops, "rtt_ms": (a[6] - b[6]) / ops, "exec_ms": (a[7] - b[7]) / ops}


def parse_perftest(path):
    txt = read_text(path)
    if not txt:
        return None
    lines = txt.splitlines()
    for i, line in enumerate(lines):
        if "#bytes" not in line:
            continue
        kind = "lat" if "t_typical" in line or "t_avg" in line else "bw"
        for row in lines[i + 1:]:
            f = row.split()
            try:
                nums = [float(x) for x in f]
            except ValueError:
                continue
            if kind == "bw" and len(nums) >= 4:
                bw = nums[3]
                if "MB/sec" in line:
                    bw = bw * 8 * 1.048576 / 1000.0
                return {"kind": "bw", "gbps": bw}
            if kind == "lat" and len(nums) >= 6:
                return {"kind": "lat", "typical_us": nums[4], "avg_us": nums[5],
                        "p99_us": nums[7] if len(nums) > 7 else None}
    return None


def parse_iperf(path):
    data = load_json_loose(path)
    if not data:
        return None
    end = data.get("end") or {}
    s = end.get("sum_received") or end.get("sum") or {}
    bps = s.get("bits_per_second")
    return bps / 1e9 if bps else None


def load_run(path):
    label = os.path.basename(os.path.normpath(path))
    run = {"label": label, "path": path, "env": {"server": {}, "client": {}},
           "fio": {}, "fabric": {}, "hosts": []}
    for f in sorted(glob.glob(os.path.join(path, "env", "*.txt"))):
        kv = parse_kv(f)
        role = kv.get("role")
        if role in run["env"] and not run["env"][role]:
            run["env"][role] = kv

    fab = os.path.join(path, "fabric")
    run["fabric"]["iperf3_gbps"] = parse_iperf(os.path.join(fab, "iperf3_tcp.json"))
    for t in ("ib_write_bw", "ib_read_bw", "ib_read_lat"):
        run["fabric"][t] = parse_perftest(os.path.join(fab, t + ".txt"))

    hosts = sorted(d for d in os.listdir(os.path.join(path, "fio"))
                   if os.path.isdir(os.path.join(path, "fio", d))) \
        if os.path.isdir(os.path.join(path, "fio")) else []
    run["hosts"] = hosts
    tests = set()
    for h in hosts:
        tests.update(os.path.splitext(os.path.basename(p))[0]
                     for p in glob.glob(os.path.join(path, "fio", h, "*.json")))
    for t in tests:
        per_host, cpu, rd, wr = [], [], [], []
        for h in hosts:
            per_host.append(parse_fio(os.path.join(path, "fio", h, t + ".json")))
            cdir = os.path.join(path, "client", h)
            c = parse_mpstat(os.path.join(cdir, t + ".mpstat.txt"))
            if c:
                cpu.append(c)
            meta = parse_kv(os.path.join(cdir, "meta.txt"))
            mp = meta.get("mountpoint", "")
            mb = parse_mountstats(os.path.join(cdir, t + ".mountstats.before"), mp)
            ma = parse_mountstats(os.path.join(cdir, t + ".mountstats.after"), mp)
            for op, acc in (("READ", rd), ("WRITE", wr)):
                r = rpc_times(mb, ma, op)
                if r:
                    acc.append(r)
            if ma and ma.get("xprt"):
                run.setdefault("xprt", ma["xprt"])
        sdir = os.path.join(path, "server")
        entry = {
            "fio": aggregate_hosts(per_host),
            "client_cpu": (sum(c["busy"] for c in cpu) / len(cpu)) if cpu else None,
            "server_cpu": parse_mpstat(os.path.join(sdir, t + ".mpstat.txt")),
            "nfsd_queue_pct": nfsd_queue_pct(
                parse_pool_stats(os.path.join(sdir, t + ".pool_stats.before")),
                parse_pool_stats(os.path.join(sdir, t + ".pool_stats.after"))),
        }
        for name, acc in (("rpc_read", rd), ("rpc_write", wr)):
            ops = sum(r["ops"] for r in acc)
            entry[name] = ({"rtt_ms": sum(r["rtt_ms"] * r["ops"] for r in acc) / ops,
                            "exec_ms": sum(r["exec_ms"] * r["ops"] for r in acc) / ops}
                           if ops else None)
        run["fio"][t] = entry
    meta0 = parse_kv(os.path.join(path, "client", hosts[0], "meta.txt")) if hosts else {}
    run["meta"] = meta0
    return run

# ------------------------------------------------------------------ model

def g(d, *keys):
    for k in keys:
        if d is None:
            return None
        d = d.get(k) if isinstance(d, dict) else None
    return d


def pct_change(base, new):
    if base is None or new is None or base == 0:
        return None
    return 100.0 * (new - base) / base


def fmt_num(v, nd=0):
    if v is None:
        return "—"
    if nd == 0:
        return "{:,.0f}".format(v)
    return "{:,.{}f}".format(v, nd)


def build_rows(runs):
    """Return report sections: list of (title, note, rows); row = dict."""
    sections = []

    # Configuration
    cfg = [
        ("server", "os", "Server OS"), ("server", "kernel", "Server kernel"),
        ("server", "platform", "Server platform"),
        ("server", "cpu_model", "Server CPU"), ("server", "cpu_sockets", "Server sockets"),
        ("server", "cpu_logical", "Server logical CPUs"), ("server", "mem_gib", "Server RAM (GiB)"),
        ("server", "storage", "Exported filesystems"),
        ("server", "arc_max_gib", "ZFS ARC max (GiB)"), ("server", "zfs_version", "ZFS version"),
        ("server", "nfsd_threads", "nfsd threads"), ("server", "nfsd_listeners", "nfsd listeners"),
        ("server", "sunrpc_pool_mode", "sunrpc pool_mode"),
        ("server", "hca", "Server HCA (type, firmware)"), ("server", "ib_driver", "Server HCA driver"),
        ("server", "pcie_link", "Server HCA PCIe link"), ("server", "ib_rate", "Server IB link rate"),
        ("server", "ib_active_mtu", "Server IB active MTU"),
        ("server", "ipoib_mode", "Server IPoIB mode"), ("server", "ipoib_mtu", "Server IPoIB MTU"),
        ("client", "ib_active_mtu", "Client IB active MTU"),
        ("client", "ipoib_mode", "Client IPoIB mode"), ("client", "ipoib_mtu", "Client IPoIB MTU"),
        ("client", "nfs_mount_opts", "Client mount options"),
    ]
    rows = [{"name": label, "vals": [g(r, "env", role, key) or "—" for r in runs],
             "text": True} for role, key, label in cfg]
    # Drop rows that are empty for every run (e.g. ZFS rows on a non-ZFS server)
    rows = [r for r in rows if any(v != "—" for v in r["vals"])]
    rows.insert(0, {"name": "NFS transport (from mountstats)",
                    "vals": [r.get("xprt") or "—" for r in runs], "text": True})
    rows.insert(1, {"name": "Client hosts in run",
                    "vals": [", ".join(r["hosts"]) or "—" for r in runs], "text": True})
    rows.insert(2, {"name": "fio size / runtime per test",
                    "vals": ["{} per job / {}s".format(g(r, "meta", "size_per_job") or "?",
                                                      g(r, "meta", "runtime") or "?") for r in runs],
                    "text": True})
    sections.append(("Configuration", "What was actually running for each capture.", rows))

    # Fabric
    rows = [
        {"name": "IPoIB TCP throughput (iperf3, 8 streams)", "unit": "Gb/s", "nd": 1,
         "better": "up", "vals": [g(r, "fabric", "iperf3_gbps") for r in runs]},
        {"name": "RDMA write bandwidth (ib_write_bw)", "unit": "Gb/s", "nd": 1, "better": "up",
         "vals": [g(r, "fabric", "ib_write_bw", "gbps") for r in runs]},
        {"name": "RDMA read bandwidth (ib_read_bw)", "unit": "Gb/s", "nd": 1, "better": "up",
         "vals": [g(r, "fabric", "ib_read_bw", "gbps") for r in runs]},
        {"name": "RDMA read latency, typical (ib_read_lat)", "unit": "µs", "nd": 2,
         "better": "down", "vals": [g(r, "fabric", "ib_read_lat", "typical_us") for r in runs]},
    ]
    rate = next((g(r, "env", "server", "ib_rate") or g(r, "env", "client", "ib_rate")
                 for r in runs if g(r, "env", "server", "ib_rate") or g(r, "env", "client", "ib_rate")),
                None)
    sections.append(("Fabric ceiling",
                     "Raw network capability, independent of NFS and the storage. "
                     + ("Link rate: {}. ".format(rate) if rate else "")
                     + "NFS cannot exceed what these show.", rows))

    # Per-test
    tests = [t for t in TEST_ORDER if any(t in r["fio"] for r in runs)]
    tests += sorted({t for r in runs for t in r["fio"]} - set(tests))
    for t in tests:
        rows = []
        for side in ("read", "write"):
            if not any(g(r, "fio", t, "fio", side) for r in runs):
                continue
            S = side.capitalize()
            rows += [
                {"name": S + " bandwidth", "unit": "MiB/s", "nd": 0, "better": "up",
                 "bar": t.startswith("seq") or t.startswith("mixed"),
                 "vals": [g(r, "fio", t, "fio", side, "bw_mib") for r in runs]},
                {"name": S + " IOPS", "unit": "IOPS", "nd": 0, "better": "up",
                 "bar": t.startswith("rand") or t.startswith("lat"),
                 "vals": [g(r, "fio", t, "fio", side, "iops") for r in runs]},
                {"name": S + " latency, mean", "unit": "µs", "nd": 1, "better": "down",
                 "vals": [g(r, "fio", t, "fio", side, "lat_mean_us") for r in runs]},
                {"name": S + " latency, p99", "unit": "µs", "nd": 1, "better": "down",
                 "vals": [g(r, "fio", t, "fio", side, "lat_p99_us") for r in runs]},
                {"name": "NFS " + side.upper() + " RPC round-trip (client view)", "unit": "ms",
                 "nd": 3, "better": "down",
                 "vals": [g(r, "fio", t, "rpc_" + side, "rtt_ms") for r in runs]},
            ]
        rows += [
            {"name": "Server CPU busy", "unit": "%", "nd": 1, "better": "down",
             "vals": [g(r, "fio", t, "server_cpu", "busy") for r in runs]},
            {"name": "Server CPU in kernel (sys+irq+soft)", "unit": "%", "nd": 1, "better": "down",
             "vals": [g(r, "fio", t, "server_cpu", "kernel") for r in runs]},
            {"name": "Client CPU busy (avg of clients)", "unit": "%", "nd": 1, "better": "down",
             "vals": [g(r, "fio", t, "client_cpu") for r in runs]},
            {"name": "nfsd arrivals that found no idle thread", "unit": "%", "nd": 2,
             "better": "down", "vals": [g(r, "fio", t, "nfsd_queue_pct") for r in runs]},
        ]
        sections.append((TEST_TITLES.get(t, t), "fio test: " + t, rows))
    return tests, sections


def headline(runs, tests):
    """Pick one primary metric per test for the summary table."""
    out = []
    for t in tests:
        if t.startswith("seq") or t.startswith("mixed"):
            side = "write" if "write" in t else "read"
            out.append((TEST_TITLES.get(t, t).split(",")[0] + " — bandwidth", "MiB/s", 0, "up",
                        [g(r, "fio", t, "fio", side, "bw_mib") for r in runs]))
        elif t.startswith("rand"):
            side = "write" if "write" in t else "read"
            out.append((TEST_TITLES.get(t, t).split(",")[0] + " — IOPS", "IOPS", 0, "up",
                        [g(r, "fio", t, "fio", side, "iops") for r in runs]))
        elif t.startswith("lat"):
            side = "write" if "write" in t else "read"
            out.append(("QD1 " + TEST_TITLES.get(t, t).split(":")[1].strip().split(",")[0]
                        + " — mean latency", "µs",
                        1, "down", [g(r, "fio", t, "fio", side, "lat_mean_us") for r in runs]))
    return out

# ------------------------------------------------------------------ rendering

CSS = """
:root{--bg:#fbfaf8;--fg:#1d1d1b;--muted:#6b6a66;--line:#e4e1db;--card:#fff;
--good:#1f7a4d;--bad:#b3362c;--bar0:#9aa3ad;--bar1:#2f6fb0;--bar2:#b07a2f;--bar3:#6b4fa3}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ecebe7;--muted:#a09e98;
--line:#2f2e2b;--card:#1f1f1d;--good:#5cc28d;--bad:#ef7a6e;--bar0:#6d7680;--bar1:#5b9bd8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:26px;margin:0 0 4px}h2{font-size:18px;margin:36px 0 2px}
.sub,.note{color:var(--muted);font-size:13px;margin:0 0 10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;overflow-x:auto}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:8px 12px;border-bottom:1px solid var(--line);text-align:right;vertical-align:top}
th:first-child,td:first-child{text-align:left}tr:last-child td{border-bottom:0}
th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);font-weight:600}
td.txt{text-align:left;font-family:ui-monospace,Menlo,monospace;font-size:12px;word-break:break-word}
.unit{color:var(--muted);font-size:12px}.up{color:var(--good);font-weight:600}
.down{color:var(--bad);font-weight:600}.flat{color:var(--muted)}
.bars{display:grid;gap:4px;padding:10px 12px;border-bottom:1px solid var(--line)}
.bar{display:grid;grid-template-columns:120px 1fr 110px;gap:8px;align-items:center;font-size:12px}
.bar i{display:block;height:12px;border-radius:3px}.bar span:last-child{text-align:right}
.cfg th{text-align:left}
footer{margin-top:40px;color:var(--muted);font-size:12px}
"""

BAR_COLORS = ["var(--bar0)", "var(--bar1)", "var(--bar2)", "var(--bar3)"]


def delta_cell(base, new, better):
    p = pct_change(base, new)
    if p is None:
        return '<td class="flat">—</td>', "—"
    good = (p > 0) == (better == "up")
    cls = "flat" if abs(p) < 2 else ("up" if good else "down")
    s = "{:+.1f}%".format(p)
    return '<td class="{}">{}</td>'.format(cls, s), s


def render_html(runs, tests, sections, title):
    labels = [r["label"] for r in runs]
    esc = html.escape
    out = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
           '<meta name="viewport" content="width=device-width,initial-scale=1">',
           '<title>{}</title><style>{}</style></head><body><main>'.format(esc(title), CSS),
           '<h1>{}</h1>'.format(esc(title)),
           '<p class="sub">Runs: {} · generated {}</p>'.format(
               " → ".join(esc(l) for l in labels),
               datetime.datetime.now().strftime("%Y-%m-%d %H:%M"))]

    def head(extra_delta=True):
        h = '<tr><th>Metric</th>' + "".join('<th>{}</th>'.format(esc(l)) for l in labels)
        if extra_delta and len(runs) > 1:
            h += "".join('<th>Δ {} vs {}</th>'.format(esc(l), esc(labels[0])) for l in labels[1:])
        return h + "</tr>"

    # Summary
    hl = headline(runs, tests)
    if hl:
        out.append('<h2>Summary</h2><p class="note">One headline number per test. Green = better.</p>')
        out.append('<div class="card"><table>' + head())
        for name, unit, nd, better, vals in hl:
            out.append('<tr><td>{} <span class="unit">{}</span></td>'.format(esc(name), esc(unit)))
            out.append("".join("<td>{}</td>".format(fmt_num(v, nd)) for v in vals))
            for v in vals[1:]:
                out.append(delta_cell(vals[0], v, better)[0])
            out.append("</tr>")
        out.append("</table></div>")

    for title_s, note, rows in sections:
        out.append('<h2>{}</h2><p class="note">{}</p><div class="card">'.format(
            esc(title_s), esc(note)))
        bar_rows = [r for r in rows if r.get("bar") and any(v for v in r["vals"])]
        for br in bar_rows:
            mx = max(v or 0 for v in br["vals"]) or 1
            out.append('<div class="bars"><div class="unit">{} ({})</div>'.format(
                esc(br["name"]), esc(br["unit"])))
            for i, (l, v) in enumerate(zip(labels, br["vals"])):
                w = 100.0 * (v or 0) / mx
                out.append('<div class="bar"><span>{}</span><i style="width:{:.1f}%;background:{}"></i>'
                           '<span>{}</span></div>'.format(esc(l), w, BAR_COLORS[i % 4],
                                                          fmt_num(v, br["nd"])))
            out.append("</div>")
        is_text = all(r.get("text") for r in rows)
        out.append('<table class="{}">'.format("cfg" if is_text else "num") + head(not is_text))
        for r in rows:
            if r.get("text"):
                out.append('<tr><td>{}</td>{}</tr>'.format(
                    esc(r["name"]), "".join('<td class="txt">{}</td>'.format(esc(str(v)))
                                            for v in r["vals"])))
                continue
            if all(v is None for v in r["vals"]):
                continue
            out.append('<tr><td>{} <span class="unit">{}</span></td>'.format(
                esc(r["name"]), esc(r["unit"])))
            out.append("".join("<td>{}</td>".format(fmt_num(v, r["nd"])) for v in r["vals"]))
            for v in r["vals"][1:]:
                out.append(delta_cell(r["vals"][0], v, r["better"])[0])
            out.append("</tr>")
        out.append("</table></div>")

    out.append('<footer>Raw data: {}. Throughput is summed across clients; mean latency is '
               'IOPS-weighted; p99 is the worst client. MiB/s = 1,048,576 bytes/s.</footer>'.format(
                   ", ".join(esc(r["path"]) for r in runs)))
    out.append("</main></body></html>")
    return "\n".join(out)


def render_md(runs, tests, sections, title):
    labels = [r["label"] for r in runs]
    L = ["# " + title, "",
         "Runs: " + " → ".join(labels) + " · generated " +
         datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), ""]

    def header(delta=True):
        cols = ["Metric"] + labels
        if delta and len(runs) > 1:
            cols += ["Δ {} vs {}".format(l, labels[0]) for l in labels[1:]]
        return ["| " + " | ".join(cols) + " |",
                "|" + "|".join(["---"] + ["---:"] * (len(cols) - 1)) + "|"]

    hl = headline(runs, tests)
    if hl:
        L += ["## Summary", ""] + header()
        for name, unit, nd, better, vals in hl:
            cells = [fmt_num(v, nd) for v in vals] + [delta_cell(vals[0], v, better)[1] for v in vals[1:]]
            L.append("| {} ({}) | {} |".format(name, unit, " | ".join(cells)))
        L.append("")
    for title_s, note, rows in sections:
        is_text = all(r.get("text") for r in rows)
        L += ["## " + title_s, "", "_" + note + "_", ""] + header(not is_text)
        for r in rows:
            if r.get("text"):
                L.append("| {} | {} |".format(r["name"], " | ".join(
                    "`{}`".format(v) if v != "—" else v for v in r["vals"])))
                continue
            if all(v is None for v in r["vals"]):
                continue
            cells = [fmt_num(v, r["nd"]) for v in r["vals"]]
            cells += [delta_cell(r["vals"][0], v, r["better"])[1] for v in r["vals"][1:]]
            L.append("| {} ({}) | {} |".format(r["name"], r["unit"], " | ".join(cells)))
        L.append("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="result dirs, reference first (e.g. results/baseline)")
    ap.add_argument("-o", "--output", default="nfs-report.html", help="HTML output path")
    ap.add_argument("-t", "--title", default="NFS performance report")
    a = ap.parse_args()
    runs = []
    for p in a.runs:
        if not os.path.isdir(p):
            sys.exit("not a directory: " + p)
        runs.append(load_run(p))
    tests, sections = build_rows(runs)
    with open(a.output, "w") as f:
        f.write(render_html(runs, tests, sections, a.title))
    md = os.path.splitext(a.output)[0] + ".md"
    with open(md, "w") as f:
        f.write(render_md(runs, tests, sections, a.title))
    print("wrote", a.output, "and", md)


if __name__ == "__main__":
    main()

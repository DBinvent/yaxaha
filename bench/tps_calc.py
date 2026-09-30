#!/usr/bin/env python3
"""bench/tps_calc.py — pgbench TPS from a CPU's estimated FLOPS.

    python3 bench/tps_calc.py cpu
    python3 .../tps_calc.py predict --config C1 --clients 8
    python3 .../tps_calc.py predict --cores 16 --ghz 3.0 --isa avx512 --clients 16
    python3 .../tps_calc.py calibrate --measure --clients 4
    python3 .../tps_calc.py normalize --tps 4200 --clients 8
    python3 .../tps_calc.py required --tps 20000 --config CN --nodes 10

WHAT THIS IS, STATED UP FRONT: pgbench executes no floating point. TFLOPS is
used here as a *capacity index* — cores x clock x SIMD width, which is the
thing that actually varies between the machines in the rig — not as a claim
that OLTP throughput is FP-bound. The number that turns capacity into TPS (A,
below) is therefore never guessed: it comes from a measured run, and the tool
refuses to print an absolute TPS until one exists.

Why it exists (BENCH.md §0): up to ten hardware nodes, and "homogeneous, or
say so". A synchronous protocol runs at the speed of its slowest participant,
so a scale curve that bends when node 7 joins may be describing node 7. This
gives every node a capacity number before the run, and afterwards divides
measured TPS by it (`normalize`), so the curve is about YaXAHA rather than
about which box got which CPU.

THE MODEL, in full — so it can be argued with:

    peak_tflops = sockets x cores x GHz x flops_per_cycle(ISA) / 1000
    tps         = A x peak_tflops x clients / (clients + c0)

A and c0 are fitted from measured anchors, per configuration. The second line
was going to be `tps = k x peak x min(clients, cores)/cores` — one client per
busy backend, cores as the ceiling — and the first three measured anchors
refuted it: 4 clients on 4 cores gave 1159 tps and 8 gave 1846, a 59% gain
where that rule predicts none. Oversubscription paying off is backends
blocking on WAL fsync while others compute, so the model needed a shape with a
soft knee. c0 is the client count reaching half the ceiling; over 4/8/16
clients the hyperbola lands within 4.9% rms.

The linear rule survives only as the fallback when a configuration has a
single anchor, where one client count cannot identify c0 — and it says so in
the output rather than pretending to a curve.

Everything printed is tagged MEASURED (from bench/calibration.json) or
PREDICTED (from BENCH.md §7, which are predictions written before the run).
Nothing here reads a benchmark result out of the air.
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAL_FILE = HERE / "calibration.json"
STREAM_SQL = HERE / "stream.sql"

# --------------------------------------------------------------------------
# CPU capacity
# --------------------------------------------------------------------------

# Double-precision FLOPs per cycle per core. An FMA does a multiply and an add,
# hence the x2; two FMA units is the Haswell-and-later Intel / Zen2-and-later
# AMD shape, and is wrong for the parts that have one (some Skylake-SP, Zen1).
# Override with --fma-units when it matters; the derivation is printed so a
# wrong assumption is visible rather than baked in.
ISA_LANES_DP = {  # ISA -> SIMD width in bits
    "avx512": 512,
    "avx2": 256,
    "avx": 256,
    "sse2": 128,
    "scalar": 64,
}


def flops_per_cycle(isa: str, fma_units: int) -> float:
    """DP FLOPs/cycle/core for an ISA. `avx` has no FMA: add and mul issue on
    separate ports, so it is 2 ops/cycle of `lanes` each, not 2 per FMA unit."""
    if isa not in ISA_LANES_DP:
        raise SystemExit(f"unknown --isa {isa!r}; one of {', '.join(ISA_LANES_DP)}")
    lanes = ISA_LANES_DP[isa] / 64.0
    if isa in ("avx", "sse2", "scalar"):
        return lanes * 2.0  # one add port + one mul port
    return lanes * 2.0 * fma_units  # FMA counts as two flops


def _proc_cpuinfo() -> list[dict]:
    try:
        text = Path("/proc/cpuinfo").read_text()
    except OSError:
        return []
    blocks = []
    cur: dict = {}
    for line in text.splitlines():
        if not line.strip():
            if cur:
                blocks.append(cur)
                cur = {}
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            cur[k.strip()] = v.strip()
    if cur:
        blocks.append(cur)
    return blocks


def _nominal_ghz(model: str) -> float | None:
    """Intel and AMD both put the nominal clock in the model string
    ('... @ 3.40GHz'). It is the honest default: max turbo is not sustainable
    all-core, and several Intel generations clock *down* under wide AVX."""
    m = re.search(r"@\s*([\d.]+)\s*GHz", model)
    return float(m.group(1)) if m else None


def _sysfs_max_ghz() -> float | None:
    p = Path("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
    try:
        return int(p.read_text().strip()) / 1_000_000.0
    except (OSError, ValueError):
        return None


def detect_cpu() -> dict:
    blocks = _proc_cpuinfo()
    if not blocks:
        raise SystemExit("cannot read /proc/cpuinfo — pass --cores/--ghz/--isa instead")

    model = blocks[0].get("model name", "unknown")
    flags = set(blocks[0].get("flags", "").split())

    sockets = len({b.get("physical id", "0") for b in blocks})
    phys = {(b.get("physical id", "0"), b.get("core id", str(i))) for i, b in enumerate(blocks)}
    cores = len(phys)
    threads = len(blocks)

    if "avx512f" in flags:
        isa = "avx512"
    elif "avx2" in flags and "fma" in flags:
        isa = "avx2"
    elif "avx" in flags:
        isa = "avx"
    elif "sse2" in flags:
        isa = "sse2"
    else:
        isa = "scalar"

    nominal = _nominal_ghz(model)
    maxghz = _sysfs_max_ghz()
    current = None
    try:
        current = round(float(blocks[0].get("cpu MHz", "0")) / 1000.0, 3) or None
    except ValueError:
        pass

    return {
        "model": model,
        "sockets": sockets,
        "cores": cores,
        "threads": threads,
        "smt": threads > cores,
        "isa": isa,
        "ghz_nominal": nominal,
        "ghz_max": maxghz,
        "ghz_current": current,
        "kernel": platform.release(),
        "hostname": platform.node(),
    }


def cpu_from_args(args) -> dict:
    """Detected values, with every field overridable — the point is to price a
    node you have specs for but no shell on."""
    cpu = detect_cpu() if not args.no_detect else {
        "model": "(described)", "sockets": 1, "cores": None, "threads": None,
        "smt": False, "isa": None, "ghz_nominal": None, "ghz_max": None,
        "ghz_current": None, "kernel": None, "hostname": None,
    }
    if args.model:
        cpu["model"] = args.model
    if args.sockets:
        cpu["sockets"] = args.sockets
    if args.cores:
        cpu["cores"] = args.cores
    if args.isa:
        cpu["isa"] = args.isa
    if args.ghz:
        cpu["ghz"] = args.ghz
        cpu["ghz_source"] = "--ghz"
    else:
        ghz = cpu.get("ghz_nominal") or cpu.get("ghz_max") or cpu.get("ghz_current")
        cpu["ghz"] = ghz
        cpu["ghz_source"] = (
            "model string (nominal)" if cpu.get("ghz_nominal")
            else "cpufreq max" if cpu.get("ghz_max") else "cpu MHz (current)"
        )
    for field in ("cores", "isa", "ghz"):
        if not cpu.get(field):
            raise SystemExit(f"could not determine {field} — pass --{field}")

    cpu["fma_units"] = args.fma_units
    cpu["flops_per_cycle"] = flops_per_cycle(cpu["isa"], args.fma_units)
    cpu["peak_tflops"] = (
        cpu["sockets"] * cpu["cores"] * cpu["ghz"] * cpu["flops_per_cycle"] / 1000.0
    )
    return cpu


def usable_tflops(cpu: dict, clients: int) -> float:
    total_cores = cpu["sockets"] * cpu["cores"]
    active = min(clients, total_cores)
    return cpu["peak_tflops"] * active / total_cores


# --------------------------------------------------------------------------
# Configurations — BENCH.md §1 and §7
# --------------------------------------------------------------------------

CONFIGS = ("S1", "S1x", "C1", "CN")

# Ratio to S1, as *predicted* in BENCH.md §7. Ranges, never points: a point
# would read like a result. None means the plan makes no prediction.
PREDICTED_VS_S1 = {
    "S1": (1.0, 1.0),          # baseline, by definition
    "S1x": None,               # "the extension costs something" — unquantified
    "C1": (0.40, 0.80),        # "C1 is 20-60% below S1"
    "CN": None,                # per-node; use CN_EFFICIENCY against C1
}

# CN aggregate = N x C1 x efficiency. §7 predicts >= 0.8 at N=3 and a bend
# somewhere between 3 and 10 — naming where is what the rig is for, so above
# N=3 the lower bound is not claimed.
CN_EFFICIENCY = {"disjoint": (0.8, 1.0), "overlapping": (0.0, 1.0)}


# --------------------------------------------------------------------------
# Calibration store
# --------------------------------------------------------------------------

def load_cal() -> dict:
    if not CAL_FILE.exists():
        return {"anchors": []}
    try:
        return json.loads(CAL_FILE.read_text())
    except json.JSONDecodeError as e:
        raise SystemExit(f"{CAL_FILE} is not valid JSON: {e}")


def save_cal(cal: dict) -> None:
    CAL_FILE.write_text(json.dumps(cal, indent=2, sort_keys=True) + "\n")


def anchor_k(a: dict) -> float:
    """TPS per usable TFLOP for one anchor."""
    return a["tps"] / a["usable_tflops"]


def k_for(cal: dict, config: str) -> tuple[float | None, list[dict]]:
    anchors = [a for a in cal.get("anchors", []) if a["config"] == config]
    if not anchors:
        return None, []
    ks = [anchor_k(a) for a in anchors]
    return statistics.median(ks), anchors


def fit_saturation(anchors: list[dict]) -> dict | None:
    """Fit  tps = A x peak_tflops x c/(c + c0)  over the anchors.

    Why this and not min(clients, cores): the first two measured anchors
    disagreed by 46% — 4 clients on 4 cores gave 1159 tps, 8 clients gave 1846.
    Oversubscription buying 59% more throughput is not a CPU running out of
    cores, it is backends blocking on WAL fsync while others compute. The
    hyperbola has the right shape for that (linear when idle, flat when
    saturated) and c0 — the client count at which half the asymptote is
    reached — is the fitted stand-in for that wait.

    Needs at least two distinct client counts, or c0 is unidentifiable.
    c0 by grid search, A in closed form for each c0: no dependencies, and with
    3-4 anchors there is nothing an optimiser would add.
    """
    pts = [(a["clients"], a["peak_tflops"], a["tps"]) for a in anchors
           if a.get("peak_tflops") and a.get("clients")]
    if len({c for c, _, _ in pts}) < 2:
        return None

    best = None
    c0 = 0.05
    while c0 <= 2000:
        xs = [pk * c / (c + c0) for c, pk, _ in pts]
        ys = [t for _, _, t in pts]
        denom = sum(x * x for x in xs)
        if denom > 0:
            A = sum(x * y for x, y in zip(xs, ys)) / denom
            sse = sum((A * x - y) ** 2 for x, y in zip(xs, ys))
            if best is None or sse < best[0]:
                best = (sse, A, c0)
        c0 *= 1.02

    if best is None:
        return None
    sse, A, c0 = best
    ys = [t for _, _, t in pts]
    rms = (sse / len(pts)) ** 0.5
    return {
        "A_tps_per_tflop": A,
        "c0_clients": c0,
        "rms_tps": rms,
        "rms_pct": rms / (sum(ys) / len(ys)) * 100,
        "n": len(pts),
        "clients_seen": sorted({c for c, _, _ in pts}),
    }


def predict_tps(fit: dict, peak_tflops: float, clients: int) -> float:
    return fit["A_tps_per_tflop"] * peak_tflops * clients / (clients + fit["c0_clients"])


# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

def fmt_tps(v: float) -> str:
    return f"{v:,.0f}"


def print_cpu(cpu: dict) -> None:
    print(f"  model            {cpu['model']}")
    if cpu.get("hostname"):
        print(f"  host             {cpu['hostname']}  (kernel {cpu.get('kernel')})")
    smt = " (SMT on; capacity uses physical cores)" if cpu.get("smt") else ""
    print(f"  cores            {cpu['sockets']} x {cpu['cores']} physical{smt}")
    print(f"  clock            {cpu['ghz']} GHz   [{cpu['ghz_source']}]")
    if cpu.get("ghz_max") and cpu.get("ghz_max") != cpu["ghz"]:
        print(f"                   turbo ceiling {cpu['ghz_max']} GHz, not assumed")
    print(f"  ISA              {cpu['isa']}  ->  {cpu['flops_per_cycle']:.0f} DP FLOPs/cycle/core"
          f"  (fma_units={cpu['fma_units']})")
    print(f"  peak capacity    {cpu['peak_tflops']:.3f} TFLOPS DP"
          f"   = {cpu['sockets']}x{cpu['cores']} x {cpu['ghz']}GHz x {cpu['flops_per_cycle']:.0f}")


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_cpu(args) -> int:
    cpu = cpu_from_args(args)
    if args.json:
        print(json.dumps(cpu, indent=2, sort_keys=True))
        return 0
    print("CPU capacity index")
    print_cpu(cpu)
    print()
    print("  Capacity is not a throughput claim: pgbench runs no floating point.")
    print("  Use `predict` for TPS (needs a calibration anchor) or `normalize`")
    print("  to divide a measured TPS by this number.")
    return 0


def cmd_predict(args) -> int:
    cpu = cpu_from_args(args)
    clients = args.clients
    u = usable_tflops(cpu, clients)
    cal = load_cal()

    out = {
        "cpu": cpu, "clients": clients, "usable_tflops": u,
        "config": args.config, "nodes": args.nodes, "workload": args.workload,
        "predictions": [],
    }

    if not args.json:
        print(f"Predicting {args.config}"
              + (f" at N={args.nodes} ({args.workload})" if args.config == "CN" else "")
              + f", {clients} client(s) per node")
        print()
        print_cpu(cpu)
        print()

    rows: list[tuple[str, str, str]] = []
    base_config = "C1" if args.config == "CN" else args.config

    def model_for(cfg: str):
        xs = [a for a in cal.get("anchors", []) if a["config"] == cfg]
        return fit_saturation(xs), xs

    def value(fit, anchors, cfg) -> tuple[float, str]:
        """TPS on this CPU at this client count, and how it was arrived at."""
        if fit:
            seen = ",".join(str(c) for c in fit["clients_seen"])
            # Two points fit two parameters exactly; an rms of 0 there is
            # arithmetic, not agreement, and printing it as a fit quality
            # would be the most flattering lie this tool could tell.
            quality = ("exact — 2 points, 2 parameters, no residual to report"
                       if fit["n"] <= 2 else f"rms {fit['rms_pct']:.1f}%")
            return (predict_tps(fit, cpu["peak_tflops"], clients),
                    f"saturating fit, {fit['n']} anchors at -c {seen}, {quality}")
        k = statistics.median([anchor_k(a) for a in anchors])
        return (k * u, f"1 anchor at -c {anchors[0]['clients']}, linear cap — "
                       f"one client count cannot show saturation")

    # 1. Direct: anchors for this very configuration.
    own_fit, own_anchors = model_for(base_config)
    if own_anchors:
        v, how = value(own_fit, own_anchors, base_config)
        lo = hi = v
        src = f"MEASURED   ({how})"
        n_anchor = len(own_anchors)
        out["fit"] = own_fit
    else:
        base_fit, base_anchors = model_for("S1")
        if not base_anchors:
            msg = ("No calibration anchor. An absolute TPS would be invented, so "
                   "none is printed.\nGet one in about a minute:\n\n"
                   "    python3 " + str(HERE / 'tps_calc.py') +
                   " calibrate --measure --clients 4\n\n"
                   "or record a run you already have:\n\n"
                   "    python3 " + str(HERE / 'tps_calc.py') +
                   " calibrate --tps 3800 --clients 4 --config S1")
            if args.json:
                out["error"] = "no calibration anchor"
                print(json.dumps(out, indent=2, sort_keys=True))
                return 3
            print(msg)
            return 3
        factor = PREDICTED_VS_S1.get(base_config)
        if factor is None:
            if args.json:
                out["error"] = f"no measurement and no prediction for {args.config}"
                print(json.dumps(out, indent=2, sort_keys=True))
                return 3
            print(f"  {args.config}: no anchor, and BENCH.md §7 makes no prediction for it.")
            print(f"  Measure it, or read it as bounded by S1 above and C1 below.")
            return 3
        base, how = value(base_fit, base_anchors, "S1")
        lo, hi = base * factor[0], base * factor[1]
        src = (f"PREDICTED  (S1 {how}; x BENCH.md §7 factor "
               f"{factor[0]}-{factor[1]})")
        n_anchor = len(base_anchors)
        out["fit"] = base_fit

    per_node = (lo, hi)
    rows.append(("per node",
                 (f"{fmt_tps(lo)} tps" if lo == hi
                  else f"{fmt_tps(lo)} – {fmt_tps(hi)} tps"), src))
    out["predictions"].append({"scope": "per_node", "tps_low": lo, "tps_high": hi,
                               "source": src, "anchors": n_anchor})

    if args.config == "CN":
        eff = CN_EFFICIENCY[args.workload]
        n = args.nodes
        agg_lo = per_node[0] * n * eff[0]
        agg_hi = per_node[1] * n * eff[1]
        note = f"PREDICTED  (x N x efficiency {eff[0]}-{eff[1]}, BENCH.md §7)"
        if n > 3 and args.workload == "disjoint":
            note += "; above N=3 the lower bound is not claimed — the bend is the finding"
        rows.append((f"aggregate, N={n}",
                     f"{fmt_tps(agg_lo)} – {fmt_tps(agg_hi)} tps", note))
        out["predictions"].append({"scope": "aggregate", "nodes": n,
                                   "tps_low": agg_lo, "tps_high": agg_hi, "source": note})

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    # Capacity scaling is linear by construction, and nothing here has ever
    # been measured on a second machine. Say so when the target is far from
    # the only box that was: an unlabelled 7x extrapolation reads like a
    # measurement, and this whole file exists to keep those apart.
    peaks = [a["peak_tflops"] for a in cal.get("anchors", []) if a.get("peak_tflops")]
    if peaks:
        ratio = cpu["peak_tflops"] / statistics.median(peaks)
        if ratio > 2 or ratio < 0.5:
            rows.append(("extrapolation",
                         f"{ratio:.1f}x",
                         "CAUTION — no anchor within 2x of this machine; the "
                         "TPS-per-TFLOP slope is assumed, not measured, across hosts"))

    f = out.get("fit")
    if f:
        ceiling = f["A_tps_per_tflop"] * cpu["peak_tflops"]
        print(f"  curve            tps = A x peak x c/(c+c0)")
        print(f"                   A = {f['A_tps_per_tflop']:,.0f} tps/TFLOP, "
              f"c0 = {f['c0_clients']:.1f} clients")
        print(f"                   ceiling on this CPU {fmt_tps(ceiling)} tps, "
              f"half of it at -c {f['c0_clients']:.0f}")
    else:
        print(f"  usable           {u:.3f} TFLOPS at {clients} client(s)  "
              f"= peak x min({clients},{cpu['sockets']*cpu['cores']})"
              f"/{cpu['sockets']*cpu['cores']}")
    print()

    w = max(len(r[0]) for r in rows)
    for scope, val, note in rows:
        print(f"  {scope:<{w}}   {val:>22}   {note}")
    print()
    print("  Every range above is a prediction to be contradicted, not a result.")
    return 0


def cmd_normalize(args) -> int:
    cpu = cpu_from_args(args)
    u = usable_tflops(cpu, args.clients)
    total_cores = cpu["sockets"] * cpu["cores"]
    per_tflop = args.tps / u
    per_core_ghz = args.tps / (min(args.clients, total_cores) * cpu["ghz"])
    if args.json:
        print(json.dumps({"tps": args.tps, "clients": args.clients,
                          "usable_tflops": u, "tps_per_tflop": per_tflop,
                          "tps_per_core_ghz": per_core_ghz, "cpu": cpu},
                         indent=2, sort_keys=True))
        return 0
    print(f"Normalizing {fmt_tps(args.tps)} tps at {args.clients} client(s)")
    print()
    print_cpu(cpu)
    print(f"  usable           {u:.3f} TFLOPS")
    print()
    print(f"  tps per TFLOP    {per_tflop:,.0f}      <- compare this across nodes, not raw tps")
    print(f"  tps per core-GHz {per_core_ghz:,.1f}      <- same thing, ISA-independent")
    print()
    print("  Two nodes with the same tps/TFLOP are the same machine as far as this")
    print("  benchmark is concerned; a node that is low is the one bounding the run.")
    return 0


def cmd_required(args) -> int:
    """The inverse question: how much machine does a target TPS need?"""
    cal = load_cal()
    base_config = "C1" if args.config in ("C1", "CN") else args.config

    def tps_per_peak_tflop(cfg: str) -> tuple[float, str] | None:
        """TPS one whole TFLOP of peak capacity yields at args.clients."""
        xs = [a for a in cal.get("anchors", []) if a["config"] == cfg]
        if not xs:
            return None
        fit = fit_saturation(xs)
        if fit:
            c = args.clients
            return (fit["A_tps_per_tflop"] * c / (c + fit["c0_clients"]),
                    f"saturating fit over {fit['n']} anchors at -c {args.clients}")
        # One anchor: k is already per *usable* TFLOP, and this assumes the
        # target machine is run with at least as many clients as cores.
        return (statistics.median([anchor_k(a) for a in xs]),
                f"1 anchor, linear cap (assumes clients >= cores)")

    got = tps_per_peak_tflop(base_config)
    if got:
        rate_lo = rate_hi = got[0]
        src = f"MEASURED ({got[1]})"
    else:
        base = tps_per_peak_tflop("S1")
        if not base:
            print("No calibration anchor — see `calibrate`. Nothing to invert.")
            return 3
        factor = PREDICTED_VS_S1.get(base_config)
        if factor is None:
            print(f"No anchor and no §7 prediction for {args.config}.")
            return 3
        rate_lo, rate_hi = base[0] * factor[0], base[0] * factor[1]
        src = f"PREDICTED (S1 {base[1]} x §7 factor {factor[0]}-{factor[1]})"
    ks = (rate_lo, rate_hi)

    target = args.tps
    if args.config == "CN":
        eff = CN_EFFICIENCY[args.workload]
        # aggregate target -> per-node target
        per_node = (target / (args.nodes * eff[1]) if eff[1] else float("inf"),
                    target / (args.nodes * eff[0]) if eff[0] else float("inf"))
    else:
        per_node = (target, target)

    print(f"To reach {fmt_tps(target)} tps"
          + (f" aggregate over N={args.nodes} ({args.workload})" if args.config == "CN" else "")
          + f" on {args.config}:")
    print()
    print(f"  per node          {fmt_tps(per_node[0])} – {fmt_tps(per_node[1])} tps"
          f"   at -c {args.clients}")
    # peak TFLOPS needed = tps / rate; the worst case uses the pessimistic rate
    need_lo = per_node[0] / ks[1]
    need_hi = per_node[1] / ks[0] if ks[0] else float("inf")
    print(f"  peak capacity     {need_lo:.3f} – {need_hi:.3f} TFLOPS   [{src}]")
    for isa, ghz in (("avx2", 3.0), ("avx512", 3.0)):
        fpc = flops_per_cycle(isa, args.fma_units)
        c_lo = need_lo * 1000 / (ghz * fpc)
        c_hi = need_hi * 1000 / (ghz * fpc)
        print(f"    as {isa:<6} @{ghz}GHz   {c_lo:.1f} – {c_hi:.1f} physical cores")
    print()
    print("  Capacity is necessary, not sufficient: this ignores WAL fsync, the")
    print("  network RTT floor under a synchronous commit, and disk entirely.")
    return 0


# --------------------------------------------------------------------------
# calibrate
# --------------------------------------------------------------------------

TPS_RE = re.compile(r"^tps = ([\d.]+)", re.M)
LAT_RE = re.compile(r"^latency average = ([\d.]+) ms", re.M)
XACT_RE = re.compile(r"^number of transactions actually processed: (\d+)", re.M)
FAIL_RE = re.compile(r"^number of failed transactions: (\d+)", re.M)


def psql_settings(conn: list[str]) -> dict:
    """The settings that decide whether a TPS number is comparable at all."""
    names = ("shared_buffers", "max_connections", "wal_level", "synchronous_commit",
             "fsync", "max_wal_size", "server_version")
    sql = ("select name || '=' || setting || coalesce(' ' || unit, '') "
           "from pg_settings where name in (" + ",".join(f"'{n}'" for n in names) + ")")
    try:
        out = subprocess.run(["psql", *conn, "-tAc", sql],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"error": str(e)}
    if out.returncode != 0:
        return {"error": out.stderr.strip()}
    d = {}
    for line in out.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def run_measurement(args, cpu: dict) -> dict:
    """Run pgbench against a scratch database and return one anchor.

    Scratch, always: the database must not already exist, so this can never
    initialise pgbench tables over somebody's data. It is dropped afterwards
    unless --keep.
    """
    for tool in ("pgbench", "psql", "createdb", "dropdb"):
        if not shutil.which(tool):
            raise SystemExit(f"{tool} not found in PATH")
    if not STREAM_SQL.exists():
        raise SystemExit(f"missing {STREAM_SQL}")

    conn = []
    if args.pghost:
        conn += ["-h", args.pghost]
    if args.pgport:
        conn += ["-p", str(args.pgport)]
    if args.pguser:
        conn += ["-U", args.pguser]

    db = args.dbname
    exists = subprocess.run(
        ["psql", *conn, "-d", "postgres", "-tAc",
         f"select 1 from pg_database where datname = '{db}'"],
        capture_output=True, text=True)
    if exists.returncode != 0:
        raise SystemExit(f"cannot reach PostgreSQL: {exists.stderr.strip()}")
    if exists.stdout.strip() == "1":
        raise SystemExit(
            f"database {db!r} already exists — refusing to initialise pgbench "
            f"tables into it. Drop it yourself or pass --dbname <other>.")

    threads = min(args.clients, cpu["sockets"] * cpu["cores"])
    created = False
    try:
        print(f"  createdb {db}")
        subprocess.run(["createdb", *conn, db], check=True)
        created = True

        print(f"  pgbench -i -s {args.scale}   (~{args.scale * 16} MB)")
        subprocess.run(["pgbench", *conn, "-i", "-q", "-s", str(args.scale), db],
                       check=True)

        common = ["pgbench", *conn, "-n", "-f", str(STREAM_SQL),
                  "-D", "node=1", "-D", "nodes=1", "-D", f"scale={args.scale}",
                  "-c", str(args.clients), "-j", str(threads), "-M", "prepared"]

        if args.ramp > 0:
            print(f"  warmup {args.ramp}s (discarded — BENCH.md §3 ramp rule)")
            subprocess.run(common + ["-T", str(args.ramp), db],
                           check=True, capture_output=True, text=True)

        print(f"  measuring {args.duration}s at -c {args.clients} -j {threads}")
        r = subprocess.run(common + ["-T", str(args.duration), "-P", "5", db],
                           check=True, capture_output=True, text=True)
        text = r.stdout
    finally:
        if created and not args.keep:
            print(f"  dropdb {db}")
            # pgbench's backends can outlive its exit by a moment, and a plain
            # dropdb then fails with "is being accessed by other users" and
            # leaves the scratch database behind. --force is PG13+; the
            # terminate-and-retry below covers anything older.
            drop = subprocess.run(["dropdb", *conn, "--force", db],
                                  capture_output=True, text=True)
            if drop.returncode != 0:
                subprocess.run(
                    ["psql", *conn, "-d", "postgres", "-tAc",
                     "select pg_terminate_backend(pid) from pg_stat_activity "
                     f"where datname = '{db}'"],
                    capture_output=True, text=True)
                time.sleep(1)
                drop = subprocess.run(["dropdb", *conn, db],
                                      capture_output=True, text=True)
            if drop.returncode != 0:
                print(f"  ! scratch database {db} left behind: {drop.stderr.strip()}")
                print(f"    drop it with:  dropdb --force {db}")

    m = TPS_RE.search(text)
    if not m:
        sys.stderr.write(text)
        raise SystemExit("could not parse a tps line out of pgbench's output")
    tps = float(m.group(1))
    lat = LAT_RE.search(text)
    xact = XACT_RE.search(text)
    fail = FAIL_RE.search(text)

    return {
        "tps": tps,
        "lat_avg_ms": float(lat.group(1)) if lat else None,
        "transactions": int(xact.group(1)) if xact else None,
        "failed": int(fail.group(1)) if fail else None,
        "duration_s": args.duration,
        "ramp_s": args.ramp,
        "scale": args.scale,
        "threads": threads,
        "workload": "stream.sql (disjoint, node=1/1)",
        "pg": psql_settings(conn + ["-d", "postgres"]),
        "measured": True,
    }


def cmd_calibrate(args) -> int:
    cpu = cpu_from_args(args)
    if args.measure:
        if args.tps:
            raise SystemExit("--measure and --tps are alternatives, not both")
        print(f"Calibrating {args.config} on {cpu['hostname'] or 'this host'} by measurement")
        result = run_measurement(args, cpu)
    else:
        if not args.tps:
            raise SystemExit("give --tps <measured> or --measure")
        result = {"tps": args.tps, "duration_s": args.duration, "scale": args.scale,
                  "workload": args.workload_label, "measured": True}

    u = usable_tflops(cpu, args.clients)
    anchor = {
        "at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "config": args.config,
        "clients": args.clients,
        "usable_tflops": round(u, 6),
        "peak_tflops": round(cpu["peak_tflops"], 6),
        "cpu": {k: cpu[k] for k in ("model", "sockets", "cores", "threads", "isa",
                                    "ghz", "ghz_source", "fma_units", "hostname")},
        "note": args.note or "",
        **result,
    }
    anchor["tps_per_tflop"] = round(anchor["tps"] / u, 2)

    cal = load_cal()
    cal.setdefault("anchors", []).append(anchor)
    cal["model"] = ("tps = k * peak_tflops * min(clients,cores)/cores ; "
                    "k = tps/usable_tflops per anchor, median over anchors of a config")
    save_cal(cal)

    print()
    print(f"  tps              {fmt_tps(anchor['tps'])}"
          + (f"   (latency avg {anchor['lat_avg_ms']} ms)" if anchor.get("lat_avg_ms") else ""))
    print(f"  usable capacity  {u:.3f} TFLOPS at {args.clients} client(s)")
    print(f"  k                {anchor['tps_per_tflop']:,.0f} tps per usable TFLOP")
    print(f"  written to       {CAL_FILE}")

    same = [a for a in cal["anchors"] if a["config"] == args.config]
    if len(same) > 1:
        ks = [anchor_k(a) for a in same]
        spread = (max(ks) - min(ks)) / statistics.median(ks) * 100
        print()
        print(f"  {len(same)} anchors for {args.config}: k spread {spread:.0f}% "
              f"({min(ks):,.0f} … {max(ks):,.0f})")
        print("  That spread is the model's error bar. A large one at differing")
        print("  client counts means min(clients,cores) is the wrong saturation")
        print("  rule for this host — likely fsync wait, not CPU.")
    else:
        print()
        print("  One anchor is a point, not a curve. Calibrate again at a different")
        print(f"  --clients (try {args.clients * 2}) before trusting a prediction.")
    return 0


def cmd_list(args) -> int:
    cal = load_cal()
    anchors = cal.get("anchors", [])
    if not anchors:
        print("No anchors yet. `calibrate --measure` writes the first one.")
        return 0
    print(f"{len(anchors)} anchor(s) in {CAL_FILE}\n")
    hdr = f"{'config':<6} {'clients':>7} {'tps':>10} {'TFLOPS':>8} {'k':>10}  host / when"
    print(hdr)
    print("-" * len(hdr))
    for a in anchors:
        print(f"{a['config']:<6} {a['clients']:>7} {a['tps']:>10,.0f} "
              f"{a['usable_tflops']:>8.3f} {anchor_k(a):>10,.0f}  "
              f"{a['cpu'].get('hostname','?')} / {a['at']}")
    print()
    for cfg in CONFIGS:
        k, xs = k_for(cal, cfg)
        if not k:
            continue
        fit = fit_saturation(xs)
        if fit:
            quality = ("exact (2 points, 2 parameters)" if fit["n"] <= 2
                       else f"rms {fit['rms_pct']:.1f}%")
            print(f"  {cfg}: tps = {fit['A_tps_per_tflop']:,.0f} x peak_tflops x "
                  f"c/(c+{fit['c0_clients']:.1f})   [{fit['n']} anchors, {quality}]")
        else:
            print(f"  {cfg}: k = {k:,.0f} tps/TFLOP  (median of {len(xs)}; "
                  f"one client count only, no saturation curve)")
    return 0


def cmd_selftest(args) -> int:
    """Arithmetic only — it checks the model is computed as documented, which
    is the only thing a test can check here. It cannot validate the model."""
    fails = []

    def check(name, got, want, tol=1e-9):
        if abs(got - want) > tol:
            fails.append(f"{name}: got {got}, want {want}")

    check("avx2 fma=2 flops/cycle", flops_per_cycle("avx2", 2), 16)
    check("avx512 fma=2", flops_per_cycle("avx512", 2), 32)
    check("avx512 fma=1", flops_per_cycle("avx512", 1), 16)
    check("avx (no fma)", flops_per_cycle("avx", 2), 8)
    check("sse2", flops_per_cycle("sse2", 2), 4)

    # i5-4670: 4 cores, 3.4 GHz, AVX2+FMA -> 4*3.4*16 = 217.6 GFLOPS
    cpu = {"sockets": 1, "cores": 4, "ghz": 3.4, "flops_per_cycle": 16.0}
    cpu["peak_tflops"] = 1 * 4 * 3.4 * 16 / 1000.0
    check("i5-4670 peak", cpu["peak_tflops"], 0.2176)
    check("usable at 2 clients", usable_tflops(cpu, 2), 0.1088)
    check("usable at 4 clients", usable_tflops(cpu, 4), 0.2176)
    check("usable capped at 8 clients", usable_tflops(cpu, 8), 0.2176)

    # k round-trip: an anchor predicts its own measurement back.
    a = {"tps": 3000.0, "usable_tflops": 0.2176}
    check("k round trip", anchor_k(a) * 0.2176, 3000.0, tol=1e-6)

    # The saturating fit must recover parameters it generated. A=10000,
    # c0=6 on a 0.2 TFLOP machine: tps(c) = 2000 * c/(c+6).
    synth = [{"clients": c, "peak_tflops": 0.2, "tps": 10000 * 0.2 * c / (c + 6)}
             for c in (4, 8, 16, 32)]
    fit = fit_saturation(synth)
    if fit is None:
        fails.append("fit_saturation returned None on 4 synthetic points")
    else:
        check("fit recovers c0", fit["c0_clients"], 6.0, tol=0.15)
        check("fit recovers A", fit["A_tps_per_tflop"], 10000.0, tol=120.0)
        check("fit residual ~0", fit["rms_pct"], 0.0, tol=0.5)
        check("fit predicts a held-out point",
              predict_tps(fit, 0.2, 64), 10000 * 0.2 * 64 / 70, tol=25.0)

    # One client count cannot identify c0 — the tool must decline, not guess.
    if fit_saturation([{"clients": 8, "peak_tflops": 0.2, "tps": 1000.0},
                       {"clients": 8, "peak_tflops": 0.4, "tps": 2000.0}]) is not None:
        fails.append("fit_saturation accepted a single client count")

    if fails:
        for f in fails:
            print("FAIL", f)
        return 1
    print("selftest: all checks pass")
    return 0


# --------------------------------------------------------------------------

def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="pgbench TPS from estimated CPU TFLOPS (BENCH.md §0, §7)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("WHAT THIS IS")[1].strip())
    sub = p.add_subparsers(dest="cmd", required=True)

    def cpu_opts(sp):
        sp.add_argument("--cores", type=int, help="physical cores per socket")
        sp.add_argument("--sockets", type=int)
        sp.add_argument("--ghz", type=float, help="sustained all-core clock")
        sp.add_argument("--isa", choices=sorted(ISA_LANES_DP))
        sp.add_argument("--fma-units", type=int, default=2,
                        help="FMA units per core (default 2; 1 on some Skylake-SP/Zen1)")
        sp.add_argument("--model", help="label for a machine you are describing")
        sp.add_argument("--no-detect", action="store_true",
                        help="do not read this host's CPU at all")
        sp.add_argument("--json", action="store_true")

    sp = sub.add_parser("cpu", help="capacity of this (or a described) machine")
    cpu_opts(sp)
    sp.set_defaults(func=cmd_cpu)

    sp = sub.add_parser("predict", help="TPS from capacity (needs an anchor)")
    cpu_opts(sp)
    sp.add_argument("--config", choices=CONFIGS, default="S1")
    sp.add_argument("--nodes", type=int, default=3, help="N, for --config CN")
    sp.add_argument("--clients", type=int, default=8, help="pgbench -c, per node")
    sp.add_argument("--workload", choices=sorted(CN_EFFICIENCY), default="disjoint")
    sp.set_defaults(func=cmd_predict)

    sp = sub.add_parser("normalize", help="measured TPS -> TPS per TFLOP")
    cpu_opts(sp)
    sp.add_argument("--tps", type=float, required=True)
    sp.add_argument("--clients", type=int, required=True)
    sp.set_defaults(func=cmd_normalize)

    sp = sub.add_parser("required", help="target TPS -> capacity needed")
    sp.add_argument("--tps", type=float, required=True)
    sp.add_argument("--config", choices=CONFIGS, default="S1")
    sp.add_argument("--nodes", type=int, default=3)
    sp.add_argument("--clients", type=int, default=8,
                    help="pgbench -c the target would run with (per node)")
    sp.add_argument("--workload", choices=sorted(CN_EFFICIENCY), default="disjoint")
    sp.add_argument("--fma-units", type=int, default=2)
    sp.set_defaults(func=cmd_required)

    sp = sub.add_parser("calibrate", help="record or measure an anchor")
    cpu_opts(sp)
    sp.add_argument("--measure", action="store_true",
                    help="run pgbench here, in a scratch database, and use its tps")
    sp.add_argument("--tps", type=float, help="a tps you already measured")
    sp.add_argument("--config", choices=CONFIGS, default="S1")
    sp.add_argument("--clients", type=int, default=4)
    sp.add_argument("--scale", type=int, default=5,
                    help="pgbench -s; keep the dataset under shared_buffers (§3)")
    sp.add_argument("--duration", type=int, default=30, help="pgbench -T")
    sp.add_argument("--ramp", type=int, default=10, help="discarded warmup seconds")
    sp.add_argument("--dbname", default="bench_calib", help="scratch db; must not exist")
    sp.add_argument("--keep", action="store_true", help="do not drop the scratch db")
    sp.add_argument("--pghost", default="/var/run/postgresql")
    sp.add_argument("--pgport", type=int)
    sp.add_argument("--pguser")
    sp.add_argument("--note", help="anything the numbers do not say")
    sp.add_argument("--workload-label", default="(recorded, not run here)")
    sp.set_defaults(func=cmd_calibrate)

    sp = sub.add_parser("list", help="show anchors and the k they imply")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("selftest", help="check the arithmetic")
    sp.set_defaults(func=cmd_selftest)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

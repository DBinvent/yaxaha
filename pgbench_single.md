# Single-node pgbench — TPS per CPU TFLOPS

One plain PostgreSQL per host, no cluster, no `yaxaha` extension. The question:
**how much throughput does each machine's CPU capacity buy, and how much of
that is the per-commit fsync?** The table reports pgbench TPS twice per node —
`synchronous_commit=on` (the default) and `=off` (bench session only) — beside
GFLOPS, the CPU capacity index from `bench/tps_calc.py`
(`sockets × cores × GHz × FLOPs-per-cycle(ISA) / 1000`). TPS ÷ (GFLOPS / 1000)
normalises throughput by hardware, so machines compare on something other than
raw TPS — the same reason BENCH.md §0a exists; the "Reading it" notes use that
ratio throughout.

Nodes are labelled by CPU model on purpose (this file is public; no host names
or addresses).

## Method

- **Run twice, keep the second.** The first run warms the OS/PG cache; only the
  second is recorded. sync=on via `raw/scripts/pgbench-single-cluster.sh`,
  sync=off via `pgbench-nosync-cluster.sh` (both private).
- pgbench built-in `tpcb-like`, **scale 5** (~80 MB, under the default 128 MB
  `shared_buffers` so it measures CPU/RAM, not disk), **8 clients**,
  jobs = min(nproc, 8), `-M prepared`, **20 s** per run.
- **sync=off** = `synchronous_commit=off` for the pgbench session only (via
  `PGOPTIONS`), never a server-wide or persistent change.
- Scratch DB via the `postgres` role over sudo; dropped afterwards.
- Distro-default PostgreSQL per node — the version is a column, not forced
  uniform.

## Results

Re-run 2026-09-05. Since the previous pass: the Phenom II X6 was moved off a
failing HDD onto a healthy SSD (was excluded, now a real row), the i7-4790
upgraded to PostgreSQL 18.6 / Ubuntu 26.04, and every node was re-measured.

| CPU | Storage | RAM | Ubuntu | glibc | PG | cores | GHz | ISA | GFLOPS | TPS sync=on | TPS sync=off |
|---|---|---:|---|---|---:|---:|---:|---|---:|---:|---:|
| Intel i7-4790K         | NVMe SSD | 14.8G | 26.04 | 2.43 | 18.6 | 4 | 4.00 | avx2 | 256.0 | **1355** | **24,370** |
| Intel i7-4790          | SSD | 11.1G | 26.04 | 2.43 | 18.6 | 4 | 3.60 | avx2 | 230.4 | **1675** | **20,658** |
| AMD Phenom II X6 1055T | SSD | 31.3G | 24.04 | 2.39 | 16 | 6 | 2.80 | sse2 |  67.2 | **1819** | **11,379** |
| Intel i5-9400F (1 vCPU)| SSD | 7.6G | 22.04 | 2.35 | 14.24 | 1 | 2.90 | avx2 |  46.4 | **1569** | **4,852** |
| Intel Pentium G3258    | SSD | 7.6G | 24.04 | 2.39 | 16 | 2 | 3.20 | sse2 |  25.6 | **3394** | **6,733** |
| AMD Athlon64 X2 5000+  | HDD | 2.8G | 20.04 | 2.31 | 12 | 2 | 2.60 | sse2 |  20.8 | **206** | **2,071** |
| Intel Core2 6600       | HDD | 3.8G | 20.04 | 2.31 | 12 | 2 | 2.40 | sse2 |  19.2 | **170** | **3,336** |
| Intel Celeron E1200    | HDD | 1.9G | 20.04 | 2.31 | 12 | 2 | 1.60 | sse2 |  12.8 | **195** | **894** |
| Intel Pentium E5500    | HDD | 2.9G | 20.04 | 2.31 | 12 | 1 | 2.80 | sse2 |  11.2 | **235** | **2,022** |
| _Intel i5-4670 (ref, bench host)_ | SSD | 23G | 24.04 | 2.39 | 16.15 | 4 | 3.40 | avx2 | 217.6 | **1828** | **12,818** |

All ten rows measured. The Phenom II X6, whose disk was failing on the
previous pass (~0.7 TPS, then excluded), has since been moved to a healthy
SSD with nothing else changed and now posts a real number — see the Phenom
point under "Reading it". Storage medium (`lsblk ROTA`) still splits the
table cleanly — see the first "Reading it" point. RAM is listed for
completeness but is not a factor at this scale: the smallest node (1.9G,
Celeron E1200) is still ~24× the ~80MB dataset, so nothing here is paging or
shared_buffers-starved. PG major version spans four (12 / 14 / 16 / 18), and
two nodes now run 18.6 (both Devil's Canyon i7s) — see the last "Reading it"
point for why those rows don't fit the usual storage story.

The reference row runs the identical method as the other nine (it's the same
host this repo's benchmarking work runs from, not reached over SSH). Its TPS
is noisy: 2026-09-05 gave 1,747 / 1,783 / 1,873 / 1,878 over four runs (1,828
median, the value tabled), against 1,607 on the previous pass and the 1,846
in `BENCH.md` §0a from a different tool (`tps_calc.py calibrate`, longer
duration, one combined warmup+measure run). All are real; they differ
because that host runs live services whose background load varies run to run
— not because the CPU changed.

## Reading it

- **Storage medium dominates TPS, not CPU capacity.** At sync=on every
  SSD/NVMe node scored 1,355–3,394 TPS; every spinning-disk node 170–235 TPS —
  roughly an order of magnitude apart, and the SSD/HDD split is clean with
  zero overlap. The Pentium G3258 (weakest CPU among the SSD nodes, 25.6
  GFLOPS) still beat the i7-4790 (230.4 GFLOPS, also SSD) at 3,394 vs 1,675
  TPS, and comfortably beat every HDD node regardless of their CPU. The
  sharpest cut of all: the Phenom II X6, moved from a failing HDD to a
  healthy SSD with nothing else changed, went from ~0.7 TPS to 1,819 — the
  same six cores, ~2,600× the throughput. The sync=off column makes the same
  point from the other side: with the per-commit fsync gone the HDD nodes jump
  to 894–3,336 TPS (5–20×) and the order-of-magnitude SSD/HDD gap collapses —
  the slowest SSD nodes (i5-9400F 4,852, G3258 6,733) are then within ~2× of
  the fastest HDD, where at sync=on that gap was 6–20×. At scale 5 with an
  8-client `tpcb-like` load, sync=on here is a storage-latency test wearing a
  CPU-capacity label. TPS/TFLOPS should be read as "throughput per unit
  compute *given this storage*", not a CPU efficiency ranking across the
  whole table — only compare it within a storage class.
- **TPS/TFLOPS favours a small capacity denominator, within a storage class.**
  Among the SSD/NVMe nodes the 2-core G3258 (0.026 TFLOPS) posts the highest
  ratio of all (≈133k), the 1-core i5-9400F VM (0.046 TFLOPS) ≈34k, and the
  6-core Phenom II X6 — sse2, slow clock, only 0.067 TFLOPS — ≈27k, while the
  three high-capacity 4-core boxes, i7-4790K (≈5.3k), i7-4790 (≈7.3k) and the
  bench host (≈8.4k), form the bottom band. It tracks the denominator, not
  core count as such: a machine that "wastes" most of its FLOPs still moves a
  respectable number of rows off one fast disk queue, so single-node pgbench
  is not FP-bound. The same pattern holds loosely among the HDD nodes: 1-core
  E5500 (≈21k) is highest, but the 2-core Celeron E1200 (≈15k, weakest clock
  of the group) beats the 2-core Athlon64 (≈9.9k) and Core2 (≈8.9k) — clock
  speed and queue depth interact too.
- **The rig is heterogeneous — ~23× on raw CPU capacity, four PG major
  versions, four Ubuntu releases, two ISA classes, and two storage classes.**
  That is the point of recording it: a synchronous cluster later runs at the
  speed of its slowest node, on whichever axis that turns out to be.
- **The `sse2` FLOPs figure is optimistic for pre-Nehalem cores.** The index
  credits 4 DP FLOPs/cycle; Core2, K8 (Athlon64) and K10 (Phenom) realistically
  do ~2, so those TFLOPS are ~2× high and their TPS/TFLOPS correspondingly ~2×
  low. Ranking holds; absolute ratios for the old chips are floors.
- **The Phenom II X6 confirms the storage story from inside one CPU.** On the
  previous pass it managed 0.65–0.72 TPS (reproducible, 11–12 s latency), with
  a SMART check showing thousands of pending sectors and an exhausted
  load-cycle count — a failing drive stalling every WAL fsync, so it was left
  out of the ranking. It has since been moved to a healthy SSD, nothing else
  changed, and now posts 1,819 TPS: squarely in the SSD band, with a ≈27k
  TPS/TFLOPS that sits where a small-denominator sse2 chip should. The earlier
  number was the drive, not the six K10 cores.
- **Both PostgreSQL 18 nodes post the lowest TPS/TFLOPS of the SSD band.** The
  i7-4790K (5,291) and the i7-4790 (7,272) — the two nodes now on PG 18.6 —
  sit below the PG 16 bench host (8,401), and the i7-4790's ratio *fell* from
  ≈9,000 on the previous pass, when it still ran PG 16, to 7,272 after the
  upgrade, while its sync=off number barely moved (20,748 → 20,658; see the
  follow-up). Durability settings (`fsync`, `synchronous_commit`,
  `wal_sync_method`, `full_page_writes`) match every other node; the standing
  difference is PG 18's new `io_method=worker` asynchronous-I/O subsystem,
  which every PG ≤16 node lacks. Two PG18 nodes agreeing, and one of them
  changing when only its PG major changed, make this the leading explanation —
  still not isolated to component level (that needs the same hardware on two
  PG majors), and a reminder that PG version is a variable this benchmark
  hasn't controlled for.

## Follow-up: does removing fsync make TPS/TFLOPS converge on CPU capacity?

sync=off is now a column of the Results table for every node. Reading it
against sync=on on the three fastest same-generation SSD/NVMe CPUs — the two
closest in raw clock, plus the i7-4790K NVMe outlier above — tests whether the
scattered TPS/TFLOPS in the first table is a storage artefact rather than a
CPU one:

| CPU | TFLOPS | TPS sync=on | TPS sync=off |
|---|---:|---:|---:|
| i5-4670 (ref, bench host) | 0.2176 | 1,828 |  12,818 |
| i7-4790 (now also PG18)   | 0.2304 | 1,675 |  20,658 |
| i7-4790K (NVMe/PG18)      | 0.2560 | 1,355 |  24,370 |

The i7-4790K still flips from *worst* of the three sync=on to *best* sync=off
(≈95k TPS/TFLOPS) — its NVMe/PG18 combination was never a CPU weakness,
sync=on was burying its CPU lead under fsync latency. Absolute TPS jumped 7×
(ref host) to 18× (the node with the most fsync latency to remove), so
sync=off is a different regime from sync=on, not a corrected version of it.

The 2026-08 pass found the three *converging* once fsync was removed (sync=on
1.9× apart, sync=off 1.35×); the 2026-09-05 re-run does not reproduce that —
sync=on TPS/TFLOPS is 5.3k–8.4k (1.6×) and sync=off 59k–95k (1.6×), the same
spread. Two things moved in between, both narrowing sync=on rather than
sync=off: the i7-4790 went to PG 18 (its sync=on ratio ≈9.0k → 7.3k, sync=off
flat, 20,748 → 20,658), and the ref host's sync=off fell (14.7k → 12.8k) under
heavier background load during this run. The convergence result needs a
lighter-loaded ref host and a matched PG version to re-test; the i7-4790K
flip does not depend on either.

**Why the bench host trails — 59k this pass, 67k in 2026-08, vs ~90–95k for
the other two.** The 2026-08 investigation still stands: re-ran it three
times (14,656.75 / 14,658.76 / … reproducible) with `mpstat` sampling — all
cores 96.9% busy, 0.06% iowait, a genuine CPU ceiling, not background noise
or leftover fsync/iowait. Matching client count to physical cores (4 instead
of 8) to rule out 8-clients-on-4-cores oversubscription made it *slower*
(13,161 TPS), so the extra concurrency is helping — a signature of a
lock/branch-stall-heavy workload, exactly what SMT absorbs. The bench host is
the only one of the three without hyperthreading (4 cores / 4 threads); the
other two are 4 cores / 8 threads. The TFLOPS index counts physical cores for
all three, so it doesn't credit HT's concurrency benefit on this workload —
the leading explanation for the gap, not proven to component level (would
need SMT toggled off on the other two). The gap is *wider* this pass (≈1.6×)
than in 2026-08 (≈1.34×) because the box was busier during the run —
RustRover's remote-dev-server at ~20% of a core plus the benchmark
orchestration itself — and on a 4-core no-HT box that lands directly on TPS.
The no-HT ceiling is still the main story; background load is a larger
secondary this time.

**Not adding an HT/SMT coefficient to TFLOPS for this.** TFLOPS here is a
pure hardware-capacity index (cores × GHz × FLOPs/cycle) — independent of
OS, PG version, or workload, which is the entire reason it's comparable
across ten dissimilar boxes. HT doesn't add FLOPs/cycle; it lets a core
interleave a second thread's stalls, a property of *this* lock/stall-heavy
workload meeting SMT, not of the CPU's raw arithmetic capacity. Fitting a
"HT credit" into TFLOPS would quietly turn a hardware number into a
workload-tuned one, off a sample of one non-HT node vs. two HT nodes.
Thread topology is read as another axis TPS/TFLOPS should be compared
*within*, the same way storage class already is — not as a correction to
the index.

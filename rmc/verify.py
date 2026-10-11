#!/usr/bin/env python3
"""Judge one cluster's ledger against what its writer was told.

    verify.py <cluster> <id-base> <id-span> <writer-log> [~]<node>=<ids-file> ...

<writer-log> is the writer's log (load/writer.sh); each <ids-file> holds the
rmc_ledger ids one member has, one per line. A node written `~node` is a member
that does not participate (Spare, Paused): it is judged by I3 and I4 only, and
its lag is reported. Prints one line per invariant and exits with the number
that failed:

  I1 lost      an OK id missing on some participating member
  I2 converge  the participating members hold different sets, or one holds nothing
  I3 phantom   an ERR or NOC id present on any member
  I4 foreign   an id outside this cluster's range on any member: a row crossed a boundary
"""
import sys


def main():
    cluster, base, span, log = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    files = dict(a.split("=", 1) for a in sys.argv[5:])

    outcome = {}
    with open(log) as f:
        for line in f:
            p = line.split(" ", 4)
            if len(p) >= 4 and p[1].isdigit():
                outcome[int(p[1])] = p[3]
    acked = {i for i, r in outcome.items() if r == "OK"}
    refused = {i for i, r in outcome.items() if r in ("ERR", "NOC")}
    unknown = {i for i, r in outcome.items() if r == "UNK"}

    every = {}
    for node, path in files.items():
        with open(path) as f:
            every[node] = {int(x) for x in f.read().split() if x.lstrip("-").isdigit()}
    held = {n: s for n, s in every.items() if not n.startswith("~")}
    spare = {n[1:]: s for n, s in every.items() if n.startswith("~")}

    failed = 0

    def report(tag, good, text):
        nonlocal failed
        print(f"  {'OK  ' if good else 'FAIL'}  {cluster} {tag}: {text}")
        failed += 0 if good else 1

    def few(s):
        s = sorted(s)
        return " ".join(str(x) for x in s[:5]) + (" ..." if len(s) > 5 else "")

    print(f"  ....  {cluster}: writer OK={len(acked)} ERR+NOC={len(refused)} UNK={len(unknown)}; "
          + ", ".join(f"{n}={len(s)}" for n, s in sorted(held.items())) + " rows"
          + "".join(f"; {n} (not participating)={len(s)}, lacks {len(acked - s)} OK" for n, s in sorted(spare.items())))

    lost = {n: acked - s for n, s in held.items() if acked - s}
    report("I1 no acknowledged row lost", not lost,
           "every OK id on every member" if not lost else
           "; ".join(f"{n} lacks {len(v)} ({few(v)})" for n, v in sorted(lost.items())))

    sets = list(held.values())
    empty = [n for n, s in held.items() if not s]
    same = all(s == sets[0] for s in sets) if sets else False
    if empty or not same:
        ref = max(sets, key=len) if sets else set()
        diff = "; ".join(f"{n} differs by {len(ref ^ s)}" for n, s in sorted(held.items()) if s != ref)
        report("I2 members converge", False, (f"empty on {' '.join(empty)}; " if empty else "") + diff)
    else:
        report("I2 members converge", True, f"{len(sets)} members hold the same {len(sets[0])} ids")

    phantom = {n: s & refused for n, s in list(held.items()) + list(spare.items()) if s & refused}
    report("I3 no phantom commit", not phantom,
           "no ERR/NOC id present" if not phantom else
           "; ".join(f"{n} holds {len(v)} refused ({few(v)})" for n, v in sorted(phantom.items())))
    if unknown:
        present = set.intersection(*sets) & unknown if sets else set()
        print(f"  ....  {cluster}: of {len(unknown)} UNK, {len(present)} committed, "
              f"{len(unknown) - len(present)} not")

    foreign = {n: {x for x in s if not base <= x < base + span} for n, s in list(held.items()) + list(spare.items())}
    foreign = {n: v for n, v in foreign.items() if v}
    report("I4 nothing crossed in", not foreign,
           "only this cluster's range" if not foreign else
           "; ".join(f"{n} holds {len(v)} foreign ({few(v)})" for n, v in sorted(foreign.items())))
    sys.exit(failed)


if __name__ == "__main__":
    main()

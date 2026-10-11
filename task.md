
## Result — BENCH.md: settle before the dump (Claude Opus 5)

§5's one-line "quiesce" is now three steps, because the order is what makes
the comparison mean anything:

1. **Stop the load on every node and wait for the last one.** One generator
   still writing means the others can never match it.
2. **Settle — `BENCH_SETTLE_S`, default 5s.** The last commits are in flight
   when pgbench prints its summary, and they are precisely the ones an
   immediate dump would miss.
3. **Then poll until the nodes agree**, once a second, bounded by
   `BENCH_CONVERGE_TIMEOUT_S` (120) through `wait_common.sh`'s `it_wait_for`.

The fixed delay is a floor rather than the whole wait, and that matters: a
bare sleep is a guess dressed as a method — too short and every run fails as
"divergence", too long and every run pays for the worst case. Floor plus poll
costs the floor when things are fast and still answers when they are not.

**The poll duration is now a recorded result, not bookkeeping.**
`converged_after_s` in `bench.convergence` (with `settle_s` beside it) is the
end-of-load replication lag, measured instead of assumed, and it gets its own
Grafana panel against N. A cluster that agrees in 200ms at N=3 and 9s at N=10
has said something about the protocol the TPS curve did not.

Two more rules that fell out of writing it down:

- **Snapshots in parallel across nodes.** Serially over ten hosts, node 1 is
  read at T+5 and node 10 at T+40, and a difference cannot be told from
  thirty-five seconds of work — in a run that is supposed to be quiesced.
- **Timing out is a failed run, never a retry.** Record the digests as they
  stood and which relations differed. Re-running until it passes turns the
  check that protects every other number into a formality.

Re-indexed: `ccc index` in yaxaha-tests.

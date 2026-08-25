# A three-node YaXAHA cluster starting, electing a leader, replicating a
# transaction, and shutting down — recorded from a real run.
#
#   ../record.sh          builds the image, boots a container, records this
#   vhs tapes/cluster.tape  if you already have a bootstrapped `yaxaha-demo`
#
# It records `docker exec` into an already-bootstrapped container on purpose.
# The container's entrypoint spends a minute on apt, ytsetup and a Postgres
# restart before anything interesting happens, and none of that is what a
# viewer came to see. record.sh does that part off-camera.

Output cluster.gif
Output cluster.mp4

Set Shell bash
Set FontSize 13
# Wide: psql prints the cluster state as a table, and wrapping it makes the
# leader/follower lines unreadable, which is the whole point of the frame.
Set Width 1500
Set Height 1000
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
# The run is minutes of waiting on ping ticks (ping_tick_sleep_ms=5000) and
# leader election. Double speed keeps it watchable; the timings below are
# still wall-clock seconds of the real run.
Set PlaybackSpeed 2.0

Type "# Three PostgreSQL nodes, one YaXAHA cluster, on one machine."
Enter
Sleep 2s

Type "docker exec -it yaxaha-demo bash -lc 'cd /home/rust && cargo make --env PG_VER=14 --env CNT=3'"
Enter

# Guessed, not measured — nobody has recorded this yet. Watch the result and
# trim: too short truncates the shutdown, too long ends on a dead prompt.
# The run is done when close_wait.sh prints "YT cluster closed!".
Sleep 150s

Type "# Every node saw the same transaction. Nothing was left running."
Enter
Sleep 3s

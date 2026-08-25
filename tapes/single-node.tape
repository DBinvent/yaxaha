# One node, a psql prompt, and the cluster answering questions about itself.
#
# The counterpart to cluster.tape: that one shows the suite running, this one
# shows what the suite is running *against*, which is the part someone
# evaluating YaXAHA actually wants to poke at.
#
#   ../record.sh          builds the image, boots a container, records this
#   vhs tapes/single-node.tape   if `yaxaha-demo` is already bootstrapped

Output single-node.gif
Output single-node.mp4

Set Shell bash
Set FontSize 13
Set Width 1500
Set Height 950
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Type "# One node of the cluster, with a psql prompt attached."
Enter
Sleep 2s

Type "docker exec -it yaxaha-demo bash -lc 'cd /home/rust && cargo make --makefile node.toml --env NID=1 --env psql=1 --env CNT=1 --env INIT=it_init_single.sql'"
Enter
# initdb, Postgres start, extension create, ytserv start, then the prompt.
# Guessed — measure it on the first recording and trim.
Sleep 45s

Type "select * from json_to_recordset(yt_info('E')) as x(name text, module text, value text);"
Enter
Sleep 6s

Type "select * from yt_help_with_defaults;"
Enter
Sleep 6s

Type "begin;"
Enter
Sleep 1s
Type "insert into yt_config(name, value) values ('demo', 'recorded');"
Enter
Sleep 1s
Type "select yt_complete(true);"
Enter
Sleep 2s
Type "commit;"
Enter
Sleep 3s

Type "select * from yt_config where value = 'recorded';"
Enter
Sleep 5s

Type "\q"
Enter
Sleep 10s

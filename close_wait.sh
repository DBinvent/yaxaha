#!/bin/bash
#set -Eeu

# Close cluster - Kill all remining nodes processes
# check errors

errormsg="error.msg"
echo "[IT] Closing YT cluster ..."

ps=1
while [[ $ps -gt 0 ]]
do
sleep 1
ps=$(ps ugx | grep -v nodev | grep -v grep | grep -v "externals/node" | grep "node.toml" | wc -l)

for p in $(ps ugx | grep -v nodev | grep -v grep | grep -v "externals/node" | grep "node.toml" | awk '{print $2}')
do
echo "Stopping pid $p ..."
kill $p
done

done

echo "[IT] YT cluster closed!"

exitcode=$(cat $errormsg | grep -v "^[[:space:]]*$" | wc -l)

if [[ $exitcode -ge 1 ]]
then
  echo
  echo "Error(s) detected at $errormsg:"
  echo
  cat $errormsg

  echo
fi

exit $exitcode

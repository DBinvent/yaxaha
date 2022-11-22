#!/bin/bash

errormsg="./error.msg"
exitcode=$(cat $errormsg | grep -v "^[[:space:]]*$" | wc -l)

if [[ $exitcode -gt 1 ]]
then

  echo
  echo Error detected at $errormsg:
  echo

  cat $errormsg

  echo
fi

exit $exitcode

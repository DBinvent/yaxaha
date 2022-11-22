#!/bin/bash

# down YT lead node to get node re-started
kill $(cat $2/.s.YT.$1.pid) || true
sleep 1

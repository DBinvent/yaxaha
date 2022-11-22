#!/bin/bash

# down YT node to re-started
kill $(cat $2/.s.YT.$1.pid) || true

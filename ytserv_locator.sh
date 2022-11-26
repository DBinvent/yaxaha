#!/bin/bash
set -Eeu

ls -l /usr/local/bin/yaxaha/ytserv* | head -n 1 | awk '{print $9}'

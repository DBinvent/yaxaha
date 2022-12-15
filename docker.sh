#!/bin/bash
set -Eeu

docker image build -t yaxaha .
echo
echo "Docker build completed, starting the init.sh..."
echo

docker run -it -v $(pwd):/home/rust yaxaha bash -e init.sh

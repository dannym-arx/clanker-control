#!/bin/sh
# Build clanker-control into ./clanker-control
set -e
cd "$(dirname "$0")"
odin build . -out:clanker-control -o:speed
echo "built ./clanker-control"

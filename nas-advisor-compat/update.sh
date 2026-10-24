#!/bin/sh
# Rebuild only this isolated advisor project in its current directory.
# Deliberately does not discover, stop, replace, or copy into another Guanpan container.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"
[ -f compose.yml ] && [ -f server/app.py ] || { echo "Missing compose.yml or server/app.py"; exit 1; }
grep -Eq '^name:[[:space:]]*guanpan-advisor[[:space:]]*$' compose.yml || { echo "Refusing to run: unexpected compose project name"; exit 1; }
PROJECT=guanpan-advisor
echo "Building isolated project $PROJECT on port 8789 with its own named data volume."
docker compose -p "$PROJECT" up -d --build --force-recreate
echo "Check http://127.0.0.1:8789/health and confirm codeVersion before configuring iOS."

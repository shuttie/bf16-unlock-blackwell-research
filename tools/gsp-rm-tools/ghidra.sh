#!/bin/bash
# Serialized read-only Ghidra headless wrapper.
# usage: ghidra.sh <Script.java> [script args...]
#   e.g. ghidra.sh DisasmRange.java 0x15ffae8,8
#        ghidra.sh DecompileAt.java out.c 0x15ffae8,0x15ff1dc 1 120
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${GH:-${GHIDRA_HOME:+$GHIDRA_HOME/support/analyzeHeadless}}"
if [ -z "$GH" ]; then
  echo "set GHIDRA_HOME to the Ghidra 12.2 install, or GH to analyzeHeadless" >&2
  exit 1
fi
PROJ="${PROJ:-$HERE/project}"
SCRIPTS="${SCRIPTS:-$HERE}"
LOCK="${LOCK:-$HERE/ghidra.lock}"

if [ -n "${JAVA_HOME:-}" ]; then
  export JAVA_HOME
fi

exec flock "$LOCK" timeout 900 env \
  GHIDRA_HEADLESS_MAXMEM="${GHIDRA_HEADLESS_MAXMEM:-8G}" \
  "$GH" "$PROJ" gsp_full -process gsp_fwimage.bin -noanalysis -readOnly \
  -scriptPath "$SCRIPTS" -postScript "$@"

#!/usr/bin/env bash
set -euo pipefail

ROOTSYS_DEFAULT="/home/morenoma/.local/tools/root"
ROOTSYS="${ROOTSYS:-${ROOTSYS_DEFAULT}}"

if [[ ! -x "${ROOTSYS}/bin/root-config" ]]; then
  echo "ROOT not found at ${ROOTSYS}" >&2
  echo "Install a prebuilt ROOT tarball or set ROOTSYS to your ROOT install path." >&2
  exit 2
fi

export ROOTSYS
export PATH="${ROOTSYS}/bin:${PATH}"
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
  export LD_LIBRARY_PATH="${ROOTSYS}/lib:/home/morenoma/.local/lib:${LD_LIBRARY_PATH}"
else
  export LD_LIBRARY_PATH="${ROOTSYS}/lib:/home/morenoma/.local/lib"
fi

echo "ROOTSYS=${ROOTSYS}"
root-config --version

#!/usr/bin/env bash
set -euo pipefail

jobs="${BUILD_JOBS:-$(($(nproc)+1))}"

if make -j"$jobs"; then
  exit 0
else
  fast_rc=$?
fi

echo "::error::Fast parallel make failed in $(pwd)"
for diagnostic_file in config.log objs/autoconf.err; do
  if [[ -f "$diagnostic_file" ]]; then
    echo "::group::$diagnostic_file"
    cat "$diagnostic_file"
    echo "::endgroup::"
  fi
done

echo "::group::Serial diagnostic make"
if make -j1; then
  diagnostic_rc=0
else
  diagnostic_rc=$?
fi
echo "Serial diagnostic exit code: $diagnostic_rc"
echo "::endgroup::"

exit "$fast_rc"

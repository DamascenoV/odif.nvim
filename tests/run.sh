#!/usr/bin/env sh
# Run all odif tests headlessly.
set -e
cd "$(dirname "$0")/.."

run() {
  echo "==> $1"
  nvim --headless --clean -u NONE -l "$1" 2>&1
}

run tests/smoke.lua
run tests/controller_dispatch.lua
run tests/match_async.lua
run tests/spawn.lua
run tests/sources.lua
run tests/ui.lua
echo "--- /tmp/odif-ui-test.log ---"
cat /tmp/odif-ui-test.log
echo "--- /tmp/odif-spawn-test.log ---"
cat /tmp/odif-spawn-test.log
echo
echo "ALL TESTS PASSED"

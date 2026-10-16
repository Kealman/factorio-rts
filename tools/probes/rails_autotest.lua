-- Test-only (tools/autotest-run.sh EXTRA_LUA): switch the rails autotest on (scripts/rails.lua, docs/qa/phase5-rails-notes.md).
local rails = require("scripts.rails")
rails.AUTOTEST_DEFAULT = true

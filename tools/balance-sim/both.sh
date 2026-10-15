#!/usr/bin/env bash
# Run the balance simulator for Space Age and base-only in parallel and print the summary side by side.
# Usage: tools/balance-sim/both.sh   (env: SIM_ONLY, SIM_FROM_HEAD as for run.sh)
cd "$(dirname "$0")/../.."
tools/balance-sim/run.sh p4-balance sa 600 > build/p4-balance-out.txt 2>&1 & P1=$!
tools/balance-sim/run.sh p4-balance-nosa base 600 > build/p4-balance-nosa-out.txt 2>&1 & P2=$!
wait $P1 $P2
grep -hE "failed|exited|rror while" build/p4-balance-out.txt build/p4-balance-nosa-out.txt
paste <(grep -E "summary" build/p4-balance-out.txt | sed 's/bsim summary sa //' | sort \
          | sed -E 's/winners //; s/metric avg/m/; s/time avg/t/') \
      <(grep -E "summary" build/p4-balance-nosa-out.txt | sed 's/bsim summary base //' | sort \
          | sed -E 's/^[^:]*: //; s/winners //; s/metric avg/m/; s/time avg/t/')

#!/bin/sh
# Regression for the RV32I pipeline + coprocessor interface, with negative controls.
#   sh scripts/run_all.sh                  (needs iverilog >= 12, python3)
#   DEFS="-DNC_TRACE" sh scripts/run_all.sh   turns the per-cycle debug prints back on
# The accelerator is replaced by a behavioural model (verification/models/accel_model.sv).
# A negative control recompiles with one fix removed (-DNO_...) and MUST fail.
# Logs: build/<test>/out.log     Summary: build/run_all.txt
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT" || exit 1
RTL=$(ls rtl/*.v rtl/*.sv); MODEL=verification/models/accel_model.sv; TB=verification/tb
mkdir -p build; OUT=build/run_all.txt; : > "$OUT"; ok=0; bad=0; t0=$(date +%s)
python3 scripts/gen_progs.py build/progs >/dev/null || exit 1

sim() {   # sim <name> <tb_module> <program .mem> <extra defines> <plusargs>
  W="build/$1"; rm -rf "$W"; mkdir -p "$W/mem files"
  cp "mem files"/*.mem "$W/mem files"/; cp "mem files"/*.mem "$W"/
  [ -n "$3" ] && { cp "$3" "$W/mem files/instruction_memory.mem" || { echo "missing program $3" > "$W/out.log"; return 1; }; }
  iverilog -g2012 $DEFS $4 -I "$TB" -s "$2" -o "$W/sim.vvp" $RTL "$MODEL" "$TB/$2.sv" > "$W/out.log" 2>&1 &&
  ( cd "$W" && vvp sim.vvp $5 >> out.log 2>&1 )
}
check() {  # check <label> <expected PASS|FAIL> <got>
  if [ "$2" = "$3" ]; then ok=$((ok+1)); r="ok ($3)"; else bad=$((bad+1)); r="MISMATCH: expected $2, got $3"; fi
  printf '%-52s %s\n' "$1" "$r" | tee -a "$OUT"
}
res() { grep -qE "$2" "build/$1/out.log" && echo PASS || echo FAIL; }

for t in 1 2 3 4; do
  sim "t$t" hazard_directed_tb "build/progs/t$t.mem" "" "+TEST=$t"
  check "T$t hazard_directed_tb" PASS "$(res t$t "TEST $t : PASS")"
done
python3 scripts/gen_t7_prog.py build/t7.mem >/dev/null || exit 1
sim t7 rawd3_tb build/t7.mem "" ""
check "T7 distance-3 RAW (register-file bypass)" PASS "$(res t7 'T7 RESULT: PASS')"
sim t7_neg rawd3_tb build/t7.mem "-DNO_RF_BYPASS" ""
check "  neg. control: -DNO_RF_BYPASS" FAIL "$(res t7_neg 'T7 RESULT: PASS')"
sim system riscv_pipeline_tb "" "" ""
check "riscv_pipeline_tb H1-H9 (system program)" PASS "$(res system 'TOP-TO-BOTTOM RUN : PASS')"

printf -- '----\nchecks as expected: %s   mismatches: %s   (%ss)\n' $ok $bad $(( $(date +%s) - t0 )) | tee -a "$OUT"
[ "$bad" = 0 ]

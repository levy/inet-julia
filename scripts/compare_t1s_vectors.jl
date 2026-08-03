#!/usr/bin/env julia
# ============================================================================
# compare_t1s_vectors.jl — compare two .vec files produced by T1S runs.
#
# Usage:
#   julia --project=. scripts/compare_t1s_vectors.jl <left.vec> <right.vec>
#
# Applies per-signal tolerance rules tuned for T1S semantics:
#   - Deterministic signals (curID, cycleLength, toLength, ownToLength,
#     packetPendingDelay, transmitOpportunityUsed): :exact.
#   - RNG-driven signals (packetInterval): :count_within(2).
#   - Everything else: default :exact.
#
# Exit code 0 if all comparisons pass; 1 if any mismatch.
# ============================================================================
using OmnetppSimulator

Base.length(ARGS) == 2 || (println(stderr, "usage: $(PROGRAM_FILE) <left.vec> <right.vec>"); exit(2))
left_path, right_path = ARGS[1], ARGS[2]

# Per-signal rules. Signal name-only matching (any module_path).
_rule_by_name = Dict(
    "curID"                  => (:exact,),
    "cycleLength"            => (:exact,),
    "toLength"               => (:exact,),
    "ownToLength"            => (:exact,),
    "packetPendingDelay"     => (:exact,),
    "transmitOpportunityUsed" => (:exact,),
    "controlStateChanged"    => (:exact,),
    "dataStateChanged"       => (:exact,),
    "rxCmd"                  => (:exact,),
    "txCmd"                  => (:exact,),
    "numFramesSent"          => (:exact,),
    "numFramesReceived"      => (:exact,),
    "carrierSenseChanged"    => (:exact,),
    "collisionChanged"       => (:exact,),
    "stateChanged"           => (:exact,),
    "transmissionStarted"    => (:exact,),
    "transmissionEnded"      => (:exact,),
    "receptionStarted"       => (:exact,),
    "receptionEnded"         => (:exact,),
    "receivedSignalType"     => (:exact,),
    "transmittedSignalType"  => (:exact,),
    "packetInterval"         => (:count_within, 2),
    "numPacketsPerTo"        => (:count_within, 2),
    "numPacketsPerCycle"     => (:count_within, 2),
    "numPacketsPerOwnTo"     => (:count_within, 2),
)

# Build full rules Dict by pairing every (module_path, name) in the left
# file with the name-based rule.
left = read_vec_file(left_path)
rules = Dict{Tuple{String,String}, Tuple}()
for v in left.vectors
    if haskey(_rule_by_name, v.name)
        rules[(v.module_path, v.name)] = _rule_by_name[v.name]
    end
end

report = compare_vec_files(left_path, right_path, rules)

println("Comparison: $(left_path) vs $(right_path)")
println("  matches      : $(Base.length(report.matches))")
println("  mismatches   : $(Base.length(report.mismatches))")
println("  missing left : $(Base.length(report.missing_left))")
println("  missing right: $(Base.length(report.missing_right))")

if !isempty(report.mismatches)
    println()
    println("MISMATCHES:")
    for d in report.mismatches
        println("  [$(d.verdict)] $(d.module_path).$(d.name) — $(d.detail)")
    end
end

exit(isempty(report.mismatches) ? 0 : 1)

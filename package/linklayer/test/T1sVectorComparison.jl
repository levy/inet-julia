# ============================================================================
# T1sVectorComparison.jl — comparing a T1S run's `.vec` output against the
# INET reference in `inet-reference/`.
#
# What is T1S-specific here is the RULE TABLE, not the comparison: which
# signals must match sample-for-sample and which are RNG-driven and may draw
# off-by-one for an equivalent stream. `compare_vec_files` (OmnetppSimulator)
# does the diffing; this decides the tolerances.
# ============================================================================

# Per-signal rules, matched on the signal's BASE name alone (any module path) —
# every node emits the same signal set, so a per-module table would be the same
# rule repeated once per node.
#
# "Base name" because a recorded vector is named `<signal>:<recording-mode>`,
# sometimes with a modifier: `curID:vector`, `decapPk:vector(packetBytes)`,
# `channelOwner:channelOwner`. The table keys on the part before the first `:`.
#
# Deterministic signals are :exact — the PLCA state machines are driven by the
# cycle structure, so an equivalent implementation reproduces them sample for
# sample. The packet-arrival signals are :count_within(2) because they are
# RNG-driven: INET and Julia consume their streams in a different order, so the
# counts agree only to within a draw or two.
const T1S_VECTOR_RULES = Dict{String, Tuple}(
    # PLCA control / cycle structure — deterministic.
    "curID"                   => (:exact,),
    "cycleLength"             => (:exact,),
    "toLength"                => (:exact,),
    "ownToLength"             => (:exact,),
    "packetPendingDelay"      => (:exact,),
    "transmitOpportunityUsed" => (:exact,),
    "controlStateChanged"     => (:exact,),
    "dataStateChanged"        => (:exact,),
    "rxCmd"                   => (:exact,),
    "txCmd"                   => (:exact,),
    # MAC / PHY counters and transitions — deterministic.
    "numFramesSent"           => (:exact,),
    "numFramesReceived"       => (:exact,),
    "carrierSenseChanged"     => (:exact,),
    "collisionChanged"        => (:exact,),
    "stateChanged"            => (:exact,),
    "transmissionStarted"     => (:exact,),
    "transmissionEnded"       => (:exact,),
    "receptionStarted"        => (:exact,),
    "receptionEnded"          => (:exact,),
    "receivedSignalType"      => (:exact,),
    "transmittedSignalType"   => (:exact,),
    # RNG-driven packet arrivals — counts within two draws.
    "packetInterval"          => (:count_within, 2),
    "numPacketsPerTo"         => (:count_within, 2),
    "numPacketsPerCycle"      => (:count_within, 2),
    "numPacketsPerOwnTo"      => (:count_within, 2),
)

"""
    signal_base_name(name) -> String

The signal name without its recording-mode suffix: `"curID:vector"` → `"curID"`,
`"decapPk:vector(packetBytes)"` → `"decapPk"`. A vector is recorded under
`<signal>:<mode>`, so this is what a per-signal rule has to key on.
"""
signal_base_name(name::AbstractString) = String(first(split(name, ':')))

"""
    t1s_vector_rules() -> Dict{String, Tuple}

The per-signal tolerance rules for a T1S run, keyed by signal base name. A copy,
so a caller can add or relax an entry for one comparison without disturbing the
shared table.
"""
t1s_vector_rules() = copy(T1S_VECTOR_RULES)

"""
    t1s_vector_rules(left::VecFile; rules = T1S_VECTOR_RULES) -> Dict{Tuple{String,String}, Tuple}

Expand the base-name-keyed rules into the `(module_path, name)` keys
`compare_vec_files` matches on, by pairing every vector present in `left` with
the rule for its base name. Signals with no entry keep the default `(:exact,)`.
"""
function t1s_vector_rules(left::VecFile; rules = T1S_VECTOR_RULES)
    expanded = Dict{Tuple{String,String}, Tuple}()
    for v in left.vectors
        rule = get(rules, signal_base_name(v.name), nothing)
        rule === nothing && continue
        expanded[(v.module_path, v.name)] = rule
    end
    return expanded
end

t1s_vector_rules(left_path::AbstractString; kwargs...) =
    t1s_vector_rules(read_vec_file(left_path); kwargs...)

"""
    compare_t1s_vectors(left, right; rules = T1S_VECTOR_RULES) -> VecCompareReport

Compare two T1S `.vec` files (paths or `VecFile`s) under the T1S tolerance
rules — typically `left` a Julia run and `right` the INET reference. Returns
the report; it prints nothing and never exits, so a test can assert on it and
a REPL session can pick it apart.

    report = compare_t1s_vectors("run.vec", "inet-reference/notraffic.vec")
    isempty(report.mismatches) || print_t1s_comparison(report)
"""
function compare_t1s_vectors(left::VecFile, right::VecFile; rules = T1S_VECTOR_RULES)
    compare_vec_files(left, right, t1s_vector_rules(left; rules = rules))
end

compare_t1s_vectors(left_path::AbstractString, right_path::AbstractString;
                    kwargs...) =
    compare_t1s_vectors(read_vec_file(left_path), read_vec_file(right_path); kwargs...)

"""
    print_t1s_comparison(report; io = stdout, label = nothing)

Human-readable summary of a `compare_t1s_vectors` report: the four counts, then
one line per mismatch. Separate from the comparison itself so the report stays
the return value.
"""
function print_t1s_comparison(report; io::IO = stdout, label = nothing)
    label === nothing || println(io, "Comparison: ", label)
    println(io, "  matches      : ", Base.length(report.matches))
    println(io, "  mismatches   : ", Base.length(report.mismatches))
    println(io, "  missing left : ", Base.length(report.missing_left))
    println(io, "  missing right: ", Base.length(report.missing_right))
    if !isempty(report.mismatches)
        println(io)
        println(io, "MISMATCHES:")
        for d in report.mismatches
            println(io, "  [", d.verdict, "] ", d.module_path, ".", d.name, " — ", d.detail)
        end
    end
    return nothing
end

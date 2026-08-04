# ============================================================================
# T1S stats phase 8 — comparison harness.
#
# Tests the compare_vec_files primitive and the "skip if reference absent"
# guard for INET-comparison tests.
# ============================================================================
using Test
using OmnetppSimulator
using InetLinkLayer
using InetLinkLayer.T1sModule

# Build a small in-memory VecFile for isolated tests (no round-trip through
# disk needed for the comparison logic itself).
_mksamples(pairs) = [VecSample(0, Float64(t), Float64(v)) for (t, v) in pairs]

_mkvec(id, path, name, pairs; columns = :TV) =
    VecVector(id, path, name, columns, Dict{String,String}(), _mksamples(pairs))

_mkfile(vs) = VecFile(3, "test-run", Dict{String,String}(), vs)

@testset "exact: identical vectors → all match" begin
    a = _mkfile([_mkvec(0, "Net.node[0]", "x", [(0.0, 1.0), (1e-6, 2.0)])])
    b = _mkfile([_mkvec(0, "Net.node[0]", "x", [(0.0, 1.0), (1e-6, 2.0)])])
    r = compare_vec_files(a, b)
    @test Base.length(r.matches) == 1
    @test isempty(r.mismatches)
end

@testset "exact: value mismatch is caught" begin
    a = _mkfile([_mkvec(0, "Net.node[0]", "x", [(0.0, 1.0), (1e-6, 2.0)])])
    b = _mkfile([_mkvec(0, "Net.node[0]", "x", [(0.0, 1.0), (1e-6, 3.0)])])
    r = compare_vec_files(a, b)
    @test isempty(r.matches)
    @test Base.length(r.mismatches) == 1
    @test r.mismatches[1].verdict === :value_mismatch
end

@testset "exact: sample-count mismatch is caught" begin
    a = _mkfile([_mkvec(0, "Net.node[0]", "x", [(0.0, 1.0)])])
    b = _mkfile([_mkvec(0, "Net.node[0]", "x", [(0.0, 1.0), (1e-6, 2.0)])])
    r = compare_vec_files(a, b)
    @test Base.length(r.mismatches) == 1
    @test r.mismatches[1].verdict === :sample_count
end

@testset "approx: within tolerance passes" begin
    a = _mkfile([_mkvec(0, "Net", "x", [(0.0, 1.0), (1e-6, 2.0)])])
    b = _mkfile([_mkvec(0, "Net", "x", [(0.0, 1.0000001), (1e-6, 1.9999999)])])
    rules = Dict{Tuple{String,String}, Tuple}(
        ("Net", "x") => (:approx, 1e-5))
    r = compare_vec_files(a, b, rules)
    @test Base.length(r.matches) == 1
end

@testset "count_within(n): count difference within tolerance passes" begin
    a = _mkfile([_mkvec(0, "N", "x", [(0.0, 1.0), (1e-6, 2.0), (2e-6, 3.0)])])
    b = _mkfile([_mkvec(0, "N", "x", [(0.0, 99.0), (1e-6, 88.0)])])  # values ignored
    rules = Dict{Tuple{String,String}, Tuple}(("N", "x") => (:count_within, 1))
    r = compare_vec_files(a, b, rules)
    @test Base.length(r.matches) == 1

    rules2 = Dict{Tuple{String,String}, Tuple}(("N", "x") => (:count_within, 0))
    r2 = compare_vec_files(a, b, rules2)
    @test Base.length(r2.mismatches) == 1
end

@testset "missing on either side is reported (not counted as mismatch)" begin
    a = _mkfile([_mkvec(0, "N", "x", [(0.0, 1.0)]),
                 _mkvec(1, "N", "y", [(0.0, 1.0)])])
    b = _mkfile([_mkvec(0, "N", "x", [(0.0, 1.0)])])
    r = compare_vec_files(a, b)
    @test Base.length(r.matches) == 1
    @test Base.length(r.missing_right) == 1
    @test r.missing_right[1].name == "y"
end

# --- T1S tolerance rules ---------------------------------------------------
# The rules key on the signal's BASE name, because a recorded vector is named
# `<signal>:<mode>` — a table keyed on bare names expands to nothing and every
# signal silently falls back to :exact.

@testset "signal_base_name strips the recording-mode suffix" begin
    @test signal_base_name("curID:vector") == "curID"
    @test signal_base_name("decapPk:vector(packetBytes)") == "decapPk"
    @test signal_base_name("channelOwner:channelOwner") == "channelOwner"
    @test signal_base_name("curID") == "curID"
end

@testset "t1s_vector_rules expands over the recorded names" begin
    f = _mkfile([_mkvec(0, "Net.node[0]", "curID:vector",          [(0.0, 1.0)]),
                 _mkvec(1, "Net.node[0]", "packetInterval:vector", [(0.0, 1.0)]),
                 _mkvec(2, "Net.node[0]", "unlisted:vector",       [(0.0, 1.0)])])
    rules = t1s_vector_rules(f)
    @test rules[("Net.node[0]", "curID:vector")] == (:exact,)
    @test rules[("Net.node[0]", "packetInterval:vector")] == (:count_within, 2)
    # No entry → compare_vec_files applies its own (:exact,) default.
    @test !haskey(rules, ("Net.node[0]", "unlisted:vector"))
end

@testset "compare_t1s_vectors applies the RNG tolerance" begin
    # packetInterval is RNG-driven: a one-draw count difference must pass,
    # while the same difference on a deterministic signal must not.
    a = _mkfile([_mkvec(0, "N", "packetInterval:vector", [(0.0, 1.0), (1e-6, 2.0), (2e-6, 3.0)])])
    b = _mkfile([_mkvec(0, "N", "packetInterval:vector", [(0.0, 9.0), (1e-6, 8.0)])])
    @test isempty(compare_t1s_vectors(a, b).mismatches)

    c = _mkfile([_mkvec(0, "N", "curID:vector", [(0.0, 1.0), (1e-6, 2.0), (2e-6, 3.0)])])
    d = _mkfile([_mkvec(0, "N", "curID:vector", [(0.0, 1.0), (1e-6, 2.0)])])
    @test Base.length(compare_t1s_vectors(c, d).mismatches) == 1
end

# --- INET reference comparison: skip gracefully if reference files absent ---

const _INET_REF_DIR = joinpath(@__DIR__, "inet-reference")

@testset "INET reference comparison (skipped when files absent)" begin
    ref = joinpath(_INET_REF_DIR, "notraffic.vec")
    if !isfile(ref)
        @test true   # placeholder — no reference to compare against
        @info "no INET reference at $ref — skipping cross-comparison"
    else
        # Generate our .vec output for notraffic.
        mktempdir() do tmp
            our_vec = joinpath(tmp, "notraffic.vec")
            t = SimulationType(T1sModel)
            a = ParameterAssignment(Dict{Symbol,Any}(
                :n_nodes    => 5,
                :time_limit => 100e-6,
                :scenario   => :notraffic,
                :vec_path   => our_vec))
            run = expand_simulation(configure_simulation(t, a))[1]
            inst = prepare_simulation_execution(run;
                                                engine = SequentialEngineSpec())
            run_simulation!(inst)
            finish_simulation!(inst)

            # Compare — every signal we emit should match INET's on every
            # (time, value) sample. `busUsed` / `throughput` are INET-only
            # signals we don't compute yet; they show up as :missing_right.
            # `transmitting` INET emits with double-init t=0 samples that
            # produce a value_mismatch (semantically equal). All other
            # signals should match exactly.
            r = compare_vec_files(our_vec, ref)
            expected_mismatches = Set([
                "transmitting:vector",     # INET double-init at t=0
                "busUsed:vector",          # INET-specific formula, not computed
                "throughput:vector",       # INET-specific formula, not computed
            ])
            unexpected = filter(r.mismatches) do d
                !(d.name in expected_mismatches)
            end
            if !isempty(unexpected)
                for d in unexpected
                    @info "unexpected mismatch: $(d.module_path).$(d.name) — $(d.detail)"
                end
            end
            @test isempty(unexpected)
        end
    end
end

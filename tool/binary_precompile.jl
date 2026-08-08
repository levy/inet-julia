# ============================================================================
# What the build runs so the image holds compiled code.
#
# `create_app` compiles what this script executes. What it does not execute,
# the user's first run compiles instead — and for a parser that is most of the
# run (plan/done/native-simulation-binary.md, phase 4).
#
# Two halves, and the first is the expensive one:
#
#   1. Parse every NED and INI file INET has. A Lerche transformer callback
#      compiles the first time a grammar production reaches it, so the cost of
#      a run tracks which productions the file uses and not how big it is. The
#      corpus is the surest way to reach them all — see tool/corpus/SOURCE.md
#      for the measurement that says so.
#   2. Run one whole simulation, so the builder, the engine, the elements and
#      the recorder are compiled too.
# ============================================================================

using InetRunner
using OmnetppFormat: nedparse_file, iniparse_file

const CORPUS = joinpath(@__DIR__, "corpus")

# ── 1. The grammar ───────────────────────────────────────────────────────────

function parse_corpus()
    ned = String[]
    ini = String[]
    for (directory, _, files) in walkdir(CORPUS), file in files
        endswith(file, ".ned") && push!(ned, joinpath(directory, file))
        endswith(file, ".ini") && push!(ini, joinpath(directory, file))
    end
    sort!(ned); sort!(ini)

    failed = 0
    # A file that will not parse still compiled everything the attempt
    # reached, which is the point here. One NED file of INET is a malformed
    # documentation snippet and never parses; see tool/corpus/SOURCE.md.
    for path in ned
        try; nedparse_file(path); catch; failed += 1; end
    end
    for path in ini
        try; iniparse_file(path); catch; failed += 1; end
    end
    (length(ned), length(ini), failed)
end

let (ned_count, ini_count, failed) = parse_corpus()
    @info "Parsed the grammar corpus" ned = ned_count ini = ini_count failed
end

# ── 2. A whole run ───────────────────────────────────────────────────────────

const NED = """
network PrecompileNetwork
{
    submodules:
        producer: ActivePacketSource {
            productionInterval = default(1s);
        }
        consumer: PassivePacketSink;
    connections:
        producer.out --> consumer.in;
}
"""

const INI = """
[General]
network = PrecompileNetwork
sim-time-limit = 3s
*.producer.packetLength = 1B
"""

mktempdir() do directory
    write(joinpath(directory, "precompile.ned"), NED)
    write(joinpath(directory, "omnetpp.ini"), INI)
    results = joinpath(directory, "results")
    # The whole path: read the command line, read both files, build the
    # network, run the engine, write both result files.
    InetRunner.main(["-f", joinpath(directory, "omnetpp.ini"), "-c", "General",
                     "-r", "0", "--result-dir=$results"]; io = devnull)
    # The two paths that answer without running anything.
    InetRunner.main(["-h"]; io = devnull)
    InetRunner.main(["--version"]; io = devnull)
end

# ── 3. A run from a real INI file ────────────────────────────────────────────
#
# Parsing an INI file is not the same as reading a configuration out of one.
# The four-line file above has one section and one rule, so the section chain,
# the `extends` walk, the reference patterns and the glob matching are barely
# touched by it. Measured: with the corpus parsed but this step missing, the
# tutorial's NED cost nothing and its 49-section INI cost 1.2 s.
#
# The tutorial is in the corpus, so this needs no checkout beside the build.

const TUTORIAL = joinpath(CORPUS, "tutorials", "queueing", "omnetpp.ini")

if isfile(TUTORIAL)
    mktempdir() do directory
        for configuration in ("ActiveSourcePassiveSink", "PacketQueue")
            InetRunner.main(["-f", TUTORIAL, "-c", configuration, "-r", "0",
                             "-n", dirname(TUTORIAL),
                             "--result-dir=$(joinpath(directory, configuration))"];
                            io = devnull)
        end
    end
else
    @warn "no tutorial INI in the corpus — a run will pay for its own compilation" TUTORIAL
end

# The error paths are taken by every script that drives many runs, so they are
# worth their compile time too.
InetRunner.main(["--no-such-option"]; io = devnull)
InetRunner.main(["-f", "/nonexistent/nope.ini", "-c", "General"]; io = devnull)

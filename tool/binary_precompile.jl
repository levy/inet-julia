# ============================================================================
# What the build runs so the image holds compiled code.
#
# `create_app` compiles what this script executes. Without it the first run of
# the binary compiles the engine, the elements and the recorder again, and a
# user's first simulation pays what a build should have paid
# (plan/done/native-simulation-binary.md, phase 4).
#
# Keep it to the paths a real run takes, and keep it short. A longer simulation
# compiles nothing a short one does not.
# ============================================================================

using InetRunner

# A NED file and an INI file small enough to write here, so the build compiles
# the parsers, the builder and the engine without needing a checkout beside it.
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

# The error paths are taken by every script that drives many runs, so they are
# worth their compile time too.
InetRunner.main(["--no-such-option"]; io = devnull)
InetRunner.main(["-f", "/nonexistent/nope.ini", "-c", "General"]; io = devnull)

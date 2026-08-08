# ============================================================================
# What the build runs so the image holds compiled code.
#
# `create_app` compiles what this script executes. Without it the first run of
# the binary compiles the engine, the elements and the recorder again, and a
# user's first simulation pays what a build should have paid
# (plan/pending/native-simulation-binary.md, phase 4).
#
# Keep it to the paths a real run takes, and keep it short. A longer simulation
# compiles nothing a short one does not.
# ============================================================================

using InetRunner

mktempdir() do directory
    # The whole path: read the command line, build the model, run the engine,
    # write both result files.
    InetRunner.main(["-c", "Queuing", "-r", "0", "--result-dir=$directory"];
                    io = devnull)
    # The two paths that answer without running anything.
    InetRunner.main(["-h"]; io = devnull)
    InetRunner.main(["--version"]; io = devnull)
end

# The error paths are taken by every script that drives many runs, so they are
# worth their compile time too.
InetRunner.main(["--no-such-option"]; io = devnull)
InetRunner.main(["-c", "NoSuchConfiguration"]; io = devnull)

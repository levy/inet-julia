# Open the demo catalog in the editor.
#
#     julia --project=. package/inet/example/demo/run.jl
#
# The same thing `run_demo()` does from the REPL, for when a shell is what you
# have. See `InetExample.run_demo` for the keywords.
using InetExample
using ProjecturedSdl: SdlBackend

run_demo(; backend = SdlBackend())

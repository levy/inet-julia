# ============================================================================
# The result files — where a run's numbers land, and what says which run made
# them.
#
# The names and the run attributes are OMNeT++'s, because `opp_scavetool` and
# the readers of `OmnetppLegacy` both key on them, and because a Julia file and
# a C++ file of the same configuration are meant to be compared with one tool
# (plan/done/native-simulation-binary.md §4.6).
# ============================================================================

"""
    ResultFilesModule

The paths, the run name and the run attributes of one run's result files.

Everything here takes the run number the way the user wrote it — counted from
0 — because these values are read by a person and by `opp_scavetool`, and both
expect what `opp_run` writes.
"""
module ResultFilesModule

using Dates: DateTime, format

export scalar_file_path, vector_file_path, result_run_name, result_run_attributes,
    result_datetime

"""
    result_datetime(moment) -> String

The moment a run started, spelled the way OMNeT++ spells it in a result file:
`20260808-11:35:28`.
"""
result_datetime(moment::DateTime) = format(moment, "yyyymmdd-HH:MM:SS")

scalar_file_path(result_dir, config, run_number) =
    joinpath(result_dir, "$config-#$run_number.sca")

vector_file_path(result_dir, config, run_number) =
    joinpath(result_dir, "$config-#$run_number.vec")

"""
    result_run_name(config, run_number, moment, process_id) -> String

The name of the run, which is what the `run` line of both files carries:
`<configuration>-<run number>-<datetime>-<process id>`.

Two runs of one configuration must not share it, which is what the moment and
the process id are for.
"""
result_run_name(config, run_number, moment::DateTime, process_id::Integer) =
    "$config-$run_number-$(result_datetime(moment))-$process_id"

"""
    result_run_attributes(; …) -> Vector{Pair{String,String}}

The `attr` lines of the run header — what was run, when, and by which process.

A C++ file carries eleven more. They describe a parameter study: the iteration
variables, the measurement, the experiment, the repetition, the replication and
the seed set. This runner runs one run of one configuration, so every one of
them would be a constant. They arrive with the parameter study.
"""
result_run_attributes(; config, run_number, network, moment::DateTime,
                      process_id::Integer, ini_file) =
    ["configname" => String(config),
     "datetime"   => result_datetime(moment),
     "inifile"    => String(ini_file),
     "network"    => String(network),
     "processid"  => string(process_id),
     "runnumber"  => string(run_number)]

end # module ResultFilesModule

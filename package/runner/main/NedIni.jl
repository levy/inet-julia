# ============================================================================
# NedIni — the glue that lets `OmnetppDescription` build `InetQueuing`.
#
# Two things per element: the NED type name it answers to, and how a resolved
# set of parameters becomes its constructor call. Most elements need only the
# first, because their `Parameters` struct already has one field per NED
# parameter under the Julia spelling of its name.
#
# **Where this belongs is still open.** It sits in the test package because
# `InetQueuing` should not gain a dependency on the reader — and through it on
# Lerche — for the sake of a model that nobody reads NED for. The permanent
# home is either that dependency, taken deliberately, or a small glue package
# beside the two. Decide it when a second model library needs the same thing.
# ============================================================================

module NedIni

using OmnetppDescription
using OmnetppUnits: AbstractDuration, AbstractInformation, seconds, ustrip, uconvert, bit
using InetPacket.PacketModule: BitLength, Bits, Bytes
using InetQueuing.ActivePacketSourceElement: ActivePacketSourceModule
using InetQueuing.PassivePacketSinkElement: PassivePacketSinkModule
using InetQueuing.ActivePacketSinkElement: ActivePacketSinkModule
using InetQueuing.PacketQueueElement: PacketQueueModule, PacketQueueParameters
using InetQueuing.PacketSourceModule: PacketTemplate

export register_queuing_ned_types!

# ── Conversions at the seam ─────────────────────────────────────────────
#
# The reader answers with a quantity, because that is what the file says. An
# element field wants the type it was written for. Neither should bend: the
# conversion belongs here, where the two meet.

"A duration as the bare number of seconds an element's `Float64` field wants."
_offset(v) = v isa AbstractDuration ? seconds(v) : Float64(v)

"An information quantity as the `BitLength` an element's field wants."
_length(v::BitLength) = v
_length(v) = v isa AbstractInformation ? Bits(round(Int, ustrip(uconvert(bit, v)))) :
             Bits(round(Int, v))

_length_or(values, key, default) = haskey(values, key) ? _length(values[key]) : default

# The sinks need no hook at all: a kind declared with `@simulation_module`
# answers for its own parameters, and the builder asks it.

# ── PacketQueue: one conversion, otherwise a fit ────────────────────────

OmnetppDescription.ned_parameters_type(::Type{PacketQueueModule}) = PacketQueueParameters

function OmnetppDescription.build_ned_module(::Type{PacketQueueModule}, name::Symbol,
                                             values::AbstractDict{Symbol})
    PacketQueueModule(name, PacketQueueParameters(;
        packet_capacity = _capacity(get(values, :packet_capacity, nothing)),
        data_capacity = haskey(values, :data_capacity) ?
                        _capacity_length(values[:data_capacity]) : nothing))
end

# NED writes "no limit" as -1, and this port writes it as `nothing`.
_capacity(v) = (v === nothing || v < 0) ? nothing : Int(v)
_capacity_length(v) = begin
    l = _length(v)
    bits(l) < 0 ? nothing : l
end

# ── ActivePacketSource: three NED parameters become one field ───────────
#
# `packetLength`, `packetData` and `attachCreationTimeTag` are a `PacketTemplate`
# here, so no name mapping can express the translation and the hook does it.

OmnetppDescription.ned_parameter_fields(::Type{ActivePacketSourceModule}) =
    (:production_interval, :initial_production_offset,
     :packet_length, :packet_data, :attach_creation_time_tag)

function OmnetppDescription.build_ned_module(::Type{ActivePacketSourceModule}, name::Symbol,
                                             values::AbstractDict{Symbol})
    haskey(values, :production_interval) ||
        error("build_ned_module: $name has no productionInterval. The NED declares it " *
              "without a default, so a configuration must assign it.")
    template = PacketTemplate(;
        length = _length_or(values, :packet_length, Bytes(1000)),
        data = get(values, :packet_data, nothing),
        attach_creation_time = get(values, :attach_creation_time_tag, true))
    ActivePacketSourceModule(name;
        production_interval = values[:production_interval],
        initial_production_offset = _offset(get(values, :initial_production_offset, -1.0)),
        packet = template)
end

# ── The names ───────────────────────────────────────────────────────────

"""
    register_queuing_ned_types!()

Say which Julia type each NED type name of this wave means. Idempotent, so a
suite may call it twice in one session.
"""
function register_queuing_ned_types!()
    register_ned_type!("inet.queueing.source.ActivePacketSource", ActivePacketSourceModule)
    register_ned_type!("inet.queueing.sink.PassivePacketSink", PassivePacketSinkModule)
    register_ned_type!("inet.queueing.sink.ActivePacketSink", ActivePacketSinkModule)
    register_ned_type!("inet.queueing.queue.PacketQueue", PacketQueueModule)
    nothing
end

end # module NedIni

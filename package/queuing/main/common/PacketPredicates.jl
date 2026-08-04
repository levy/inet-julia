"""
    PacketPredicateModule

**The questions elements ask about a packet**, as values.

A filter takes a predicate, a content-based classifier takes one per output,
and both are `packet -> Bool`. INET writes those as strings its runtime parses
(`expr(ByteCountChunk.data == 0)`) and names stock ones by class
(`classifierClass = "inet::…"`). Here a predicate is an ordinary function, so
the interesting question is not how to express one but how to *hand one over* —
by writing it inline, or by naming one that was registered.

Two builders cover the tutorial's stock policies:

- [`data_predicate`](@ref) compares the value the source wrote on the packet
  against something, which is the comparator INET's steps reach for;
- [`ordinal_predicate`](@ref) asks *which* packet this is rather than what is
  in it, which is what an ordinal dropper or duplicator needs.

and [`register_packet_predicate!`](@ref) is the named catalog, so a
configuration can say `"every_other"` where a program would pass a closure.
"""
module PacketPredicateModule

using InetPacket.PacketModule: Packet
using ..PacketSourceModule: packet_data

export data_predicate, ordinal_predicate,
       register_packet_predicate!, packet_predicate, packet_predicate_names

"""
    data_predicate(relation, value) -> (packet -> Bool)

Compare what the source wrote on the packet against `value`, with `relation` —
`==`, `<`, `>=`, `in`, anything of two arguments.

A packet carrying no value never satisfies the comparison rather than erroring:
a stream where only some packets are labelled is an ordinary thing, and the
element asking is entitled to a plain no.

    data_predicate(==, 3)          # exactly the packets labelled 3
    data_predicate(>=, 10)         # everything from 10 up
    data_predicate(in, (1, 4, 9))  # one of these
"""
function data_predicate(relation, value)
    function (packet::Packet)
        data = packet_data(packet)
        data === nothing && return false
        relation(data, value)
    end
end

"""
    ordinal_predicate(accept) -> (packet -> Bool)

Ask *which* packet this is: the returned predicate counts the packets it is
shown and answers `accept(n)` for the `n`-th, ignoring what is in it.

The count lives in the predicate, so each one made is a separate stream
position — two elements given the same `accept` count independently, which is
what you want when both are looking at their own traffic.

    ordinal_predicate(n -> n % 2 == 1)     # every other packet
    ordinal_predicate(n -> n > 100)        # everything after the first hundred
"""
function ordinal_predicate(accept)
    count = Ref(0)
    function (_packet::Packet)
        count[] += 1
        accept(count[])
    end
end

# ── The named catalog ───────────────────────────────────────────────────────
#
# INET names a stock policy by the class that implements it. A name is still
# useful here — a step file is JSON, and JSON cannot hold a closure — but what
# it names is a function rather than a class, and anything may register one.

const _PACKET_PREDICATES = Dict{Symbol,Any}()

"""
    register_packet_predicate!(name, builder) -> builder

Register `builder` under `name`. `builder(arguments...)` returns the predicate,
so a name can take parameters: `packet_predicate(:data_equals, 3)` builds the
predicate for that value rather than looking up a fixed one.

Registering an existing name replaces it — a library that ships a default and a
model that wants its own should not have to fight over load order.
"""
function register_packet_predicate!(name::Symbol, builder)
    _PACKET_PREDICATES[name] = builder
    builder
end

"""
    packet_predicate(name, arguments...) -> (packet -> Bool)

Build the registered predicate `name`. Errors — naming what *is* registered —
when there is no such name, because a configuration that asks for a policy
nobody registered has said something wrong and should hear about it.
"""
function packet_predicate(name::Symbol, arguments...)
    builder = get(_PACKET_PREDICATES, name, nothing)
    builder === nothing &&
        error("packet_predicate: no predicate named ", repr(name),
              " — registered: (", join(packet_predicate_names(), ", "), ")")
    builder(arguments...)
end

"""
    packet_predicate_names() -> Vector{Symbol}

Every registered name, sorted. What a form offers, and what an error message
lists.
"""
packet_predicate_names() = sort!(collect(keys(_PACKET_PREDICATES)))

# The stock policies, registered here so a name works without anyone importing
# this module first. Runtime state, so `__init__` rather than top level.
function __init__()
    register_packet_predicate!(:always, () -> (_ -> true))
    register_packet_predicate!(:never, () -> (_ -> false))
    register_packet_predicate!(:data_equals, value -> data_predicate(==, value))
    register_packet_predicate!(:data_below, value -> data_predicate(<, value))
    register_packet_predicate!(:data_at_least, value -> data_predicate(>=, value))
    register_packet_predicate!(:data_one_of, values -> data_predicate(in, values))
    # "Every k-th packet", counting from one: k = 2 is every other.
    register_packet_predicate!(:every_nth, k -> ordinal_predicate(n -> n % k == 0))
    # "All but every k-th", which is the dropper's half of the same question.
    register_packet_predicate!(:except_every_nth, k -> ordinal_predicate(n -> n % k != 0))
    register_packet_predicate!(:after_first, k -> ordinal_predicate(n -> n > k))
end

end # module PacketPredicateModule

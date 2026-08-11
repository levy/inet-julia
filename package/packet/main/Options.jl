# ============================================================================
# `Options` — an ordered list of type-length-value options.
#
# This is the shape of IPv4 options, TCP options, the IPv6 hop-by-hop and
# destination options, the DHCP options, the SCTP INIT parameters, the MIPv6
# mobility options, the BGP path attributes and the 802.11 information
# elements. It is also the largest gap in INET itself: its
# `SERIALIZER_REMAINING_GAPS.md` names four families that lose bytes for want
# of it, all with the same cause — a fixed struct of known options cannot
# preserve the order the sender used and cannot hold a code it does not know.
#
# Both losses break a byte round trip, so the list here is ordered from the
# start and an unknown code becomes a raw member that keeps its bytes.
#
# A family is an abstract type and three methods:
#
#     abstract type TcpOption <: Fields end
#
#     @header TcpOptionMaxSegmentSize <: TcpOption begin
#         kind             :: Constant{U8, TCPOPTION_MAX_SEGMENT_SIZE}
#         length           :: Constant{U8, 0x04}
#         max_segment_size :: U16
#     end
#
#     list_options(::Type{TcpOption})     = (TcpOptionEnd, TcpOptionNop, …)
#     find_raw_option(::Type{TcpOption})  = TcpOptionUnknown
#     ends_option_list(::Type{TcpOption}, code) = code == TCPOPTION_END
#
# and a header carries one with a window:
#
#     options :: Options{TcpOption}
#         until(Bytes(4) * data_offset)
#
# `until` gives the offset the list ends at, counted from the start of the
# header. The reader reads options until an ending code appears or the window
# runs out, and then skips whatever padding is left — which is what INET's
# option loops do, without the two infinite loops the C++ branch had to fix.
# ============================================================================

"""
    list_options(::Type{FAMILY})::Tuple

Every option type the family knows, as a tuple of types. Explicit rather than
discovered: it is self-describing, and it has no world-age trap.
"""
function list_options end

"""
    find_raw_option(::Type{FAMILY})::Type

The member that holds an option the family does not know — its code, its length
and its bytes. Without one, an unknown option would be dropped and the list
would not round-trip.
"""
function find_raw_option end

"""
    option_code(::Type{MEMBER})

The code that selects this member. `@header` defines it from the member's first
field when that field is a `Constant`.
"""
function option_code end

"""
    ends_option_list(::Type{FAMILY}, code)::Bool

Whether this code ends the list early, whatever the window still has left. That
is IPv4's END_OF_OPTIONS and TCP's End of Option List. The default is `false`.
"""
ends_option_list(::Type, code) = false

"""
    measure_option_code(::Type{FAMILY})::Int

How many bits the reader looks at to choose a member. Eight for every family
INET has.
"""
measure_option_code(::Type) = 8

"""
    find_option_type(::Type{FAMILY}, code)::Type

The member a code selects, or the family's raw member when no member claims it.
"""
function find_option_type(::Type{FAMILY}, code) where {FAMILY}
    for member in list_options(FAMILY)
        option_code(member) == code && return member
    end
    return find_raw_option(FAMILY)
end

"""
    Options{FAMILY}(values)

An ordered list of options, in the order the sender wrote them.
"""
struct Options{FAMILY}
    values::Vector{FAMILY}
end

Options{FAMILY}(value::Options{FAMILY}) where {FAMILY} = value
Base.convert(::Type{Options{FAMILY}}, values::AbstractVector) where {FAMILY} =
    Options{FAMILY}(Vector{FAMILY}(values))
Base.:(==)(a::Options{F}, b::Options{F}) where {F} = a.values == b.values
Base.hash(value::Options, seed::UInt) = hash(value.values, hash(:Options, seed))
Base.length(value::Options) = Base.length(value.values)
Base.getindex(value::Options, index) = value.values[index]
Base.iterate(value::Options, state...) = iterate(value.values, state...)
Base.eltype(::Type{Options{FAMILY}}) where {FAMILY} = FAMILY
Base.show(io::IO, value::Options) =
    print(io, "[", join((string(nameof(typeof(v))) for v in value.values), ", "), "]")

is_variable_field(::Type{<:Options}) = true
has_field_bits(::Type{<:Options}) = false
classify_display(::Type{<:Options}) = :composite
format_field(value::Options) = string(value)

# On write the list is exactly its options; a header that pads follows it with
# a `Pad` field, as IPv4 and TCP do.
measure_value(value::Options, ::Int) =
    sum(bits(chunk_length(option)) for option in value.values; init = 0)

function write_field(io::BitWriter, ::Type{Options{FAMILY}}, value::Options{FAMILY},
                     ::Int, ::Symbol) where {FAMILY}
    for option in value.values
        serialize(io, option)
    end
    return io
end

# On read the list fills its window: options until an ending code or until the
# window runs out, and then whatever padding is left.
function read_field(io::BitReader, ::Type{Options{FAMILY}}, width::Int,
                    ::Symbol) where {FAMILY}
    values = FAMILY[]
    stop = io.bit_pos + width
    code_width = measure_option_code(FAMILY)
    while io.bit_pos + code_width <= stop
        code = peek_option_code(io, code_width)
        member = find_option_type(FAMILY, code)
        before = io.bit_pos
        option = deserialize(member, io)
        push!(values, option)
        # A member that reads nothing would spin forever. The C++ branch fixed
        # exactly that twice — in the IPv6 TLV reader and in the BGP length
        # reader — so the loop refuses rather than hangs.
        io.bit_pos > before ||
            error("Options{$(FAMILY)}: `$(nameof(member))` read no bits; the list " *
                  "would never end")
        ends_option_list(FAMILY, code) && break
    end
    # Whatever is left of the window is padding, and it is the writer's `Pad`
    # field that put it there.
    io.bit_pos < stop && skip_bits!(io, stop - io.bit_pos)
    return Options{FAMILY}(values)
end

"The next `width` bits, without consuming them."
function peek_option_code(io::BitReader, width::Int)
    at = io.bit_pos
    code = read_bits!(io, width)
    io.bit_pos = at
    return code
end

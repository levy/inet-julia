# ============================================================================
# `@header` — one declaration produces the struct AND its codec.
#
# In INET a `.msg` file generates the C++ struct and a HAND-WRITTEN `.cc`
# serializer must stay in sync; they can drift, which is part of why
# `improperlyRepresented` exists. Here a single macro emits the immutable
# struct, `chunk_length`, `serialize`, and `deserialize` from the same
# declaration, so drift is impossible.
#
# Syntax — one line per field, segments separated by `|`:
#
#     name :: Type | width | base | order | clause(expr) … = default
#
#     @header Ipv4Header begin
#         version      :: UInt8  | 4
#         ihl          :: UInt8  | 4
#         dscp         :: UInt8  | 6
#         ecn          :: UInt8  | 2
#         total_length :: UInt16                # width omitted → field_width(T)
#         src_address  :: Ipv4Address           # a field type, not an integer
#         checksum     :: UInt16 | 16 | hex     # how a reader sees it
#         duration     :: UInt16 | 16 | le      # least significant byte first
#         reserved     :: UInt8  | 4 | constant(0x00)   # wire only
#         checksum_mode:: ChecksumMode | 0 = DECLARED   # model only
#         sfd          :: UInt8  | 8 = 0xD5     # a default, for a constant field
#     end
#
# A segment is one of four things, and the macro tells them apart by shape:
#
#   an integer or any other expression   the width in bits
#   `bin` `dec` `hex` `mac` `ipv4`       the display base
#   `ipv6` `enum`
#   `be` `le`                            the byte order, big-endian by default
#   `constant(v)`                        a clause
#
# Width zero is not a degenerate case, it is a rule: a **model-only** field is
# in the struct and not on the wire. That is how a header carries state its
# protocol needs and its format does not — INET's `ChecksumMode`, `FcsMode`
# and `Ieee80211MacHeader::MACArrive`. A model-only field must have a default,
# because a reader has no bits to give it.
#
# `constant(v)` is the mirror: a **wire-only** field takes width, is not in the
# struct, writes `v`, and discards what it reads. That is a reserved field and
# a fixed delimiter — INET's `stream.writeByte(0x4E)`.
#
# What's generated:
#   struct Ipv4Header <: Fields; version::UInt8; ihl::UInt8; ... end
#   chunk_length(::Ipv4Header) = Bits(<sum-of-widths>)
#   serialize(w::BitWriter, h::Ipv4Header) — writes each field's low bits
#   deserialize(::Type{Ipv4Header}, r::BitReader) — reads and constructs
#   header_layout(::Type{Ipv4Header}) — the name, the offset, the width and the
#       display base of every field, which is what a view of a packet needs
#   a keyword constructor, when at least one field carries a default
#
# The field-type protocol of `FieldTypes.jl` is what lets a field be a
# `MacAddress`: the macro asks the type how wide it is, and asks it to write
# and read itself. A type wider than 64 bits answers `field_write` and
# `field_read` directly; every other type inherits them from `field_encode`
# and `field_decode`.
#
# Headers whose codec cannot be described declaratively (variable-length tails)
# just define `serialize`/`deserialize` directly — dispatch wins, there is
# nothing to register.
# ============================================================================

# Fallback (overridable by hand for variable-length headers):
function serialize end
function deserialize end

const _FIELD_BASES  = (:bin, :dec, :hex, :mac, :ipv4, :ipv6, :enum)
const _FIELD_ORDERS = (:be, :le)
const _FIELD_CLAUSES = (:constant,)

# One field of a declaration, after the parse.
#
#   kind      `:wire` (struct and wire), `:model` (struct only),
#             `:constant` (wire only)
#   width     an expression, or `nothing` for the field type's own width
#   base      an expression for the display base, or `nothing`
#   order     `:be` or `:le`
#   default   an expression, or `nothing`
#   value     the constant a `:constant` field writes
struct FieldDecl
    name::Symbol
    type::Any
    kind::Symbol
    width::Any
    base::Union{Symbol, Nothing}
    order::Symbol
    default::Any
    value::Any
end

"Peel the `|` chain of a field declaration into its head and its segments."
function _split_segments(expr)
    segments = Any[]
    while Meta.isexpr(expr, :call) && expr.args[1] === :| && Base.length(expr.args) == 3
        pushfirst!(segments, expr.args[3])
        expr = expr.args[2]
    end
    return expr, segments
end

# A default parses as a block when the line has more than one `|` segment, and
# a block that holds one value is that value.
function _unwrap_block(expr)
    Meta.isexpr(expr, :block) || return expr
    values = filter(a -> !(a isa LineNumberNode), expr.args)
    return Base.length(values) == 1 ? values[1] : expr
end

"Parse one field declaration."
function _parse_field(expr)
    default = nothing
    if Meta.isexpr(expr, :(=)) && Base.length(expr.args) == 2
        expr, default = expr.args[1], _unwrap_block(expr.args[2])
    end

    head, segments = _split_segments(expr)
    Meta.isexpr(head, :(::)) && Base.length(head.args) == 2 ||
        error("@header: expected `name :: Type`, got $head")
    name, type = head.args[1]::Symbol, head.args[2]

    width = nothing
    base = nothing
    order = :be
    value = nothing
    kind = :wire
    for segment in segments
        if segment isa Symbol
            if segment in _FIELD_BASES
                base = segment
            elseif segment in _FIELD_ORDERS
                order = segment
            else
                error("@header $name: unknown segment `$segment`; a display base is one of " *
                      "$(_FIELD_BASES) and a byte order is one of $(_FIELD_ORDERS)")
            end
        elseif Meta.isexpr(segment, :call) && segment.args[1] in _FIELD_CLAUSES
            clause = segment.args[1]
            Base.length(segment.args) == 2 ||
                error("@header $name: `$clause` takes one argument")
            kind = :constant
            value = segment.args[2]
        elseif Meta.isexpr(segment, :call) && segment.args[1] isa Symbol &&
               Base.isidentifier(segment.args[1]) && segment.args[1] !== :|
            # A call the macro does not know is a clause of a later phase, and
            # naming it in the error beats "unexpected width expression".
            error("@header $name: unknown clause `$(segment.args[1])`; " *
                  "this phase knows $(_FIELD_CLAUSES)")
        else
            width === nothing ||
                error("@header $name: two width segments, `$width` and `$segment`")
            width = segment
        end
    end

    # Width zero says model-only, and a model-only field cannot also be a
    # constant: it has no bits for a constant to occupy.
    if width isa Integer && width == 0
        kind === :wire ||
            error("@header $name: a model-only field (width 0) cannot be `constant`")
        kind = :model
        default === nothing &&
            error("@header $name: a model-only field needs a default; a reader has no bits for it")
    end
    kind === :constant && default !== nothing &&
        error("@header $name: a `constant` field is not in the struct, so it cannot have a default")

    return FieldDecl(name, type, kind, width, base, order, default, value)
end

macro header(name, block)
    Meta.isexpr(block, :block) ||
        error("@header $name: expected a `begin … end` block")

    fields = FieldDecl[]
    for line in block.args
        line isa LineNumberNode && continue
        push!(fields, _parse_field(line))
    end
    isempty(fields) && error("@header $name: no fields")

    # The struct holds what the model has: the wire fields and the model-only
    # fields, in declaration order. The wire holds what the format has: the
    # wire fields and the constants.
    stored = filter(f -> f.kind !== :constant, fields)
    isempty(stored) && error("@header $name: every field is `constant`, so the struct is empty")
    on_wire = filter(f -> f.kind !== :model, fields)

    struct_fields = [Expr(:(::), esc(f.name), esc(f.type)) for f in stored]

    # Widths — a missing width is the type's own, which is `sizeof(T) * 8` for
    # an integer and 48 for a `MacAddress`.
    M = @__MODULE__
    width_of(f) = f.width === nothing ? :($(M).field_width($(esc(f.type)))) : esc(f.width)
    total_expr = isempty(on_wire) ? 0 : Expr(:call, :+, (width_of(f) for f in on_wire)...)

    # serialize: write each field on the wire. `M.field_write` so the generated
    # code doesn't rely on the caller having imported it.
    write_calls = Expr[]
    for f in on_wire
        source = f.kind === :constant ? esc(f.value) : :(h.$(f.name))
        push!(write_calls,
              :($(M).field_write(io, $(esc(f.type)), $(source),
                                 $(width_of(f)), $(QuoteNode(f.order)))))
    end

    # deserialize: read each field, then call the ctor. A constant is read and
    # dropped; a model-only field takes its default.
    read_body = Expr[]
    for f in on_wire
        call = :($(M).field_read(io, $(esc(f.type)), $(width_of(f)), $(QuoteNode(f.order))))
        push!(read_body, f.kind === :constant ? call : :($(esc(f.name)) = $call))
    end
    ctor_args = [f.kind === :model ? esc(f.default) : esc(f.name) for f in stored]
    ctor_call = Expr(:call, esc(name), ctor_args...)

    # The layout descriptor, built once at declaration time and returned by a
    # method on the type. The const lives in the caller's module, beside the
    # struct it describes. It describes the WIRE, so a model-only field is
    # absent and a constant is present.
    layout_const = esc(Symbol("_HEADER_LAYOUT_", name))
    names_expr  = :(Symbol[$([QuoteNode(f.name) for f in on_wire]...)])
    types_expr  = :(Type[$((esc(f.type) for f in on_wire)...)])
    widths_expr = :(Int[$((width_of(f) for f in on_wire)...)])
    bases_expr  = :(Union{Symbol, Nothing}[$([f.base === nothing ? :nothing : QuoteNode(f.base)
                                              for f in on_wire]...)])
    constants_expr = :(Any[$((f.kind === :constant ? esc(f.value) : :nothing
                              for f in on_wire)...)])

    # A field with a default earns the header a keyword constructor. A field
    # without one stays a required keyword, so a header with two defaults out of
    # ten is still built by naming the other eight. A model-only field always
    # has a default, so it never forces a caller to name it.
    has_default = any(f -> f.default !== nothing, stored)
    kw_args = [f.default === nothing ? esc(f.name) :
               Expr(:kw, esc(f.name), esc(f.default)) for f in stored]
    kw_ctor = has_default ?
        Expr(:(=), Expr(:call, esc(name), Expr(:parameters, kw_args...)),
             Expr(:call, esc(name), [esc(f.name) for f in stored]...)) :
        nothing

    # Method definitions must add to PacketModule's generic functions, NOT
    # create fresh shadows in the caller's module. `function foo(…)` at top
    # level always defines the name in the module the code expands INTO —
    # so we qualify with the enclosing module (`M` bound above).
    return quote
        # `Base.@__doc__` is what lets a docstring sit in front of `@header`.
        # Without it Julia refuses to document a macro that expands to a block.
        Base.@__doc__ struct $(esc(name)) <: $(M).Fields
            $(struct_fields...)
        end
        $(M).chunk_length(::$(esc(name))) = $(M).Bits($total_expr)
        $(M).chunk_length(::Type{$(esc(name))}) = $(M).Bits($total_expr)
        function $(M).serialize(io::$(M).BitWriter, h::$(esc(name)))
            $(write_calls...)
            return io
        end
        function $(M).deserialize(::Type{$(esc(name))}, io::$(M).BitReader)
            $(read_body...)
            return $ctor_call
        end
        const $(layout_const) = $(M).build_header_layout(
            $(QuoteNode(name)), $names_expr, $types_expr, $widths_expr, $bases_expr,
            $constants_expr)
        $(M).header_layout(::Type{$(esc(name))}) = $(layout_const)
        $(kw_ctor === nothing ? :() : kw_ctor)
        # A quality accessor covering headers built by hand vs deserialised —
        # Phase 4 fills the misrepresented bit here.
        $(M).quality(::$(esc(name))) = $(M).Q_COMPLETE
        function Base.show(io::IO, h::$(esc(name)))
            print(io, $(string(name)), "(")
            fs = fieldnames(typeof(h))
            for (i, f) in enumerate(fs)
                i > 1 && print(io, ", ")
                print(io, f, "=", getfield(h, f))
            end
            print(io, ")")
        end
    end
end

# ---------- serialise / deserialise entry points -----------------------------

"Serialise a header to a Vector{UInt8}, padded to whole bytes."
function to_bytes(h::Fields)
    w = BitWriter()
    serialize(w, h)
    # Ensure the byte vector is at least ceil(chunk_length/8) bytes.
    needed = (chunk_length(h).bits + 7) >> 3
    while Base.length(w.bytes) < needed
        push!(w.bytes, 0x00)
    end
    return w.bytes
end

"Deserialise a header from a Vector{UInt8}."
from_bytes(::Type{T}, bytes::Vector{UInt8}) where {T<:Fields} =
    deserialize(T, BitReader(bytes))

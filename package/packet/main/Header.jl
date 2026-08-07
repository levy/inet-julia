# ============================================================================
# `@header` — one declaration produces the struct AND its codec.
#
# In INET a `.msg` file generates the C++ struct and a HAND-WRITTEN `.cc`
# serializer must stay in sync; they can drift, which is part of why
# `improperlyRepresented` exists. Here a single macro emits the immutable
# struct, `chunk_length`, `serialize`, and `deserialize` from the same
# declaration, so drift is impossible.
#
# Syntax:
#
#     @header Ipv4Header begin
#         version      :: UInt8  | 4
#         ihl          :: UInt8  | 4
#         dscp         :: UInt8  | 6
#         ecn          :: UInt8  | 2
#         total_length :: UInt16                # width omitted → field_width(T)
#         src_address  :: Ipv4Address           # a field type, not an integer
#         checksum     :: UInt16 | 16 | hex     # how a reader sees it
#         sfd          :: UInt8  | 8 = 0xD5     # a default, for a constant field
#     end
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
# The four generic functions of `FieldTypes.jl` are what lets a field be a
# `MacAddress`: the macro asks the type how wide it is, which bits it becomes,
# and which value those bits come back as.
#
# Headers whose codec cannot be described declaratively (variable-length tails)
# just define `serialize`/`deserialize` directly — dispatch wins, there is
# nothing to register.
# ============================================================================

# Fallback (overridable by hand for variable-length headers):
function serialize end
function deserialize end

const _FIELD_BASES = (:bin, :dec, :hex, :mac, :ipv4, :enum)

# Parse one field declaration. `width` and `base` are `nothing` when the
# declaration leaves them to the field's type; `default` is `nothing` when the
# field has none.
function _parse_field(expr)
    default = nothing
    if Meta.isexpr(expr, :(=)) && Base.length(expr.args) == 2
        expr, default = expr.args[1], expr.args[2]
    end
    base = nothing
    # `name :: T | w | base` parses as `((name::T | w) | base)`, so peel the
    # outer pipe first and keep it only when it carries a display base.
    if Meta.isexpr(expr, :call) && expr.args[1] === :| && Base.length(expr.args) == 3 &&
       expr.args[3] isa Symbol
        expr.args[3] in _FIELD_BASES ||
            error("@header: unknown display base `$(expr.args[3])`; expected one of $(_FIELD_BASES)")
        base = expr.args[3]
        expr = expr.args[2]
    end
    if Meta.isexpr(expr, :call) && expr.args[1] === :| && Base.length(expr.args) == 3
        decl, width = expr.args[2], expr.args[3]
        Meta.isexpr(decl, :(::)) && Base.length(decl.args) == 2 ||
            error("@header: expected `name :: Type | width`, got $expr")
        return (name = decl.args[1]::Symbol, type = decl.args[2],
                width = Int(width), base = base, default = default)
    elseif Meta.isexpr(expr, :(::)) && Base.length(expr.args) == 2
        return (name = expr.args[1]::Symbol, type = expr.args[2],
                width = nothing, base = base, default = default)
    else
        error("@header: unrecognised field declaration $expr")
    end
end

macro header(name, block)
    Meta.isexpr(block, :block) ||
        error("@header $name: expected a `begin … end` block")

    fields = NamedTuple[]
    for line in block.args
        line isa LineNumberNode && continue
        push!(fields, _parse_field(line))
    end
    isempty(fields) && error("@header $name: no fields")

    struct_fields = [Expr(:(::), esc(f.name), esc(f.type)) for f in fields]

    # Widths — a missing width is the type's own, which is `sizeof(T) * 8` for
    # an integer and 48 for a `MacAddress`.
    M = @__MODULE__
    width_exprs = [f.width === nothing ? :($(M).field_width($(esc(f.type)))) : f.width
                   for f in fields]
    total_expr  = Expr(:call, :+, width_exprs...)

    # serialize: write each field. `M.write_bits!` so the generated code
    # doesn't rely on the caller having imported `write_bits!`.
    write_calls = Expr[]
    for (f, w) in zip(fields, width_exprs)
        push!(write_calls,
              :($(M).write_bits!(io, $(M).field_encode($(esc(f.type)), h.$(f.name)), $(w))))
    end

    # deserialize: read each field, then call the ctor.
    read_body = Expr[]
    ctor_args = []
    for (f, w) in zip(fields, width_exprs)
        tmp = Symbol("_", f.name)
        push!(read_body,
              :($(tmp) = $(M).field_decode($(esc(f.type)), $(M).read_bits!(io, $(w)))))
        push!(ctor_args, tmp)
    end
    ctor_call = Expr(:call, esc(name), ctor_args...)

    # The layout descriptor, built once at declaration time and returned by a
    # method on the type. The const lives in the caller's module, beside the
    # struct it describes.
    layout_const = esc(Symbol("_HEADER_LAYOUT_", name))
    names_expr  = :(Symbol[$([QuoteNode(f.name) for f in fields]...)])
    types_expr  = :(Type[$([esc(f.type) for f in fields]...)])
    widths_expr = :(Int[$(width_exprs...)])
    bases_expr  = :(Union{Symbol, Nothing}[$([f.base === nothing ? :nothing : QuoteNode(f.base)
                                              for f in fields]...)])

    # A field with a default earns the header a keyword constructor. A field
    # without one stays a required keyword, so a header with two defaults out of
    # ten is still built by naming the other eight.
    has_default = any(f -> f.default !== nothing, fields)
    kw_args = [f.default === nothing ? esc(f.name) :
               Expr(:kw, esc(f.name), esc(f.default)) for f in fields]
    kw_ctor = has_default ?
        Expr(:(=), Expr(:call, esc(name), Expr(:parameters, kw_args...)),
             Expr(:call, esc(name), [esc(f.name) for f in fields]...)) :
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
            $(QuoteNode(name)), $names_expr, $types_expr, $widths_expr, $bases_expr)
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

# ============================================================================
# `@header` — one declaration produces the struct AND its codec.
#
# In INET a `.msg` file generates the C++ struct and a HAND-WRITTEN `.cc`
# serializer must stay in sync; they can drift, which is part of why
# `improperlyRepresented` exists. Here a single macro emits the immutable
# struct, `chunk_length`, `serialize`, and `deserialize` from the same
# declaration, so drift is impossible.
#
# Syntax (plan §5 Question 1, form 1 — decide in phase 3 against real headers):
#
#     @header Ipv4Header begin
#         version      :: UInt8  | 4
#         ihl          :: UInt8  | 4
#         dscp         :: UInt8  | 6
#         ecn          :: UInt8  | 2
#         total_length :: UInt16               # width omitted → sizeof(T)*8
#     end
#
# What's generated:
#   struct Ipv4Header <: Fields; version::UInt8; ihl::UInt8; ... end
#   chunk_length(::Ipv4Header) = Bits(<sum-of-widths>)
#   serialize(w::BitWriter, h::Ipv4Header) — writes each field's low bits
#   deserialize(::Type{Ipv4Header}, r::BitReader) — reads and constructs
#
# Headers whose codec cannot be described declaratively (TCP options,
# variable-length tails) just define `serialize`/`deserialize` directly —
# dispatch wins, there is nothing to register (plan §5, bullet 2).
# ============================================================================

# Fallback (overridable by hand for variable-length headers):
function serialize end
function deserialize end

# Parse one field declaration into (name::Symbol, type::Symbol, width::Union{Int,Nothing}).
function _parse_field(expr)
    if Meta.isexpr(expr, :call) && expr.args[1] === :| && Base.length(expr.args) == 3
        decl, width = expr.args[2], expr.args[3]
        Meta.isexpr(decl, :(::)) && Base.length(decl.args) == 2 ||
            error("@header: expected `name :: Type | width`, got $expr")
        return (decl.args[1]::Symbol, decl.args[2], Int(width))
    elseif Meta.isexpr(expr, :(::)) && Base.length(expr.args) == 2
        return (expr.args[1]::Symbol, expr.args[2], nothing)
    else
        error("@header: unrecognised field declaration $expr")
    end
end

macro header(name, block)
    Meta.isexpr(block, :block) ||
        error("@header $name: expected a `begin … end` block")

    fields = Tuple{Symbol,Any,Union{Int,Nothing}}[]
    for line in block.args
        line isa LineNumberNode && continue
        push!(fields, _parse_field(line))
    end
    isempty(fields) && error("@header $name: no fields")

    struct_fields = [Expr(:(::), esc(f[1]), esc(f[2])) for f in fields]

    # Widths — nothing → sizeof(T)*8, static.
    width_exprs = [f[3] === nothing ? :(sizeof($(esc(f[2]))) * 8) : f[3] for f in fields]
    total_expr  = Expr(:call, :+, width_exprs...)

    M = @__MODULE__
    # serialize: write each field. `M.write_bits!` so the generated code
    # doesn't rely on the caller having imported `write_bits!`.
    write_calls = Expr[]
    for (f, w) in zip(fields, width_exprs)
        push!(write_calls, :($(M).write_bits!(io, h.$(f[1]), $(w))))
    end

    # deserialize: read each field, then call the ctor.
    read_body = Expr[]
    ctor_args = []
    for (f, w) in zip(fields, width_exprs)
        tmp = Symbol("_", f[1])
        push!(read_body, :($(tmp) = $(esc(f[2]))($(M).read_bits!(io, $(w)))))
        push!(ctor_args, tmp)
    end
    ctor_call = Expr(:call, esc(name), ctor_args...)

    # Method definitions must add to PacketModule's generic functions, NOT
    # create fresh shadows in the caller's module. `function foo(…)` at top
    # level always defines the name in the module the code expands INTO —
    # so we qualify with the enclosing module (`M` bound above).
    return quote
        struct $(esc(name)) <: $(M).Fields
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

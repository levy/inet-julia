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
const _FIELD_CLAUSES = (:constant, :derive, :check, :length)

# One field of a declaration, after the parse.
#
#   kind      `:wire` (struct and wire), `:model` (struct only),
#             `:constant` (wire only)
#   width     an expression, or `nothing` for the field type's own width
#   base      an expression for the display base, or `nothing`
#   order     `:be` or `:le`
#   default   an expression, or `nothing`
#   value     the constant a `:constant` field writes
#   derive    an expression the writer computes instead of reading the struct
#   check     an expression that must hold, or `nothing`
#   extent    for a byte field: `:rest`, or an expression giving its length;
#             for a `:pad` entry: the boundary it aligns to
#   fill      the byte a `:pad` entry writes
#
# `kind` also takes `:bytes` — a `Vector{UInt8}` whose length the data decides —
# and `:pad`, which is a wire-only entry with no name of its own.
struct FieldDecl
    name::Symbol
    type::Any
    kind::Symbol
    width::Any
    base::Union{Symbol, Nothing}
    order::Symbol
    default::Any
    value::Any
    derive::Any
    check::Any
    extent::Any
    fill::Any
end

"Whether the entry's width depends on the instance rather than the declaration."
is_variable(f::FieldDecl) = f.kind === :bytes || f.kind === :pad

"What a failed check says. The expression is the message: it is what the
declaration wrote, and a reader of the error wants to see exactly that."
function _check_message(header, field, expr, what)
    where_ = field === nothing ? "" : ".$(field)"
    return "$(header)$(where_): $(what) — check failed: $(string(expr))"
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
    derive = nothing
    check = nothing
    extent = nothing
    kind = :wire
    for segment in segments
        if segment isa Symbol
            if segment in _FIELD_BASES
                base = segment
            elseif segment in _FIELD_ORDERS
                order = segment
            elseif segment === :rest
                kind = :bytes
                extent = :rest
            else
                error("@header $name: unknown segment `$segment`; a display base is one of " *
                      "$(_FIELD_BASES), a byte order is one of $(_FIELD_ORDERS), " *
                      "and `rest` takes the remainder of the window")
            end
        elseif Meta.isexpr(segment, :call) && segment.args[1] in _FIELD_CLAUSES
            clause = segment.args[1]
            Base.length(segment.args) == 2 ||
                error("@header $name: `$clause` takes one argument")
            argument = segment.args[2]
            if clause === :constant
                kind = :constant
                value = argument
            elseif clause === :derive
                derive = argument
            elseif clause === :length
                kind = :bytes
                extent = argument
            else
                check = argument
            end
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
    kind === :constant && derive !== nothing &&
        error("@header $name: a `constant` field already states its value, so it cannot `derive` one")
    kind === :model && derive !== nothing &&
        error("@header $name: a model-only field is not on the wire, so `derive` has nothing to write")
    if kind === :bytes
        width === nothing ||
            error("@header $name: a byte field takes its width from `length` or `rest`, not from `| n`")
        derive === nothing ||
            error("@header $name: a byte field is its own value, so `derive` has nothing to compute")
    end

    return FieldDecl(name, type, kind, width, base, order, default, value,
                     derive, check, extent, nothing)
end

"Parse a `@pad to <boundary> fill <byte>` line into a wire-only entry."
function _parse_pad(header, arguments)
    boundary = nothing
    fill = :(0x00)
    index = 1
    while index <= Base.length(arguments)
        keyword = arguments[index]
        keyword isa Symbol && keyword in (:to, :fill) ||
            error("@header $header: `@pad` reads `to <boundary>` and `fill <byte>`, got $keyword")
        index + 1 <= Base.length(arguments) ||
            error("@header $header: `@pad $keyword` needs a value")
        keyword === :to ? (boundary = arguments[index + 1]) : (fill = arguments[index + 1])
        index += 2
    end
    boundary === nothing &&
        error("@header $header: `@pad` needs `to <boundary>`")
    return FieldDecl(:pad, :UInt8, :pad, nothing, nothing, :be, nothing, nothing,
                     nothing, nothing, boundary, fill)
end

macro header(name, block)
    Meta.isexpr(block, :block) ||
        error("@header $name: expected a `begin … end` block")

    fields = FieldDecl[]
    header_checks = Any[]
    for line in block.args
        line isa LineNumberNode && continue
        if Meta.isexpr(line, :macrocall) && line.args[1] === Symbol("@check")
            arguments = filter(a -> !(a isa LineNumberNode), line.args[2:end])
            Base.length(arguments) == 1 ||
                error("@header $name: `@check` takes one expression")
            push!(header_checks, arguments[1])
            continue
        end
        if Meta.isexpr(line, :macrocall) && line.args[1] === Symbol("@pad")
            push!(fields, _parse_pad(name, filter(a -> !(a isa LineNumberNode),
                                                  line.args[2:end])))
            continue
        end
        push!(fields, _parse_field(line))
    end
    isempty(fields) && error("@header $name: no fields")

    # The struct holds what the model has: the wire fields, the byte fields and
    # the model-only fields, in declaration order. The wire holds what the
    # format has: those, plus the constants and the padding.
    stored = filter(f -> f.kind !== :constant && f.kind !== :pad, fields)
    isempty(stored) && error("@header $name: every field is `constant`, so the struct is empty")
    on_wire = filter(f -> f.kind !== :model, fields)

    # A `rest` field eats what is left, so nothing can follow it.
    for (index, f) in enumerate(fields)
        f.kind === :bytes && f.extent === :rest && index != Base.length(fields) &&
            error("@header $name.$(f.name): `rest` takes the whole remainder, " *
                  "so it must be the last line")
    end
    fixed_length = !any(is_variable, on_wire)

    struct_fields = [Expr(:(::), esc(f.name), esc(f.type)) for f in stored]

    # Widths — a missing width is the type's own, which is `sizeof(T) * 8` for
    # an integer and 48 for a `MacAddress`.
    M = @__MODULE__
    width_of(f) = f.width === nothing ? :($(M).field_width($(esc(f.type)))) : esc(f.width)
    fixed_entries = filter(f -> !is_variable(f), on_wire)
    minimum_expr = isempty(fixed_entries) ? 0 :
                   Expr(:call, :+, (width_of(f) for f in fixed_entries)...)
    total_expr = minimum_expr

    # Both codecs bind every field as a local of its own name, so a `derive` or
    # a `check` reads `ihl` rather than `h.ihl`. The header itself is `h`, and
    # that name is ESCAPED into the caller's scope: a clause is the caller's
    # code, so a hygienic `h` would be invisible to it. A header therefore
    # cannot have a field named `h`.
    header_var = esc(:h)
    bind_locals = [:($(esc(f.name)) = $(header_var).$(f.name)) for f in stored]
    constant_locals = [:($(esc(f.name)) = $(esc(f.value)))
                       for f in on_wire if f.kind === :constant]

    # A check that fails on WRITE is a bug in the model, so it throws. The same
    # check on READ is a malformed packet, so it marks — see below.
    checks = Any[(f.name, f.check) for f in fields if f.check !== nothing]
    append!(checks, ((nothing, c) for c in header_checks))
    write_checks = [:($(esc(expr)) ||
                      error($(_check_message(name, field, expr, "refusing to serialize"))))
                    for (field, expr) in checks]

    # The cursor. `offset` is what this header has written or read so far, and
    # `remaining` is what its window has left. Both are re-bound before every
    # entry, because a clause reads them where it sits, not where the codec
    # started. Both are escaped, for the same reason `h` is.
    offset_var = esc(:offset)
    remaining_var = esc(:remaining)
    start_var = gensym(:start)
    read_cursor = quote
        $(offset_var) = $(M).Bits(io.bit_pos - $(start_var))
        $(remaining_var) = $(M).Bits(io.total - io.bit_pos)
    end

    # serialize walks the entries TWICE. The first walk is arithmetic: it binds
    # `offset` at each entry and computes the derived values and the padding
    # widths there, without writing anything. The second walk writes.
    #
    # Two walks and not one, because a check must be able to refuse before any
    # bits reach the caller's writer, and a derive must see the offset at its
    # own position — `derive(UInt8(bytes(offset)))` is the position of THAT
    # field, not of the header.
    pad_widths = Dict{Int, Symbol}()
    plan_steps = Expr[]
    push!(plan_steps, :($(start_var) = 0))
    for (index, f) in enumerate(on_wire)
        push!(plan_steps, :($(offset_var) = $(M).Bits($(start_var))))
        f.derive === nothing ||
            push!(plan_steps, :($(esc(f.name)) = convert($(esc(f.type)), $(esc(f.derive)))))
        if f.kind === :bytes
            push!(plan_steps, :($(start_var) += 8 * Base.length($(esc(f.name)))))
        elseif f.kind === :pad
            local_width = gensym(:pad)
            pad_widths[index] = local_width
            push!(plan_steps, :($(local_width) = $(M).pad_bits($(start_var), $(esc(f.extent)))))
            push!(plan_steps, :($(start_var) += $(local_width)))
        else
            push!(plan_steps, :($(start_var) += $(width_of(f))))
        end
    end

    write_calls = Expr[]
    for (index, f) in enumerate(on_wire)
        if f.kind === :bytes
            push!(write_calls, :($(M).write_bytes!(io, $(esc(f.name)))))
        elseif f.kind === :pad
            push!(write_calls,
                  :($(M).write_byte_repeatedly!(io, UInt8($(esc(f.fill))),
                                                $(pad_widths[index]) >> 3)))
        else
            push!(write_calls,
                  :($(M).field_write(io, $(esc(f.type)), $(esc(f.name)),
                                     $(width_of(f)), $(QuoteNode(f.order)))))
        end
    end

    # deserialize: read each field, then call the ctor. A constant is not in the
    # struct, but its local still takes the value that ARRIVED, so a `check` on
    # a constant tests what the sender wrote. A model-only field takes its
    # default, because no bits carried it.
    read_body = Expr[]
    for f in on_wire
        push!(read_body, read_cursor)
        if f.kind === :bytes
            count = f.extent === :rest ? :($(M).bits($(remaining_var)) >> 3) :
                    :($(M).bits(convert($(M).BitLength, $(esc(f.extent)))) >> 3)
            push!(read_body, :($(esc(f.name)) = $(M).read_bytes!(io, $count)))
        elseif f.kind === :pad
            push!(read_body,
                  :($(M).skip_bits!(io,
                      $(M).pad_bits($(M).bits($(offset_var)), $(esc(f.extent))))))
        else
            call = :($(M).field_read(io, $(esc(f.type)), $(width_of(f)), $(QuoteNode(f.order))))
            push!(read_body, :($(esc(f.name)) = $call))
        end
    end
    ctor_args = [f.kind === :model ? esc(f.default) : esc(f.name) for f in stored]
    ctor_call = Expr(:call, esc(name), ctor_args...)

    # `chunk_length` of an INSTANCE walks the entries: a fixed one contributes
    # its declared width, a byte field the length of its vector, and a pad
    # whatever takes the running total to its boundary. For a header with no
    # variable entry the walk folds to the same constant the type answers.
    length_steps = Expr[]
    for f in on_wire
        if f.kind === :bytes
            push!(length_steps, :(total += 8 * Base.length($(header_var).$(f.name))))
        elseif f.kind === :pad
            push!(length_steps, :(total += $(M).pad_bits(total, $(esc(f.extent)))))
        else
            push!(length_steps, :(total += $(width_of(f))))
        end
    end

    # A failed check on read gives the header back, marked incorrect. A packet
    # that arrived malformed is data, not a program error: the caller decides,
    # through the `peek` gate, whether to accept it.
    read_checks = [:($(esc(expr)) || (correct = false)) for (_, expr) in checks]
    has_checks = !isempty(checks)

    # The layout descriptor, built once at declaration time and returned by a
    # method on the type. The const lives in the caller's module, beside the
    # struct it describes. It describes the WIRE, so a model-only field is
    # absent and a constant is present.
    #
    # A variable entry has no width until there is an instance, so the TYPE
    # layout stops at the first one. `header_layout(h)` gives the whole thing.
    described = Base.something(findfirst(is_variable, on_wire),
                               Base.length(on_wire) + 1) - 1
    fixed_prefix = on_wire[1:described]
    layout_const = esc(Symbol("_HEADER_LAYOUT_", name))
    names_expr  = :(Symbol[$([QuoteNode(f.name) for f in fixed_prefix]...)])
    types_expr  = :(Type[$((esc(f.type) for f in fixed_prefix)...)])
    widths_expr = :(Int[$((width_of(f) for f in fixed_prefix)...)])
    bases_expr  = :(Union{Symbol, Nothing}[$([f.base === nothing ? :nothing : QuoteNode(f.base)
                                              for f in fixed_prefix]...)])
    constants_expr = :(Any[$((f.kind === :constant ? esc(f.value) : :nothing
                              for f in fixed_prefix)...)])

    # The instance layout adds the variable entries, with the widths this
    # header actually has. It is what a view of a real packet reads.
    instance_steps = Expr[]
    for f in on_wire[(described + 1):end]
        width = f.kind === :bytes ? :(8 * Base.length($(header_var).$(f.name))) :
                f.kind === :pad ? :($(M).pad_bits(at, $(esc(f.extent)))) :
                width_of(f)
        value = f.kind === :constant ? esc(f.value) :
                f.kind === :pad ? :(UInt8($(esc(f.fill)))) : :nothing
        push!(instance_steps, quote
            let width = $width
                push!(specs, $(M).FieldSpec($(QuoteNode(f.name)), $(esc(f.type)), at, width,
                                            $(M).field_base($(esc(f.type)), width), $value))
                at += width
            end
        end)
    end

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
        function $(M).chunk_length($(header_var)::$(esc(name)))
            total = 0
            $(length_steps...)
            return $(M).Bits(total)
        end
        $(M).minimum_chunk_length(::Type{$(esc(name))}) = $(M).Bits($minimum_expr)
        $(M).is_fixed_length(::Type{$(esc(name))}) = $(fixed_length)
        # A variable-length header has no length until there is an instance, so
        # the type-level method says which question to ask instead.
        $(if fixed_length
              :($(M).chunk_length(::Type{$(esc(name))}) = $(M).Bits($total_expr))
          else
              :($(M).chunk_length(::Type{$(esc(name))}) =
                    error($(string("chunk_length(", name, "): the length depends on the ",
                                   "instance; ask minimum_chunk_length, or chunk_length of a ",
                                   "header you have"))))
          end)
        function $(M).serialize(io::$(M).BitWriter, $(header_var)::$(esc(name)))
            $(bind_locals...)
            $(constant_locals...)
            $(plan_steps...)
            $(write_checks...)
            $(write_calls...)
            return io
        end
        function $(M).deserialize(::Type{$(esc(name))}, io::$(M).BitReader)
            $(start_var) = io.bit_pos
            $(read_body...)
            $(header_var) = $ctor_call
            $(if has_checks
                  quote
                      correct = true
                      $(read_checks...)
                      correct || return $(M).mark_incorrect($(header_var))
                  end
              else
                  :()
              end)
            return $(header_var)
        end
        const $(layout_const) = $(M).build_header_layout(
            $(QuoteNode(name)), $names_expr, $types_expr, $widths_expr, $bases_expr,
            $constants_expr)
        $(M).header_layout(::Type{$(esc(name))}) = $(layout_const)
        $(if fixed_length
              :()
          else
              quote
                  function $(M).header_layout($(header_var)::$(esc(name)))
                      specs = copy($(layout_const).fields)
                      at = $(M).bits($(layout_const).length)
                      $(instance_steps...)
                      return $(M).HeaderLayout($(QuoteNode(name)), $(M).Bits(at), specs)
                  end
              end
          end)
        $(kw_ctor === nothing ? :() : kw_ctor)
        # A quality accessor covering headers built by hand vs deserialised —
        # Phase 4 fills the misrepresented bit here.
        $(M).quality(::$(esc(name))) = $(M).Q_COMPLETE
        # Field-wise equality. Julia's default `==` on an immutable struct is
        # `===` once a field is not `isbits`, so a header with a byte field
        # would never equal an identical one read back off the wire.
        function Base.:(==)(a::$(esc(name)), b::$(esc(name)))
            for field in fieldnames($(esc(name)))
                getfield(a, field) == getfield(b, field) || return false
            end
            return true
        end
        function Base.hash(value::$(esc(name)), seed::UInt)
            for field in fieldnames($(esc(name)))
                seed = hash(getfield(value, field), seed)
            end
            return hash($(QuoteNode(name)), seed)
        end
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

# ============================================================================
# `@header` — the two things a type cannot hold.
#
# A wire format is an ordinary struct, and `HeaderCodec.jl` reads it. So this
# macro emits **no codec**. It emits the same struct a hand-written declaration
# would, plus what the field types have no room for:
#
#   a default      what the standard fixes, so a call site states only what a
#                  packet decides
#   `derive`       a value the writer computes from the header
#   `check`        a value that must hold, or the header is not what it claims
#
#     @header Ipv4Header begin
#         version      :: U4 = 4
#             check(version == 4)
#         ihl          :: U4 = 5
#             derive(cld(measure_header(h), 32))
#         total_length :: U16
#         source       :: Ipv4Address
#         @check ihl >= 5
#     end
#
# A clause sits on its own line and applies to the field ABOVE it. Julia will
# not parse `version :: U4 = 4  check(…)` — two expressions side by side on one
# line is a syntax error — and a clause of any length wraps better on a line of
# its own anyway. `@check` on its own line spans fields instead.
#
# A header written by hand and a header written through the macro are the same
# type with the same methods, so a format may start as a bare struct and grow a
# check later without any caller noticing.
#
# Inside a clause, every field is bound by its own name and the header is `h`.
# Both names are ESCAPED into the caller's scope, because a clause is the
# caller's code — so a header cannot have a field called `h`.
#
# `derive` computes on write and keeps what arrived on read, so a foreign
# sender's disagreement stays visible. `check` marks on read and throws on
# write: a packet that arrived malformed is data, and a header the model built
# wrong is a bug.
#
# A value the header cannot see — a length that counts the payload, a checksum
# over a pseudo-header — has no derive. The model sets it. That is what INET
# does, and it is what lets a capture round-trip byte for byte.
# ============================================================================

const HEADER_CLAUSES = (:derive, :check, :length, :count, :until)

# One field of a declaration, after the parse.
struct HeaderField
    name::Symbol
    type::Any
    default::Any        # an expression, or `nothing` when the field is required
    derive::Any         # an expression, or `nothing`
    check::Any          # an expression, or `nothing`
    extent::Any         # how long an `Octets` field is this time, or `nothing`
end

"""
    derive_field(::Type{H}, ::Val{NAME}, h)

What the writer puts in the `NAME` field of `h`. The fallback is the field
itself, so a header with no `derive` clause needs no method.
"""
derive_field(::Type{H}, ::Val{NAME}, h) where {H, NAME} = getfield(h, NAME)

"""
    check_field(::Type{H}, ::Val{NAME}, h)::Bool

Whether the `NAME` field of `h` holds what it must. The fallback is `true`.
`Val(:header)` is the name a `@check` line across fields takes.
"""
check_field(::Type{H}, ::Val{NAME}, h) where {H, NAME} = true

"""
    list_derived(::Type{H})::Tuple

The names of the fields of `H` that a `derive` clause computes.
"""
list_derived(::Type{<:Fields}) = ()

"""
    list_checked(::Type{H})::Tuple

The names a `check` clause guards, plus `:header` when a `@check` line spans
fields.
"""
list_checked(::Type{<:Fields}) = ()

"Parse a `name :: Type` line, with its default when it has one."
function parse_header_field(line)
    default = nothing
    if Meta.isexpr(line, :(=)) && Base.length(line.args) == 2
        line, default = line.args[1], line.args[2]
    end
    Meta.isexpr(line, :(::)) && Base.length(line.args) == 2 ||
        error("@header: expected `name :: Type`, got $line")
    return HeaderField(line.args[1]::Symbol, line.args[2], default, nothing, nothing, nothing)
end

"Whether the line is a `derive(…)` or a `check(…)` for the field above it."
is_header_clause(line) =
    Meta.isexpr(line, :call) && Base.length(line.args) == 2 && line.args[1] in HEADER_CLAUSES

"The field with the clause attached."
function attach_clause(field::HeaderField, clause)
    name = clause.args[1]
    argument = clause.args[2]
    if name === :derive
        field.derive === nothing ||
            error("@header $(field.name): two `derive` clauses")
        return HeaderField(field.name, field.type, field.default, argument,
                           field.check, field.extent)
    elseif name === :until
        field.extent === nothing ||
            error("@header $(field.name): two `until` clauses")
        return HeaderField(field.name, field.type, field.default, field.derive,
                           field.check, (:until, argument))
    elseif name === :length || name === :count
        field.extent === nothing ||
            error("@header $(field.name): two `length` or `count` clauses")
        # A `count` is a number of elements and a `length` is a number of bits;
        # `measure_read` wants bits either way, so a count is multiplied by the
        # element's width where the method is emitted.
        return HeaderField(field.name, field.type, field.default, field.derive,
                           field.check, (name, argument))
    end
    field.check === nothing ||
        error("@header $(field.name): two `check` clauses")
    return HeaderField(field.name, field.type, field.default, field.derive,
                       argument, field.extent)
end

macro header(declaration, block)
    Meta.isexpr(block, :block) ||
        error("@header $declaration: expected a `begin … end` block")

    # `@header Member <: Family` puts the member under its family, which is how
    # an option family and a variant name their members. Without one a header
    # sits directly under `Fields`.
    name, supertype = declaration, nothing
    if Meta.isexpr(declaration, :(<:)) && Base.length(declaration.args) == 2
        name, supertype = declaration.args[1], declaration.args[2]
    end

    fields = HeaderField[]
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
        if is_header_clause(line)
            isempty(fields) &&
                error("@header $name: `$(line.args[1])` has no field above it")
            fields[end] = attach_clause(fields[end], line)
            continue
        end
        push!(fields, parse_header_field(line))
    end
    isempty(fields) && error("@header $name: no fields")

    M = @__MODULE__
    header_var = esc(:h)
    struct_fields = [Expr(:(::), esc(f.name), esc(f.type)) for f in fields]

    # Every field is bound by its own name, so a clause reads `ihl` and not
    # `h.ihl`. `Base.getfield` and not `.`, because a header may have a field
    # whose name shadows a function the clause calls.
    bindings = [:($(esc(f.name)) =
                    $(M).unwrap_field(Base.getfield($(header_var), $(QuoteNode(f.name)))))
                for f in fields]

    # A `length` clause runs while the header is still being read, so its
    # bindings come from what the reader has met so far rather than from `h`.
    # It may only name a field ABOVE it — nothing below has arrived yet, and a
    # clause that names one gets an error at expansion rather than at run time.
    read_bindings_above(index) =
        [:($(esc(f.name)) = sofar[$(QuoteNode(f.name))]) for f in fields[1:(index - 1)]]

    # Every header gets a keyword constructor. A field with a default may be
    # omitted; a field without one stays a required keyword, so a header with
    # two defaults out of ten is still built by naming the other eight.
    #
    # A `Pad` or a `Constant` field is a singleton the type fully describes, so
    # it defaults to itself and a caller never names it. The macro tells by the
    # name in the declaration, which is the only thing it can read.
    fills_itself(type) = Meta.isexpr(type, :curly) && type.args[1] in (:Pad, :Constant)
    default_of(f) = f.default !== nothing ? esc(f.default) :
                    fills_itself(f.type) ? :($(esc(f.type))()) : nothing
    keyword_arguments = [default_of(f) === nothing ? esc(f.name) :
                         Expr(:kw, esc(f.name), default_of(f)) for f in fields]
    keyword_constructor =
        Expr(:(=), Expr(:call, esc(name), Expr(:parameters, keyword_arguments...)),
             Expr(:call, esc(name), (esc(f.name) for f in fields)...))

    # One method per clause, keyed by the field name. A name the declaration
    # does not have therefore cannot be written: `derive` and `check` sit on
    # the field, so a typo is a field that does not exist.
    clause_methods = Expr[]
    derived = Symbol[]
    checked = Symbol[]
    # A default is also what a `Draft` starts a field at, so record each one.
    for f in fields
        f.default === nothing && continue
        push!(clause_methods, quote
            $(M).find_default(::Type{$(esc(name))}, ::Val{$(QuoteNode(f.name))}) =
                convert($(esc(f.type)), $(esc(f.default)))
        end)
    end
    for (index, f) in enumerate(fields)
        if f.derive !== nothing
            push!(derived, f.name)
            push!(clause_methods, quote
                function $(M).derive_field(::Type{$(esc(name))}, ::Val{$(QuoteNode(f.name))},
                                           $(header_var)::$(esc(name)))
                    $(bindings...)
                    return convert($(esc(f.type)), $(esc(f.derive)))
                end
            end)
        end
        if f.extent !== nothing
            read_bindings = read_bindings_above(index)
            kind, extent = f.extent
            # `length` gives bits directly; `count` gives elements, so it is
            # multiplied by the width of one.
            width = kind === :length ?
                    :($(M).bits(convert($(M).BitLength, $(esc(extent))))) :
                    kind === :count ?
                    :(Int($(esc(extent))) * $(M).measure_field(eltype($(esc(f.type))))) :
                    # `until` gives the offset the list ENDS at, so the width is
                    # what is left between here and there.
                    :($(M).bits(convert($(M).BitLength, $(esc(extent)))) - $(esc(:offset)))
            push!(clause_methods, quote
                function $(M).measure_read(::Type{$(esc(name))},
                                           ::Val{$(QuoteNode(f.name))}, ::Type,
                                           sofar::NamedTuple, $(esc(:offset))::Int,
                                           $(esc(:remaining))::Int)
                    $(read_bindings...)
                    return $(width)
                end
            end)
        end
        if f.check !== nothing
            push!(checked, f.name)
            push!(clause_methods, quote
                function $(M).check_field(::Type{$(esc(name))}, ::Val{$(QuoteNode(f.name))},
                                          $(header_var)::$(esc(name)))
                    $(bindings...)
                    return $(esc(f.check))
                end
            end)
        end
    end
    if !isempty(header_checks)
        push!(checked, :header)
        push!(clause_methods, quote
            function $(M).check_field(::Type{$(esc(name))}, ::Val{:header},
                                      $(header_var)::$(esc(name)))
                $(bindings...)
                return $(Expr(:&&, (esc(c) for c in header_checks)...))
            end
        end)
    end

    # A member of an option family selects itself by a code, and the code is
    # the constant its first field already states. Nothing else has to say it.
    first_is_constant = Meta.isexpr(fields[1].type, :curly) &&
                        fields[1].type.args[1] === :Constant &&
                        Base.length(fields[1].type.args) == 3
    option_code_method = supertype !== nothing && first_is_constant ?
        :($(M).option_code(::Type{$(esc(name))}) = $(esc(fields[1].type.args[3]))) :
        :()

    return quote
        # `Base.@__doc__` is what lets a docstring sit in front of `@header`.
        Base.@__doc__ struct $(esc(name)) <: $(supertype === nothing ?
                                                 :($(M).Fields) : esc(supertype))
            $(struct_fields...)
        end
        $(keyword_constructor)
        $(clause_methods...)
        $(option_code_method)
        $(M).list_derived(::Type{$(esc(name))}) = $(Expr(:tuple, QuoteNode.(derived)...))
        $(M).list_checked(::Type{$(esc(name))}) = $(Expr(:tuple, QuoteNode.(checked)...))
    end
end

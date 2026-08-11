# ============================================================================
# `Draft` — a header under construction, which is not a header.
#
# No field of a header is `Union{T, Nothing}`. A finished header is a value
# that is true about a packet, and a maybe on every field would cost the union
# tag, lose `isbits`, and be paid at every call site that reads it.
#
# A field is omitted, not set to nothing, and the declaration says which may be
# omitted. The fields a model fills in later — the lengths and the checksums —
# carry a default of zero, so they are omitted too.
#
# What is left is genuine incremental construction: code that assembles a
# header across several steps and must be able to ask whether a field has been
# set yet. That is this type.
#
#     draft = start_draft(Ipv4Header)
#     draft.source = "10.0.0.1"
#     is_set(draft, :protocol)      # false
#     ip = build_header(draft)      # errors, and names what is still unset
#
# A hole is therefore a state of the thing that BUILDS a header, never a state
# of a header. `build_header` is the one door between them, and nothing gets
# through it half-built.
#
# `Draft{H}` is derived generically from `fieldnames(H)`. No header declares
# one, and no header needs to.
# ============================================================================

"""
    find_default(::Type{H}, ::Val{NAME})

The default the declaration gives the `NAME` field, or `nothing` when it gives
none. `@header` defines a method for each field that has one; a header written
as a plain struct has none, so every field of its draft starts unset.
"""
find_default(::Type{H}, ::Val{NAME}) where {H, NAME} = nothing

"""
    Draft{H}

A mutable header under construction. Every field is set, or it is not, and
`build_header` refuses to make a header until each one is.
"""
mutable struct Draft{H <: Fields}
    values::Vector{Any}
end

"""
    start_draft(::Type{H})::Draft{H}

A draft of `H` with the declaration's defaults already filled in — those are
what the standard fixes, not what a builder still has to decide — and every
other field unset.
"""
function start_draft(::Type{H}) where {H <: Fields}
    values = Any[find_default(H, Val(name)) for name in header_fields(H)]
    return Draft{H}(values)
end

"The header type a draft builds."
header_type(::Draft{H}) where {H} = H

"""
    is_set(draft, name::Symbol)::Bool

Whether the field has a value yet. A field with a default is set from the
start, because the standard already decided it.
"""
function is_set(draft::Draft{H}, name::Symbol) where {H}
    index = find_field_index(H, name)
    return draft.values[index] !== nothing
end

"""
    list_unset(draft)::Vector{Symbol}

Every field still waiting for a value, in declaration order.
"""
list_unset(draft::Draft{H}) where {H} =
    [name for (index, name) in enumerate(header_fields(H))
     if draft.values[index] === nothing]

"The position of `name` in `H`, or an error naming what `H` does have."
function find_field_index(::Type{H}, name::Symbol) where {H <: Fields}
    index = findfirst(==(name), header_fields(H))
    index === nothing &&
        error("$(document_schema_name(H)) has no field `$(name)`; it has $(join(header_fields(H), ", "))")
    return index
end

"""
    set_field!(draft, name::Symbol, value)

Give a field its value, converted to the field's type. `draft.source = value`
is the same thing.
"""
function set_field!(draft::Draft{H}, name::Symbol, value) where {H}
    index = find_field_index(H, name)
    draft.values[index] = convert(fieldtype(H, index), value)
    return draft
end

"""
    unset_field!(draft, name::Symbol)

Take a field's value away again, so `is_set` says `false`. A draft is where a
hole is allowed, so putting one back is allowed too.
"""
function unset_field!(draft::Draft{H}, name::Symbol) where {H}
    draft.values[find_field_index(H, name)] = nothing
    return draft
end

function Base.getproperty(draft::Draft{H}, name::Symbol) where {H}
    name === :values && return getfield(draft, :values)
    index = find_field_index(H, name)
    value = getfield(draft, :values)[index]
    value === nothing &&
        error("$(document_schema_name(H)).$(name) is not set yet; ask `is_set` before reading it")
    return unwrap_field(value)
end

Base.setproperty!(draft::Draft{H}, name::Symbol, value) where {H} =
    (set_field!(draft, name, value); value)

Base.propertynames(::Draft{H}) where {H} = header_fields(H)

"""
    build_header(draft)::H

The header the draft describes. It refuses while any field is unset, and names
every one of them — a builder that forgot two fields wants to hear about both.
"""
function build_header(draft::Draft{H}) where {H <: Fields}
    unset = list_unset(draft)
    isempty(unset) ||
        error("build_header($(document_schema_name(H))): still unset — $(join(unset, ", "))")
    return H(getfield(draft, :values)...)
end

"""
    start_draft(h::Fields)::Draft

A draft that starts where an existing header is. This is how a builder edits a
header field by field and then makes a new one; `set_field` is the shorter way
when there is only one field to change.
"""
function start_draft(h::H) where {H <: Fields}
    return Draft{H}(Any[getfield(h, index) for index in 1:header_count(H)])
end

function Base.show(io::IO, draft::Draft{H}) where {H}
    print(io, "Draft{", document_schema_name(H), "}(")
    for (index, name) in enumerate(header_fields(H))
        index > 1 && print(io, ", ")
        value = getfield(draft, :values)[index]
        print(io, name, "=", value === nothing ? "?" : unwrap_field(value))
    end
    print(io, ")")
end

# ============================================================================
# What a header knows about itself, beyond its layout.
#
# `describe_layout` in `HeaderCodec.jl` answers where the fields lie. Three
# questions remain, and a view of a header needs all three:
#
#   find_declaration        where the declaration is, so a view can show it
#   describe_construction   the call that rebuilds an instance
#   describe_update         what one field update does to the bytes
#
# All three read `fieldnames`, `fieldtypes` and the clause methods `@header`
# emits. None of them is written per header, and none of them is a second
# description of anything: the declaration is quoted from its own file, and the
# construction and the update are computed from the instance they show.
#
# Design: plan/*/protocol-header-gallery.md.
# ============================================================================

# ---------- where a header is declared ---------------------------------------

"""
    find_declaration(::Type{H}) -> (; file, line) or nothing

Where `H` was declared. `@header` records its own source location, and a header
written as a plain struct records the line its `register_header` call is on.
`nothing` for a header that never registered.
"""
function find_declaration(::Type{H}) where {H <: Fields}
    site = get(DECLARATION_SITES, H, nothing)
    site === nothing && return nothing
    return (file = site[1], line = site[2])
end

"""
    declaration_path(::Type{H}) -> String or nothing

The file `H` is declared in, as a path that exists now.

A recorded path is the path of the machine that precompiled the package, so a
relocated checkout and a precompiled image both need the file found again. Every
wire format here sits either beside this file or in `protocol/`, so those two
places are tried before the recorded path is handed back as it stands.
"""
function declaration_path(::Type{H}) where {H <: Fields}
    site = find_declaration(H)
    site === nothing && return nothing
    isfile(site.file) && return site.file
    root = package_source_directory()
    root === nothing && return site.file
    name = basename(site.file)
    for candidate in (joinpath(root, "protocol", name), joinpath(root, name))
        isfile(candidate) && return candidate
    end
    return site.file
end

"""
    package_source_directory() -> String or nothing

Where this package's source is, now. `nothing` when the module was not loaded
as a package.

Not `pkgdir`: that one expects `src/Foo.jl` under the package root, and this
package's entry file sits in the root itself — which `Project.toml` says with
`entryfile`, and which `pkgdir` refuses.
"""
function package_source_directory()
    path = pathof(parentmodule(@__MODULE__))
    return path === nothing ? nothing : dirname(path)
end

# ---------- an instance to show ----------------------------------------------

"""
    example_header(::Type{H})::H

An instance of `H` worth showing: every field distinct, and the header
self-consistent.

`fill_asymmetric` gives the first half — a value per field that no neighbour
shares, which is what makes a bit grid readable and a round trip meaningful.
The second half is the encode and decode that follow it: a derived field then
holds what the writer computes, a checked field holds what its check allows, and
an optional field is present exactly when its clause says it is. What comes back
is a header that agrees with its own bytes.
"""
function example_header(::Type{H}) where {H <: Fields}
    header = fill_asymmetric(H)
    decoded = decode_header(H, encode_header(header))
    decoded isa MarkedFields && (decoded = decoded.header)
    return decoded
end

# ---------- how an instance is built -----------------------------------------

"""
    HeaderArgument(name, literal, text, reason)

One field of a header, as a caller meets it.

`literal` is the Julia expression that rebuilds the value and `text` is how a
reader wants to see it. `reason` says why the field is in the keyword call, or
why it is not:

  `:required`  no default — a caller must state it
  `:differs`   it has a default, and this value is not it
  `:default`   it has a default, and this value is it
  `:derived`   the writer computes it, so stating it would be noise
  `:fixed`     the type fully describes it — a `Constant` or a `Pad`
"""
struct HeaderArgument
    name::Symbol
    literal::String
    text::String
    reason::Symbol
end

"Whether the keyword call names this field."
is_named(argument::HeaderArgument) = argument.reason in (:required, :differs)

"""
    HeaderConstruction(type, call, arguments, keyword)

How one instance of a header is built: the call that rebuilds it, and every
field with the reason it is named or left out.

`keyword` says which call it is. `@header` emits a keyword constructor, so a
header it declared is built by naming the fields that matter. A header written
as a plain struct has only the positional constructor Julia gives every struct,
so it is built by stating every field in order — and then every field is
required, because a positional call has no default to fall back on.
"""
struct HeaderConstruction
    type::Type
    call::String
    arguments::Vector{HeaderArgument}
    keyword::Bool
end

"""
    has_keyword_constructor(::Type{H})::Bool

Whether `H` can be built by naming its fields. True for every header `@header`
declared, and false for one written as a plain struct.
"""
has_keyword_constructor(::Type{H}) where {H <: Fields} =
    hasmethod(H, Tuple{}, header_fields(H))

"The fields the call names, in declaration order."
list_named(c::HeaderConstruction) = [a for a in c.arguments if is_named(a)]

"The fields the call leaves to the declaration, in declaration order."
list_omitted(c::HeaderConstruction) = [a for a in c.arguments if !is_named(a)]

"""
    describe_construction(h::Fields)::HeaderConstruction

The keyword call that rebuilds `h`.

It names a field that has no default, and a field whose value is not its
default. It leaves out everything else, because the declaration already says it
— which is the whole point of the defaults, and is why a twenty-byte IPv4 header
is built by naming four fields.

A derived field is left out even when its value is not the default: the writer
computes it from the header, so a caller who states it is either repeating the
writer or contradicting it. The call therefore rebuilds a header that ENCODES
the same bytes, which is a stronger claim than field equality and the one the
library actually makes.
"""
function describe_construction(h::H) where {H <: Fields}
    keyword = has_keyword_constructor(H)
    derived = list_derived(H)
    arguments = HeaderArgument[]
    for index in 1:header_count(H)
        name = fieldname(H, index)
        type = fieldtype(H, index)
        value = getfield(h, index)
        default = find_default(H, Val(name))
        reason = !keyword                        ? :required :
                 type <: Constant || type <: Pad ? :fixed :
                 name in derived                 ? _derive_reason(h, name, default) :
                 default === nothing             ? :required :
                 value == default                ? :default : :differs
        push!(arguments, HeaderArgument(name, literal_field(value),
                                        format_field(value), reason))
    end
    return HeaderConstruction(H, _construction_call(H, arguments, keyword),
                              arguments, keyword)
end

# Whether a derived field can be left out of the call.
#
# Not every derive computes. IPv4's `ihl` counts the header's own width, so a
# caller never states it and the writer puts it back. IPv4's `header_checksum`
# derives to ITSELF unless the checksum mode says to compute one — RFC 791
# leaves the choice to the sender, and INET's default is `declared` — so the
# writer puts back exactly what it was given, and a call that left it out would
# emit a different datagram.
#
# The two are told apart by trying it: set the field to its default, and see
# whether the bytes still come out the same. That is the property the call
# claims, so it is the property to check.
function _derive_reason(h::H, name::Symbol, default) where {H <: Fields}
    default === nothing && return :differs
    try
        encode_header(set_field(h, name, default)) == encode_header(h) ?
            :derived : :differs
    catch
        # A default the header refuses is not a field to leave out.
        :differs
    end
end

# The call itself. One line while it fits, and one argument per line when it
# does not — a header with twelve keywords on one line is a line nobody reads.
function _construction_call(::Type{H}, arguments, keyword::Bool) where {H <: Fields}
    named = [a for a in arguments if is_named(a)]
    isempty(named) && return string(document_schema_name(H), "()")
    pieces = [keyword ? string(a.name, " = ", a.literal) : a.literal for a in named]
    single = string(document_schema_name(H), "(", join(pieces, ", "), ")")
    Base.length(single) <= 76 && return single
    return string(document_schema_name(H), "(\n    ", join(pieces, ",\n    "), ")")
end

"""
    construction_text(h::Fields)::String

The keyword call that rebuilds `h`, as text. `describe_construction` gives the
same call with the reason for every field beside it.
"""
construction_text(h::Fields) = describe_construction(h).call

# An embedded header is built by its own keyword call, so a field whose type is
# a header nests one construction inside another.
literal_field(h::Fields) = construction_text(h)

# ---------- what one field update does ---------------------------------------

"""
    HeaderUpdate(type, field, before, after, literal, before_bytes, after_bytes, changed)

One field of a header, read and then written. `changed` holds the 1-based
indices of the bytes that differ, which for a field inside one byte is one
index.
"""
struct HeaderUpdate
    type::Type
    field::Symbol
    before::String
    after::String
    literal::String
    before_bytes::Vector{UInt8}
    after_bytes::Vector{UInt8}
    changed::Vector{Int}
end

"""
    describe_update(h::Fields)::HeaderUpdate

Read one field of `h`, write a different value to it, and report which bytes
moved.

The field is the first one an update can demonstrate anything with: not a
`Constant` and not a `Pad`, which hold nothing a caller decides; not a `Model`,
which never reaches the wire; not derived, which the writer overwrites; not
checked, which would refuse the new value; and not variable-length, which would
change how long the header is rather than what it says.

The new value flips the field's lowest bit. That is width-safe for any field
the codec can put in a `UInt64` — a four-bit field stays inside four bits — and
it changes exactly one byte, which is what makes the two byte strings worth
printing side by side.
"""
function describe_update(h::H) where {H <: Fields}
    name = find_updatable_field(H)
    name === nothing &&
        error("describe_update: ", document_schema_name(H), " has no field an update can show")
    type = fieldtype(H, name)
    before = getfield(h, name)
    after = decode_field(type, encode_field(type, before) ⊻ UInt64(1))
    updated = set_field(h, name, after)
    before_bytes = encode_header(h)
    after_bytes = encode_header(updated)
    changed = [i for i in 1:min(Base.length(before_bytes), Base.length(after_bytes))
                 if before_bytes[i] != after_bytes[i]]
    return HeaderUpdate(H, name, format_field(before), format_field(after),
                        literal_field(after), before_bytes, after_bytes, changed)
end

"""
    find_updatable_field(::Type{H}) -> Symbol or nothing

The first field of `H` that `describe_update` can demonstrate on.
"""
function find_updatable_field(::Type{H}) where {H <: Fields}
    derived = list_derived(H)
    checked = list_checked(H)
    for index in 1:header_count(H)
        name = fieldname(H, index)
        type = fieldtype(H, index)
        name in derived && continue
        name in checked && continue
        (type <: Constant || type <: Pad || type <: Model) && continue
        # An enum names its values, and the value beside one is rarely a value
        # the enum has — flipping a bit there builds something that is not.
        type <: Base.Enum && continue
        is_variable_field(type) && continue
        has_field_bits(type) || continue
        classify_display(type) === :composite && continue
        return name
    end
    return nothing
end

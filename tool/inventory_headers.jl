# ============================================================================
# The INET wire-format inventory, and the generator that writes it.
#
# INET declares a wire format twice: a `.msg` file states the field model, and
# a hand-written `*Serializer.cc` states the bit layout. This script joins the
# two and writes `package/packet/doc/inventory.md`, which says which formats
# `inet-julia` must declare with `@header` and which capability each one needs.
#
# `inventory.md` is output — regenerate it with:
#
#     julia --project=tool tool/inventory_headers.jl
#
# Run from the repository root. The script needs a checkout of `inet-cpp` and
# reads one git ref out of it; it changes nothing there. Point it elsewhere
# with the two environment variables named below.
#
# Why the branch below and not `master`: on `master` a `FieldsChunk` built by
# deserialization cached the original wire bytes and the serializer replayed
# the cache, so a reader and a writer could disagree and no test noticed. The
# branch clears the cache and repairs what that exposed, which makes it the
# only ref whose serializers state the real layout.
# ============================================================================

const INET_CPP = get(ENV, "INET_CPP", joinpath(dirname(@__DIR__), "..", "inet-cpp"))
const INET_REF = get(ENV, "INET_REF", "remotes/origin/topic/bz/serializertest")
const OUTPUT   = joinpath(@__DIR__, "..", "package", "packet", "doc", "inventory.md")

# ---------- read the ref -----------------------------------------------------

"Every path in `ref` whose name matches `pattern`, with its contents."
function read_sources(pattern::Regex)
    listing = readchomp(`git -C $INET_CPP ls-tree -r --name-only $INET_REF`)
    paths = filter(p -> occursin(pattern, p), split(listing, '\n'))
    return Dict(String(p) => read(`git -C $INET_CPP show $INET_REF:$p`, String) for p in paths)
end

# ---------- the class graph --------------------------------------------------

struct MsgClass
    name::String
    base::String
    file::String
    body::String
end

const DECL = r"^\s*(class|struct|packet|message)\s+(?:noncobject\s+)?([A-Za-z_]\w*)\s*(?:extends\s+(?:\w+::)*([A-Za-z_]\w*))?\s*(.*)$"

"Every class a `.msg` file declares, by name."
function parse_classes(sources::Dict{String, String})
    classes = Dict{String, MsgClass}()
    for (path, source) in sources
        lines = split(source, '\n')
        index = 1
        while index <= length(lines)
            match_ = match(DECL, lines[index])
            if match_ === nothing
                index += 1
                continue
            end
            _, name, base, rest = match_.captures
            if startswith(strip(rest), ";")               # a forward declaration
                classes[name] = MsgClass(name, base === nothing ? "" : base, path, "")
                index += 1
                continue
            end
            open_at = index
            while open_at <= length(lines) && !occursin('{', lines[open_at])
                open_at += 1
            end
            depth = 0
            close_at = open_at
            while close_at <= length(lines)
                depth += count(==('{'), lines[close_at]) - count(==('}'), lines[close_at])
                depth <= 0 && occursin('{', join(lines[open_at:close_at])) && break
                close_at += 1
            end
            close_at = min(close_at, length(lines))
            classes[name] = MsgClass(name, base === nothing ? "" : base, path,
                                     join(lines[open_at:close_at], '\n'))
            index = close_at + 1
        end
    end
    return classes
end

"Every class that derives from `root`, however far down."
function descendants(classes::Dict{String, MsgClass}, root::String)
    children = Dict{String, Vector{String}}()
    for (name, class) in classes
        push!(get!(children, class.base, String[]), name)
    end
    found = String[]
    stack = [root]
    while !isempty(stack)
        for child in get(children, pop!(stack), String[])
            push!(found, child)
            push!(stack, child)
        end
    end
    return sort!(unique!(found))
end

# ---------- the serializers --------------------------------------------------

"The serializer class of every chunk class, from `Register_Serializer`."
function parse_registrations(sources::Dict{String, String})
    registrations = Dict{String, String}()
    for source in values(sources)
        for match_ in eachmatch(r"Register_Serializer\(\s*([\w:]+)\s*,\s*([\w:]+)\s*\)", source)
            chunk = last(split(match_.captures[1], "::"))
            serializer = last(split(match_.captures[2], "::"))
            registrations[chunk] = serializer
        end
    end
    return registrations
end

"The body of `class::method`, braces included, or an empty string."
function method_body(source::AbstractString, class::AbstractString, method::AbstractString)
    pattern = Regex("(?:void|const\\s+Ptr<Chunk>)\\s+" * class * "::" * method * "\\s*\\([^{;]*\\)\\s*const\\s*\\{")
    match_ = match(pattern, source)
    match_ === nothing && return ""
    # Iterate over character indices, not byte positions: a copyright line may
    # hold a non-ASCII name, and a byte index inside one is not a valid index.
    start = something(findnext('{', source, match_.offset))
    depth = 0
    for index in Iterators.dropwhile(<(start), eachindex(source))
        source[index] == '{' && (depth += 1)
        source[index] == '}' && (depth -= 1; depth == 0 && return source[start:index])
    end
    return ""
end

# The constructs a codec may use, and the plan section that answers each one.
const CONSTRUCTS = [
    (:repetition, r"\bfor\s*\(|\bwhile\s*\(",                     "D1, D2"),
    (:helper,     r"\w+[sS]erializ\w*\(\s*stream|\w+[dD]eserializ\w*\(\s*stream", "D2, F1"),
    (:variant,    r"switch\s*\(|dynamicPtrCast|check_and_cast",   "E2"),
    (:cursor,     r"getPosition|getLength\(\)|getRemainingLength|isReadBeyondEnd", "C1, C4"),
    (:rawbytes,   r"(write|read)Bytes|writeData",                 "C2"),
    (:padding,    r"Repeatedly",                                  "C3"),
    (:quality,    r"markIncorrect|markIncomplete|markImproperlyRepresented", "B3"),
    (:littleendian, r"Uint\d+Le",                                 "A2"),
    (:subbyte,    r"writeBit\b|readBit\b|Uint2\(|Uint4\(|NBits|writeBits|readBits", "A1"),
    (:branch,     r"\bif\s*\(",                                   "B3, E3"),
]

"The constructs the codec of `serializer` uses."
function codec_constructs(sources::Dict{String, String}, serializer::AbstractString)
    source = ""
    for candidate in values(sources)
        if occursin(Regex("\\b" * serializer * "::serialize\\b"), candidate)
            source = candidate
            break
        end
    end
    isempty(source) && return Symbol[]
    body = method_body(source, serializer, "serialize") *
           "\n" * method_body(source, serializer, "deserialize")
    return [name for (name, pattern, _) in CONSTRUCTS if occursin(pattern, body)]
end

# The tier of a codec: the deepest capability it needs.
function tier(constructs::Vector{Symbol})
    :repetition in constructs && return "T3"
    :helper     in constructs && return "T3"
    :variant    in constructs && return "T4"
    (:cursor in constructs || :rawbytes in constructs) && return "T2"
    any(c -> c in constructs, (:padding, :littleendian, :quality, :branch)) && return "T1"
    return "T0"
end

const TIER_MEANING = Dict(
    "T0" => "fixed widths, big-endian, nothing else",
    "T1" => "plus padding, byte order or validation",
    "T2" => "plus a length that depends on the data",
    "T3" => "plus repetition: arrays or option lists",
    "T4" => "plus a variant: one format, many types")

# ---------- the report -------------------------------------------------------

"The INET package a `.msg` path belongs to, e.g. `linklayer/ieee80211`."
function family(path::AbstractString)
    parts = split(path, '/')
    startswith(path, "src/inet/") || return "(not in src)"
    return length(parts) > 4 ? join(parts[3:4], '/') : join(parts[3:3], '/')
end

function main()
    isdir(INET_CPP) || error("inventory_headers: no checkout at $INET_CPP; set INET_CPP")
    # Only the model itself. A doc snippet and a unit-test fixture declare a
    # class of the same name as a real one — `TcpHeader` and `UdpHeader` both —
    # so a parse that reads them cannot say which declaration it kept.
    messages = read_sources(r"^src/inet/.*\.msg$")
    codecs = read_sources(r"Serializer\.cc$")
    classes = parse_classes(messages)
    registrations = parse_registrations(codecs)

    chunks = descendants(classes, "FieldsChunk")

    # One codec serves many chunk classes, so read each codec once.
    constructs = Dict(serializer => codec_constructs(codecs, serializer)
                      for serializer in unique(values(registrations)))

    rows = map(chunks) do name
        serializer = get(registrations, name, "")
        used = isempty(serializer) ? Symbol[] : constructs[serializer]
        (name = name, family = family(classes[name].file),
         file = classes[name].file, serializer = serializer,
         tier = isempty(serializer) ? "—" : tier(used), constructs = used)
    end

    open(OUTPUT, "w") do io
        write_report(io, rows, messages, codecs, registrations)
    end
    println("inventory_headers: wrote $(relpath(OUTPUT, pwd())) — ",
            "$(length(rows)) formats, $(count(r -> !isempty(r.serializer), rows)) with a codec")
end

function write_report(io, rows, messages, codecs, registrations)
    with_codec = filter(r -> !isempty(r.serializer), rows)
    println(io, "# The INET wire-format inventory")
    println(io)
    println(io, "⚙️ **Generated.** Do not edit by hand. Regenerate with")
    println(io, "`julia --project=tool tool/inventory_headers.jl`; the generator is")
    println(io, "[`tool/inventory_headers.jl`](../../../tool/inventory_headers.jl) and the plan")
    println(io, "behind it is `plan/*/protocol-header-inventory.md`.")
    println(io)
    println(io, "Source: `$INET_REF` in the `inet-cpp` checkout.")
    println(io)
    println(io, "Every class below derives from INET's `FieldsChunk`, which means it is a")
    println(io, "wire format that `inet-julia` declares with `@header`. A class with no")
    println(io, "serializer states a field model that no C++ code turns into bytes.")
    println(io)

    println(io, "## The size of it")
    println(io)
    println(io, "| fact | count |")
    println(io, "| --- | --- |")
    println(io, "| `.msg` files read | $(length(messages)) |")
    println(io, "| `*Serializer.cc` files read | $(length(codecs)) |")
    println(io, "| classes that derive from `FieldsChunk` | $(length(rows)) |")
    println(io, "| … with a registered serializer | $(length(with_codec)) |")
    println(io, "| … with no wire format at all | $(length(rows) - length(with_codec)) |")
    println(io, "| serializer classes that carry them | $(length(unique(values(registrations)))) |")
    println(io)

    println(io, "## The tiers")
    println(io)
    println(io, "The tier is a property of the codec, so a family that shares one codec")
    println(io, "shares one tier.")
    println(io)
    println(io, "| tier | what the codec needs | formats |")
    println(io, "| --- | --- | --- |")
    for name in ("T0", "T1", "T2", "T3", "T4")
        println(io, "| $name | $(TIER_MEANING[name]) | $(count(r -> r.tier == name, rows)) |")
    end
    println(io)

    println(io, "## Capability demand")
    println(io)
    println(io, "How many formats need each construct, counted over the $(length(with_codec))")
    println(io, "formats that have a codec.")
    println(io)
    println(io, "| construct | formats | plan section |")
    println(io, "| --- | --- | --- |")
    for (name, _, section) in CONSTRUCTS
        println(io, "| $name | $(count(r -> name in r.constructs, with_codec)) | $section |")
    end
    println(io)

    println(io, "## The families")
    println(io)
    println(io, "| family | formats | with a codec | tiers |")
    println(io, "| --- | --- | --- | --- |")
    families = unique(r.family for r in rows)
    sort!(families, by = f -> -count(r -> r.family == f, rows))
    for name in families
        members = filter(r -> r.family == name, rows)
        coded = filter(r -> !isempty(r.serializer), members)
        tiers = join((("$t:$(count(r -> r.tier == t, coded))")
                      for t in ("T0", "T1", "T2", "T3", "T4")
                      if count(r -> r.tier == t, coded) > 0), ", ")
        println(io, "| `$name` | $(length(members)) | $(length(coded)) | $tiers |")
    end
    println(io)

    println(io, "## Every format")
    println(io)
    println(io, "| format | family | tier | serializer | needs |")
    println(io, "| --- | --- | --- | --- | --- |")
    for row in sort(rows, by = r -> (r.family, r.name))
        codec = isempty(row.serializer) ? "— model only" : "`$(row.serializer)`"
        needs = join(("`$c`" for c in row.constructs), " ")
        println(io, "| `$(row.name)` | `$(row.family)` | $(row.tier) | $codec | $needs |")
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()

#!/usr/bin/env julia
#
# Rewrite the call sites of an element that moved onto `@simulation_module`.
#
# When an element declares its fields by kind, two things about it change
# everywhere it is used:
#
#   1. a parameter struct disappears, so
#          Mod(:name, ModParameters(a = 1); seed = 2)
#      becomes
#          Mod(:name; a = 1, seed = 2)
#
#   2. the three containers disappear, so
#          m.parameters.a   m.states.timer   m.statistics.num_packets
#      become
#          m.a              m.timer          m.num_packets
#
# There are a few hundred of these across the queuing package, and a textual
# search-and-replace gets them wrong. `source` names an active source in one
# test and a passive one in the next, so the same characters must be rewritten
# in one place and left alone in the other. The receiver's type decides, and
# only the syntax tree knows it.
#
# So this tool parses. It locates every site with `Base.JuliaSyntax`, infers
# the type of each receiver from the bindings that reach it, and splices text
# at the byte ranges the parser reports. Everything it cannot prove, it names
# and leaves alone.
#
# Usage:
#
#     julia tool/port_to_module_macro.jl              # report, change nothing
#     julia tool/port_to_module_macro.jl --apply      # write the files
#     julia tool/port_to_module_macro.jl --check      # exit 1 if anything is refused
#
# It takes no element argument. It finds the ported elements by reading the
# `@simulation_module` declarations in the tree, so the way to use it is: port
# one element by hand, run this, read the report, then apply.

module PortToModuleMacro

const JS = Base.JuliaSyntax

# ─────────────────────────────────────────────────────────────────────────────
# The syntax tree
# ─────────────────────────────────────────────────────────────────────────────

kids(n) = something(JS.children(n), JS.SyntaxNode[])
kd(n) = JS.kind(n)
span(n) = JS.byte_range(n)
piece(src::AbstractString, n) = src[span(n)]

# A node's range starts at the whitespace before it, not at its first
# character. Everything that reads or moves a node's text wants the range
# without that lead-in, so that a re-render does not carry a stray newline.
function tight_span(src::AbstractString, n)
    r = span(n)
    at = first(r)
    while at <= last(r) && src[at] in (' ', '\t', '\n', '\r')
        at += 1
    end
    at:last(r)
end

tight_piece(src::AbstractString, n) = src[tight_span(src, n)]

# The name at the end of a possibly qualified reference: `X` and `A.B.X` both
# give `X`. Anything else has no name.
function simple_name(n)
    kd(n) == JS.K"Identifier" && return n.val
    kd(n) == JS.K"." && length(kids(n)) == 2 && return simple_name(kids(n)[2])
    nothing
end

line_of(src::AbstractString, pos::Int) = count(==('\n'), SubString(src, 1, prevind(src, pos))) + 1

# The byte where the line holding `pos` starts.
function line_start(src::AbstractString, pos::Int)
    i = something(findprev('\n', src, prevind(src, pos)), 0)
    i + 1
end

# The characters before `pos` on its line, and how many of them are the indent.
line_prefix(src::AbstractString, pos::Int) = SubString(src, line_start(src, pos), prevind(src, pos))
indent_width(src::AbstractString, pos::Int) = count(c -> c == ' ', match(r"^ *", line_prefix(src, pos)).match)
column_of(src::AbstractString, pos::Int) = length(line_prefix(src, pos))

# The characters after `pos` on its line, with the trailing spaces dropped.
function line_suffix(src::AbstractString, pos::Int)
    stop = something(findnext('\n', src, pos), lastindex(src) + 1) - 1
    rstrip(SubString(src, min(pos + 1, lastindex(src) + 1), stop))
end

# Take up to `n` spaces off the front of a line.
function unindent(line::AbstractString, n::Int)
    taken = 0
    while taken < n && taken < ncodeunits(line) && line[taken + 1] == ' '
        taken += 1
    end
    SubString(line, taken + 1)
end

# Move every line but the first by `delta` columns.
function reindent(text::AbstractString, delta::Int)
    delta == 0 && return String(text)
    lines = split(text, '\n')
    for i in 2:length(lines)
        line = lines[i]
        isempty(strip(line)) && continue
        lines[i] = delta > 0 ? " "^delta * line : unindent(line, -delta)
    end
    join(lines, '\n')
end

# ─────────────────────────────────────────────────────────────────────────────
# What the world holds
# ─────────────────────────────────────────────────────────────────────────────

# The sections of `@simulation_module`, singular and plural, and the kind each
# declares.
const SECTIONS = Dict(
    Symbol("@parameters") => :parameter, Symbol("@parameter") => :parameter,
    Symbol("@variables")  => :variable,  Symbol("@variable")  => :variable,
    Symbol("@statistics") => :statistic, Symbol("@statistic") => :statistic,
    Symbol("@gates")      => :gate,      Symbol("@gate")      => :gate,
    Symbol("@streams")    => :stream,    Symbol("@stream")    => :stream,
    Symbol("@signals")    => :signal,    Symbol("@signal")    => :signal)

# The container a field of each kind used to sit in, before the port. A gate
# was always a field of the module itself, and a signal was never a field.
const CONTAINER = Dict(:parameter => :parameters, :variable => :states,
                       :stream => :states, :statistic => :statistics)

const CONTAINERS = Set([:parameters, :states, :statistics])

struct Element
    name::Symbol                       # ActivePacketSourceModule
    file::String
    ported::Bool
    fields::Dict{Symbol,Symbol}        # field => kind, for a ported element
end

struct World
    elements::Dict{Symbol,Element}
    retired::Dict{Symbol,Symbol}       # ActivePacketSourceParameters => the element
    structs::Set{Symbol}               # every struct that is still defined
    returns::Dict{Symbol,Any}          # function name => what it returns
end

ported(w::World, name) = name isa Symbol && haskey(w.elements, name) && w.elements[name].ported

# The inferred type of an expression is one of: the name of a module kind, a
# `VecOf`, a `Record`, or nothing when it is not known. Two of them are equal
# when they say the same thing, which is what lets one harvest be compared with
# the next.
struct VecOf; of; end
struct Record; fields::Dict{Symbol,Any}; end

Base.:(==)(a::VecOf, b::VecOf) = a.of == b.of
Base.:(==)(a::Record, b::Record) = a.fields == b.fields

# ─────────────────────────────────────────────────────────────────────────────
# Reading a declaration
# ─────────────────────────────────────────────────────────────────────────────

# The field a section item declares. An item is `f::T`, or `f::T = default`, or
# `f::T = default in domain` — the name is the leftmost identifier either way.
function declared_field(n)
    k = kd(n)
    k == JS.K"Identifier" && return n.val
    (k == JS.K"=" || k == JS.K"::") && return declared_field(kids(n)[1])
    nothing
end

function read_sections!(fields::Dict{Symbol,Symbol}, body)
    for item in kids(body)
        kd(item) == JS.K"macrocall" || continue
        parts = kids(item)
        kind = get(SECTIONS, parts[1].val, nothing)
        kind === nothing && continue
        for arg in parts[2:end]
            # A plural section holds a block; a singular one holds the field.
            for decl in (kd(arg) == JS.K"block" ? kids(arg) : (arg,))
                name = declared_field(decl)
                name === nothing || (fields[name] = kind)
            end
        end
    end
end

# Every module kind the file defines, and every struct name it uses up.
function collect_elements!(elements, structs, file, tree)
    function visit(n)
        if kd(n) == JS.K"macrocall" && !isempty(kids(n)) &&
           kids(n)[1].val === Symbol("@simulation_module")
            decl = findfirst(c -> kd(c) == JS.K"struct", kids(n))
            if decl !== nothing
                s = kids(n)[decl]
                name = simple_name(kids(s)[1])
                fields = Dict{Symbol,Symbol}()
                length(kids(s)) >= 2 && read_sections!(fields, kids(s)[2])
                name === nothing ||
                    (elements[name] = Element(name, file, true, fields); push!(structs, name))
            end
        elseif kd(n) == JS.K"struct"
            head = kids(n)[1]
            name = simple_name(kd(head) == JS.K"<:" ? kids(head)[1] : head)
            name === nothing || push!(structs, name)
            if kd(head) == JS.K"<:" && simple_name(kids(head)[2]) === :AbstractModule &&
               name !== nothing && !haskey(elements, name)
                elements[name] = Element(name, file, false, Dict{Symbol,Symbol}())
            end
        end
        foreach(visit, kids(n))
    end
    visit(tree)
end

# The parameter struct of a ported element is retired, and so are its states
# and its statistics — unless a struct by that name is still defined, which
# means the port left it behind on purpose.
function collect_retired(elements, structs)
    retired = Dict{Symbol,Symbol}()
    for (name, element) in elements
        element.ported || continue
        base = replace(String(name), r"Module$" => "")
        for suffix in ("Parameters", "States", "Statistics")
            old = Symbol(base, suffix)
            old in structs || (retired[old] = name)
        end
    end
    retired
end

# ─────────────────────────────────────────────────────────────────────────────
# The walk over one file
# ─────────────────────────────────────────────────────────────────────────────

struct Edit
    range::UnitRange{Int}
    text::String
    what::Symbol                       # :call, :field, :import
    line::Int
    detail::String
end

struct Note
    file::String
    line::Int
    severity::Symbol                   # :refuse or :assume
    message::String
end

mutable struct FileScan
    file::String
    src::String
    world::World
    width::Int
    scopes::Vector{Dict{Symbol,Any}}
    edits::Vector{Edit}
    notes::Vector{Note}
    harvest::Bool                      # true: only learn what functions return
end

function lookup(sc::FileScan, name::Symbol)
    for scope in Iterators.reverse(sc.scopes)
        haskey(scope, name) && return scope[name]
    end
    nothing
end

bind!(sc::FileScan, name::Symbol, ty) = (sc.scopes[end][name] = ty)

note!(sc::FileScan, pos::Int, severity::Symbol, message::AbstractString) =
    push!(sc.notes, Note(sc.file, line_of(sc.src, pos), severity, message))

# A block that holds its own bindings. `@testset` is one of them: its body is a
# scope in Julia, which is exactly why the same name means two things in two
# neighbouring test sets.
function opens_scope(n)
    k = kd(n)
    k in (JS.K"function", JS.K"->", JS.K"do", JS.K"let", JS.K"for", JS.K"while",
          JS.K"generator", JS.K"module", JS.K"struct", JS.K"comprehension") && return true
    k == JS.K"macrocall" && !isempty(kids(n)) &&
        kids(n)[1].val in (Symbol("@testset"),) && return true
    false
end

# ── inference ────────────────────────────────────────────────────────────────

function infer(sc::FileScan, n)
    k = kd(n)
    if k == JS.K"Identifier"
        return lookup(sc, n.val)
    elseif k == JS.K"."
        length(kids(n)) == 2 || return nothing
        base = infer(sc, kids(n)[1])
        field = simple_name(kids(n)[2])
        base isa Record && field !== nothing && return get(base.fields, field, nothing)
        return nothing
    elseif k == JS.K"ref"
        base = infer(sc, kids(n)[1])
        return base isa VecOf ? base.of : nothing
    elseif k == JS.K"call"
        return infer_call(sc, n)
    elseif k == JS.K"vect"
        for c in kids(n)
            t = infer(sc, c)
            t === nothing || return VecOf(t)
        end
        return nothing
    elseif k == JS.K"comprehension"
        body = kids(n)
        isempty(body) && return nothing
        gen = body[1]
        kd(gen) == JS.K"generator" || return nothing
        t = infer(sc, kids(gen)[1])
        return t === nothing ? nothing : VecOf(t)
    elseif k == JS.K"tuple"
        return infer_tuple(sc, n)
    elseif k == JS.K"block"
        return isempty(kids(n)) ? nothing : infer(sc, last(kids(n)))
    elseif k == JS.K"return"
        return isempty(kids(n)) ? nothing : infer(sc, kids(n)[1])
    elseif (k == JS.K"?" || k == JS.K"if") && length(kids(n)) == 3
        # A ternary. One known branch is taken as the answer, because the
        # unknown one is normally a keyword defaulting to `nothing`.
        a, b = infer(sc, kids(n)[2]), infer(sc, kids(n)[3])
        a === nothing && return b
        b === nothing && return a
        return a == b ? a : nothing
    end
    nothing
end

# `(; network, source, queues = q)` — a shorthand name is its own binding.
function infer_tuple(sc::FileScan, n)
    fields = Dict{Symbol,Any}()
    function take(item)
        if kd(item) == JS.K"Identifier"
            t = lookup(sc, item.val)
            t === nothing || (fields[item.val] = t)
        elseif kd(item) == JS.K"="
            name = simple_name(kids(item)[1])
            t = infer(sc, kids(item)[2])
            name === nothing || t === nothing || (fields[name] = t)
        end
    end
    for c in kids(n)
        kd(c) == JS.K"parameters" ? foreach(take, kids(c)) : take(c)
    end
    isempty(fields) ? nothing : Record(fields)
end

function infer_call(sc::FileScan, n)
    callee = simple_name(kids(n)[1])
    callee === nothing && return nothing
    haskey(sc.world.elements, callee) && return callee
    # `add_module!(network, m)` and `add_submodule!(parent, m)` answer for `m`.
    if callee in (:add_module!, :add_submodule!) && length(kids(n)) >= 3
        return infer(sc, kids(n)[3])
    end
    get(sc.world.returns, callee, nothing)
end

# ── the walk ─────────────────────────────────────────────────────────────────

function walk!(sc::FileScan, n; statement::Bool = false)
    scoped = opens_scope(n)
    scoped && push!(sc.scopes, Dict{Symbol,Any}())
    try
        if kd(n) == JS.K"function"
            walk_function!(sc, n)
        elseif kd(n) in (JS.K"for", JS.K"generator")
            # The loop variable takes the element type, so `for queue in queues`
            # says what `queue` is.
            spec = kd(n) == JS.K"for" ? kids(n)[1] : kids(n)[end]
            bind_iteration!(sc, spec)
            foreach(c -> walk!(sc, c; statement = kd(c) == JS.K"block"), kids(n))
        elseif kd(n) == JS.K"call" && length(kids(n)) >= 3 && kd(kids(n)[2]) == JS.K"->" &&
               simple_name(kids(n)[1]) in OVER_A_COLLECTION
            # `all(sink -> sink.statistics.num_packets > 0, sinks)` says what
            # `sink` is, and there is no other way to know.
            over = infer(sc, kids(n)[3])
            walk_lambda!(sc, kids(n)[2], over isa VecOf ? over.of : nothing)
            for c in kids(n)[3:end]
                walk!(sc, c)
            end
        elseif kd(n) == JS.K"=" && statement
            walk!(sc, kids(n)[2])
            lhs = kids(n)[1]
            if kd(lhs) == JS.K"Identifier"
                bind!(sc, lhs.val, infer(sc, kids(n)[2]))
            else
                walk!(sc, lhs)
            end
        elseif kd(n) in (JS.K"block", JS.K"toplevel")
            for c in kids(n)
                walk!(sc, c; statement = true)
            end
        else
            # A test set holds statements, and so does a `let` or a `for` body,
            # but the block is reached through the branch above.
            for c in kids(n)
                walk!(sc, c; statement = kd(n) == JS.K"macrocall")
            end
        end
        sc.harvest || visit_site!(sc, n)
    finally
        scoped && pop!(sc.scopes)
    end
    nothing
end

function walk_function!(sc::FileScan, n)
    parts = kids(n)
    isempty(parts) && return
    bind_signature!(sc, parts[1])
    length(parts) >= 2 && walk!(sc, parts[2]; statement = kd(parts[2]) != JS.K"block")
    if sc.harvest
        name = signature_name(parts[1])
        if name !== nothing && length(parts) >= 2
            ty = infer(sc, parts[2])
            if ty !== nothing
                previous = get(sc.world.returns, name, nothing)
                # Two functions of one name that answer differently answer for
                # nothing: the tool must not guess between them.
                sc.world.returns[name] = previous === nothing || previous == ty ? ty : nothing
            end
        end
    end
    nothing
end

# The functions that take a function and a collection, in that order.
const OVER_A_COLLECTION = Set([:all, :any, :count, :sum, :prod, :map, :filter, :foreach,
                               :maximum, :minimum, :findfirst, :findall, :mapreduce])

function walk_lambda!(sc::FileScan, lam, element)
    push!(sc.scopes, Dict{Symbol,Any}())
    try
        head = kids(lam)[1]
        names = kd(head) == JS.K"tuple" ? [simple_name(c) for c in kids(head)] : [simple_name(head)]
        element === nothing || length(names) != 1 || names[1] === nothing ||
            bind!(sc, names[1], element)
        for c in kids(lam)[2:end]
            walk!(sc, c; statement = kd(c) == JS.K"block")
        end
    finally
        pop!(sc.scopes)
    end
    nothing
end

function bind_iteration!(sc::FileScan, spec)
    for it in (kd(spec) == JS.K"iteration" ? kids(spec) : (spec,))
        kd(it) == JS.K"in" && length(kids(it)) == 2 || continue
        name = simple_name(kids(it)[1])
        over = infer(sc, kids(it)[2])
        name === nothing && continue
        over isa VecOf && bind!(sc, name, over.of)
    end
    nothing
end

signature_name(sig) =
    kd(sig) == JS.K"call" ? simple_name(kids(sig)[1]) :
    kd(sig) in (JS.K"where", JS.K"::") ? signature_name(kids(sig)[1]) : nothing

function bind_signature!(sc::FileScan, sig)
    if kd(sig) in (JS.K"where", JS.K"::")
        return bind_signature!(sc, kids(sig)[1])
    end
    kd(sig) == JS.K"call" || return
    function take(arg)
        if kd(arg) == JS.K"::" && length(kids(arg)) == 2
            name, ty = simple_name(kids(arg)[1]), simple_name(kids(arg)[2])
            name === nothing || ty === nothing ||
                (haskey(sc.world.elements, ty) && bind!(sc, name, ty))
        elseif kd(arg) == JS.K"="
            take(kids(arg)[1])
        end
    end
    for arg in kids(sig)[2:end]
        kd(arg) == JS.K"parameters" ? foreach(take, kids(arg)) : take(arg)
    end
    nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# The sites
# ─────────────────────────────────────────────────────────────────────────────

function visit_site!(sc::FileScan, n)
    k = kd(n)
    if k == JS.K"." && length(kids(n)) == 2 && kd(kids(n)[1]) == JS.K"."
        visit_chain!(sc, n)
    elseif k == JS.K"call"
        visit_construction!(sc, n)
    elseif k == JS.K"using" || k == JS.K"import" || k == JS.K"export"
        visit_name_list!(sc, n)
    end
    nothing
end

# `receiver.container.field`
function visit_chain!(sc::FileScan, n)
    inner = kids(n)[1]
    length(kids(inner)) == 2 || return
    container = simple_name(kids(inner)[2])
    container in CONTAINERS || return
    field = simple_name(kids(n)[2])
    field === nothing && return
    receiver = kids(inner)[1]
    ty = infer(sc, receiver)

    if ported(sc.world, ty)
        element = sc.world.elements[ty]
        kind = get(element.fields, field, nothing)
        if kind === nothing
            note!(sc, first(span(n)), :refuse,
                  "$(ty) does not declare `$(field)`, so `.$(container).$(field)` is left alone")
            return
        end
        expected = get(CONTAINER, kind, nothing)
        expected == container || note!(sc, first(span(n)), :assume,
            "`$(field)` is a $(kind) but was read out of `.$(container)`")
        # Cut out `.container`, which runs from just after the receiver to the
        # end of the inner reference.
        cut = (last(span(receiver)) + 1):last(span(inner))
        push!(sc.edits, Edit(cut, "", :field, line_of(sc.src, first(span(n))),
                             "$(piece(sc.src, receiver)).$(container).$(field) → " *
                             "$(piece(sc.src, receiver)).$(field)"))
    elseif ty === nothing && any(e -> e.ported && haskey(e.fields, field),
                                 values(sc.world.elements))
        note!(sc, first(span(n)), :refuse,
              "cannot tell the type of `$(piece(sc.src, receiver))`, " *
              "so `.$(container).$(field)` is left alone")
    end
    nothing
end

# `Mod(:name, ModParameters(…); …)`
function visit_construction!(sc::FileScan, n)
    callee = simple_name(kids(n)[1])
    ported(sc.world, callee) || return
    at = first(span(n))

    args = collect(kids(n)[2:end])
    trailing = findfirst(a -> kd(a) == JS.K"parameters", args)
    keywords = trailing === nothing ? JS.SyntaxNode[] : collect(kids(args[trailing]))
    trailing === nothing || deleteat!(args, trailing)

    inline = filter(a -> kd(a) == JS.K"=", args)
    positional = filter(a -> kd(a) != JS.K"=", args)

    # The one positional argument that is a retired parameter struct.
    which = findfirst(a -> kd(a) == JS.K"call" &&
                           get(sc.world.retired, something(simple_name(kids(a)[1]), :_), nothing) === callee &&
                           endswith(String(something(simple_name(kids(a)[1]), :_)), "Parameters"),
                      positional)
    which === nothing && return                    # already in the new shape
    pstruct = positional[which]
    deleteat!(positional, which)

    if length(positional) != 1
        note!(sc, at, :refuse,
              "`$(callee)(…)` has $(length(positional)) positional arguments beside its " *
              "parameters, and the generated constructor takes one")
        return
    end
    pkw = JS.SyntaxNode[]
    for a in kids(pstruct)[2:end]
        if kd(a) == JS.K"="
            push!(pkw, a)
        elseif kd(a) == JS.K"parameters"
            append!(pkw, kids(a))
        else
            note!(sc, at, :refuse,
                  "`$(simple_name(kids(pstruct)[1]))(…)` is given a positional argument, " *
                  "so its fields cannot be named")
            return
        end
    end

    name_arg = positional[1]
    kwargs = vcat(pkw, inline, keywords)
    keep = [tight_span(sc.src, x) for x in vcat([kids(n)[1], name_arg, kids(pstruct)[1]], kwargs)]

    # Everything between the parts that are kept must be punctuation. A comment
    # in there would be dropped by re-rendering, so the call is left alone and
    # a person is told where it is.
    if !only_punctuation_between(sc.src, span(n), keep)
        note!(sc, at, :refuse,
              "`$(callee)(…)` holds a comment between its arguments, so it is left alone")
        return
    end

    # A nested rewrite inside an argument is folded into that argument's text.
    inside = filter(e -> first(e.range) >= first(span(n)) && last(e.range) <= last(span(n)), sc.edits)
    filter!(e -> !(first(e.range) >= first(span(n)) && last(e.range) <= last(span(n))), sc.edits)

    text = render_construction(sc, n, name_arg, kwargs, inside)
    push!(sc.edits, Edit(span(n), text, :call, line_of(sc.src, at),
                         "$(callee)(…, $(simple_name(kids(pstruct)[1]))(…)) → keywords"))
    nothing
end

function only_punctuation_between(src, whole::UnitRange{Int}, keep)
    covered = falses(length(whole))
    for r in keep
        covered[(first(r) - first(whole) + 1):(last(r) - first(whole) + 1)] .= true
    end
    for (i, taken) in enumerate(covered)
        taken && continue
        at = first(whole) + i - 1
        # A byte in the middle of a character is never punctuation.
        isvalid(src, at) || return false
        src[at] in (' ', '\t', '\n', '\r', '(', ')', ',', ';') || return false
    end
    true
end

# The source text of one argument, with the rewrites inside it already made and
# its continuation lines moved to where the argument now starts.
function argument_text(sc::FileScan, node, inside, column::Int)
    r = tight_span(sc.src, node)
    text = sc.src[r]
    for e in sort(filter(e -> first(e.range) >= first(r) && last(e.range) <= last(r), inside),
                  by = e -> first(e.range), rev = true)
        head = text[1:(first(e.range) - first(r))]
        tail = text[(last(e.range) - first(r) + 2):end]
        text = string(head, e.text, tail)
    end
    reindent(text, column - column_of(sc.src, first(r)))
end

function render_construction(sc::FileScan, n, name_arg, kwargs, inside)
    at = first(span(n))
    callee = piece(sc.src, kids(n)[1])
    indent = indent_width(sc.src, at)
    column = column_of(sc.src, at)

    flat_name = argument_text(sc, name_arg, inside, column + length(callee) + 1)
    flat = string(callee, "(", flat_name,
                  isempty(kwargs) ? "" : "; ",
                  join((argument_text(sc, k, inside, 0) for k in kwargs), ", "), ")")
    # What follows the call on its line has to fit as well: the call is usually
    # the argument of `add_module!`, and the brackets close after it.
    tail = length(line_suffix(sc.src, last(span(n))))
    if !occursin('\n', flat) && column + length(flat) + tail <= sc.width
        return flat
    end

    body = indent + 4
    parts = [argument_text(sc, k, inside, body) for k in kwargs]
    string(callee, "(", flat_name, isempty(parts) ? "" : ";\n" * " "^body,
           join(parts, ",\n" * " "^body), ")")
end

# A retired name in a `using`, an `import` or an `export` goes, and takes one
# separator with it.
function visit_name_list!(sc::FileScan, n)
    items = if kd(n) == JS.K"export"
        kids(n)
    else
        inner = findfirst(c -> kd(c) == JS.K":", kids(n))
        inner === nothing ? JS.SyntaxNode[] : kids(kids(n)[inner])[2:end]
    end
    isempty(items) && return
    named(item) = kd(item) == JS.K"importpath" && length(kids(item)) == 1 ?
                  simple_name(kids(item)[1]) : simple_name(item)
    gone = [i for (i, item) in enumerate(items) if haskey(sc.world.retired, something(named(item), :_))]
    isempty(gone) && return

    if length(gone) == length(items)
        # Nothing is left to bring in, so the whole line goes.
        r = span(n)
        stop = something(findnext('\n', sc.src, last(r)), last(r))
        push!(sc.edits, Edit(line_start(sc.src, first(r)):stop, "", :import,
                             line_of(sc.src, first(r)), "drop `$(strip(sc.src[r]))`"))
        return
    end
    for i in gone
        # Take the separator on the side that has one, so no comma is orphaned.
        cut = i > 1 ? ((last(span(items[i - 1])) + 1):last(span(items[i]))) :
                      (first(span(items[i])):(first(span(items[i + 1])) - 1))
        push!(sc.edits, Edit(cut, "", :import, line_of(sc.src, first(span(items[i]))),
                             "drop `$(named(items[i]))` from the list"))
    end
    nothing
end

# A retired name that survives anywhere else has to be looked at by a person.
function report_survivors!(sc::FileScan, tree)
    covered(pos) = any(e -> pos in e.range, sc.edits)
    function visit(n)
        if kd(n) == JS.K"Identifier" && haskey(sc.world.retired, n.val) && !covered(first(span(n)))
            note!(sc, first(span(n)), :refuse, "`$(n.val)` is retired but still named here")
        end
        foreach(visit, kids(n))
    end
    visit(tree)
    nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Applying the edits
# ─────────────────────────────────────────────────────────────────────────────

function apply_edits(src::AbstractString, edits::Vector{Edit})
    ordered = sort(edits, by = e -> first(e.range))
    for i in 2:length(ordered)
        first(ordered[i].range) > last(ordered[i - 1].range) ||
            error("two rewrites overlap at byte $(first(ordered[i].range))")
    end
    out = IOBuffer()
    at = 1
    for e in ordered
        print(out, SubString(src, at, prevind(src, first(e.range))))
        print(out, e.text)
        at = last(e.range) + 1
    end
    print(out, SubString(src, at))
    String(take!(out))
end

# ─────────────────────────────────────────────────────────────────────────────
# The run
# ─────────────────────────────────────────────────────────────────────────────

function parse_file(path, src)
    try
        JS.parseall(JS.SyntaxNode, src; filename = path)
    catch err
        @warn "cannot parse, so it is skipped" path
        nothing
    end
end

function scan_world(root, files)
    elements = Dict{Symbol,Element}()
    structs = Set{Symbol}()
    sources = Dict{String,Any}()
    for file in files
        src = read(joinpath(root, file), String)
        tree = parse_file(file, src)
        tree === nothing && continue
        sources[file] = (src, tree)
        collect_elements!(elements, structs, file, tree)
    end
    world = World(elements, collect_retired(elements, structs), structs, Dict{Symbol,Any}())
    # What a function returns may rest on what another one returns, so the
    # harvest runs twice and settles.
    for _ in 1:2, file in sort(collect(keys(sources)))
        src, tree = sources[file]
        sc = FileScan(file, src, world, 92, [Dict{Symbol,Any}()], Edit[], Note[], true)
        walk!(sc, tree)
    end
    world, sources
end

function rewrite_file(world, file, src, tree, width)
    sc = FileScan(file, src, world, width, [Dict{Symbol,Any}()], Edit[], Note[], false)
    walk!(sc, tree)
    report_survivors!(sc, tree)
    sc
end

function main(argv)
    apply = "--apply" in argv
    check = "--check" in argv
    width = let i = findfirst(==("--width"), argv)
        i === nothing ? 92 : parse(Int, argv[i + 1])
    end
    root = let i = findfirst(==("--root"), argv)
        i === nothing ? dirname(@__DIR__) : argv[i + 1]
    end

    files = filter(f -> endswith(f, ".jl"),
                   split(read(`git -C $root ls-files`, String), '\n'; keepempty = false))
    world, sources = scan_world(root, files)

    porteds = sort([String(k) for (k, e) in world.elements if e.ported])
    if isempty(porteds)
        println("No element declares itself with `@simulation_module` yet.")
        return 0
    end
    println("ported: ", join(porteds, ", "))
    println("retired: ", join(sort([String(k) for k in keys(world.retired)]), ", "))
    println()

    changed, edited, refused, assumed = 0, 0, 0, 0
    for file in sort(collect(keys(sources)))
        src, tree = sources[file]
        sc = rewrite_file(world, file, src, tree, width)
        (isempty(sc.edits) && isempty(sc.notes)) && continue

        println(file)
        for e in sort(sc.edits, by = e -> e.line)
            println("  ", lpad(e.line, 5), "  ", rpad(String(e.what), 6), "  ", e.detail)
        end
        for n in sort(sc.notes, by = n -> n.line)
            println("  ", lpad(n.line, 5), "  ", n.severity == :refuse ? "REFUSE" : "assume",
                    "  ", n.message)
        end
        println()

        edited += length(sc.edits)
        refused += count(n -> n.severity == :refuse, sc.notes)
        assumed += count(n -> n.severity == :assume, sc.notes)
        isempty(sc.edits) && continue
        changed += 1

        out = apply_edits(src, sc.edits)
        # A rewrite that does not parse is a fault in this tool, not in the
        # source, so it never reaches the working tree.
        try
            JS.parseall(JS.SyntaxNode, out; filename = file)
        catch err
            error("the rewrite of $(file) does not parse, so nothing was written:\n$(err)")
        end
        apply && write(joinpath(root, file), out)
    end

    println("$(edited) rewrites in $(changed) files, $(refused) refused, $(assumed) assumed",
            apply ? " — written." : " — nothing written, pass --apply.")
    check && refused > 0 ? 1 : 0
end

end # module

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(PortToModuleMacro.main(ARGS))
end

# ── The leaf rules ──────────────────────────────────────────────────────────
#
# A package image is built with exactly that package's dependencies present, so
# compiled code survives only in a package nothing depends on and nothing loads
# after — the leaf the `ji` alias loads. These rules keep that true, and they
# are asserted rather than only written down because the cost of breaking one is
# invisible: it shows up as a slow first paint, not as a failure.
#
# The counterparts are `test_package_graph` in projectured-julia and
# omnetpp-julia. See documentation/packages.md.

const _REPOSITORY_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

const _LEAVES = ("InetRepl",)

# Every package in the tree — main, example, test, repl — mapped to the sibling
# packages it declares. Read from the `Project.toml` files rather than from the
# loaded modules, so a dependency that is declared but unused still shows up.
function _read_packages()
    packages = Dict{String,Vector{String}}()
    for (root, _dirs, files) in walkdir(joinpath(_REPOSITORY_ROOT, "package"))
        "Project.toml" in files || continue
        text = read(joinpath(root, "Project.toml"), String)
        name = match(r"(?m)^name = \"([^\"]+)\"", text)
        name === nothing && continue
        deps = String[]
        in_deps = false
        for line in split(text, "\n")
            if startswith(line, "[")
                in_deps = line == "[deps]"
                continue
            end
            in_deps || continue
            m = match(r"^((?:Inet|Omnetpp|Projectured)\w*) = ", line)
            m === nothing || push!(deps, m.captures[1])
        end
        packages[name.captures[1]] = deps
    end
    packages
end

@testset "package dependency graph" begin
    packages = _read_packages()

    @testset "the tree is readable" begin
        @test haskey(packages, "InetRepl")
        @test haskey(packages, "Inet")
    end

    @testset "nothing depends on a leaf" begin
        for (name, deps) in sort(collect(packages))
            for leaf in _LEAVES
                leaf in deps && println(stderr, "\n$name depends on the leaf $leaf")
                @test !(leaf in deps)
            end
        end
    end

    @testset "an example package is a dependency only of a leaf, an example or a test" begin
        for (name, deps) in sort(collect(packages))
            (endswith(name, "Example") || endswith(name, "Test")) && continue
            name in _LEAVES && continue
            examples = sort(filter(d -> endswith(d, "Example"), deps))
            isempty(examples) ||
                println(stderr, "\n$name depends on the example package(s) $examples")
            @test isempty(examples)
        end
    end

    @testset "a compile workload lives only in a leaf" begin
        offenders = String[]
        for (root, _dirs, files) in walkdir(joinpath(_REPOSITORY_ROOT, "package"))
            occursin(joinpath("package", "repl"), root) && continue
            for file in files
                endswith(file, ".jl") || continue
                path = joinpath(root, file)
                # A call, not a mention: the macro at the head of a line.
                occursin(r"(?m)^\s*@compile_workload\b", read(path, String)) &&
                    push!(offenders, relpath(path, _REPOSITORY_ROOT))
            end
        end
        isempty(offenders) ||
            println(stderr, "\n@compile_workload outside a leaf:\n  ",
                    join(offenders, "\n  "))
        @test isempty(offenders)
    end

    @testset "a third-party dependency is one that was named" begin
        # documentation/packages.md names each one with its reason, so this is
        # asserted rather than described: a package that acquires one is named
        # there first, and then added here. The list is short on purpose.
        allowed = Dict("InetRepl"       => ["PrecompileTools", "Preferences"],
                       "InetRunner"     => ["Preferences"],
                       "InetRunnerTest" => ["Preferences"])
        known = ("Inet", "Omnetpp", "Projectured", "Test", "Dates", "TOML",
                 "Random", "Statistics", "Printf", "Serialization", "UUIDs",
                 "InteractiveUtils", "Profile", "LinearAlgebra", "SHA", "Base64")
        for (root, _dirs, files) in walkdir(joinpath(_REPOSITORY_ROOT, "package"))
            "Project.toml" in files || continue
            text = read(joinpath(root, "Project.toml"), String)
            name = match(r"(?m)^name = \"([^\"]+)\"", text)
            name === nothing && continue
            in_deps = false
            foreign = String[]
            for line in split(text, "\n")
                if startswith(line, "[")
                    in_deps = line == "[deps]"
                    continue
                end
                in_deps || continue
                m = match(r"^(\w+) = \"", line)
                m === nothing && continue
                dep = m.captures[1]
                any(k -> startswith(dep, k), known) && continue
                dep in get(allowed, name.captures[1], String[]) && continue
                push!(foreign, dep)
            end
            isempty(foreign) ||
                println(stderr, "\n$(name.captures[1]) declares $(sort(foreign)) — ",
                        "name it in documentation/packages.md, then allow it here")
            @test isempty(foreign)
        end
    end
end

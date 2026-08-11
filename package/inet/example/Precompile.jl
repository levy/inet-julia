# ═══════════════════════════════════════════════════════════════════════════
# example/Precompile.jl
#
# This repository's share of the build-time compilation, on the same terms as
# `ProjecturedExample`'s and `OmnetppPresentationExample`'s: the workload runs
# the pipeline and forces the output, because the chain is lazy and `precompile`
# on the signatures cannot name the closures the cell machinery calls.
#
# There is deliberately no `@compile_workload` in this file. A package image is
# built with exactly that package's dependencies present, so code compiled here
# is invalidated as soon as a session loads anything above it. The macro lives
# in `InetRepl`.
#
# See plan/pending/package-convention-repl-leaves.md.
# ═══════════════════════════════════════════════════════════════════════════

"""
    precompile_workload() -> Nothing

The body a leaf package's `@compile_workload` calls — `InetRepl` for a session.
An ordinary function, so it can be called and timed without a rebuild.

It runs the upstream workload and then this repository's own catalog page.
There are no levels: they graded build time against the first click, and a
recording settles that trade, so a build now either replays a recorded list or
runs this. See `InetRepl.WORKLOAD`.

The upstream call is `ProjecturedExample`'s, and it is not a duplicated effort.
A workload can only cache inference that is still valid when the session has
finished loading, so the last package in the chain has to redo the upstream work
in its own image, where the method set is complete. Measured in omnetpp-julia,
loading its umbrella and its example and test packages voids 15286 method
instances in the images below.
"""
function precompile_workload()
    ProjecturedExample.precompile_workload()
    _precompile_catalog_page()
    nothing
end

# This repository's own catalog, opened and forced, with no window. The page
# path is not reached by any atom: an atom is one node type, a page is the whole
# chain over a file.
function _precompile_catalog_page()
    try
        shell = demo_catalog()
        projection = demo_projection()
        force(out) = Projectured.GraphicsModule._canvas_content_bounds(
            out, Projectured.TrueTypeModule.truetype_measure_text)
        force(Projectured.IoMapModule.get_iomap_output(
            Projectured.ProjectionApiModule.print_document(projection, shell)))
        # And one header page, whose chain the index page does not exercise: a
        # parsed declaration, a reflected instance and a bit grid, all on one
        # page.
        index = findfirst(e -> e.path == "pages/header/Ipv4Header.md",
                          collect(shell.entries))
        if index !== nothing
            open_page!(shell, index)
            force(Projectured.IoMapModule.get_iomap_output(
                Projectured.ProjectionApiModule.print_document(projection, shell)))
        end
    catch
        # A precompile workload must not fail a build. The catalog test is where
        # a page that cannot open is meant to be noticed.
    end
    nothing
end

# ============================================================================
# The model catalog `Inet` offers, on top of the kernel's own.
#
# `Omnetpp.default_simulation_catalog()` lists the models that ship with the
# kernel. That catalog is deliberately a VALUE rather than a global registry,
# which is exactly what lets a model library extend it without the kernel
# having to know the library exists.
# ============================================================================

"""
    inet_simulation_catalog()

The kernel's `default_simulation_catalog()` extended with the models `Inet`
provides. Hand it to a workbench to offer them:

    SimulationWorkbench(; catalog = inet_simulation_catalog())
"""
inet_simulation_catalog() = Any[default_simulation_catalog()...,
                                SimulationType(T1sModel)]

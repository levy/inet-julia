# The catalog is the umbrella's job: a model library extends the kernel's
# `default_simulation_catalog()` with everything it provides, and only the
# umbrella knows about every component.

using Inet
using OmnetppSimulator
# The components themselves, to check the umbrella hands back their modules.
using InetPacket, InetCommon, InetQueuing, InetLinkLayer

@testset "the models Inet offers" begin
    catalog = inet_simulation_catalog()
    kernel_catalog = default_simulation_catalog()

    @testset "every kernel model is still offered" begin
        for entry in kernel_catalog
            @test any(offered -> offered.model_type === entry.model_type, catalog)
        end
    end

    @testset "each component's models are added" begin
        @test any(entry -> entry.model_type === QueuingModel, catalog)
        @test any(entry -> entry.model_type === T1sModel, catalog)
        @test length(catalog) == length(kernel_catalog) + 2
    end
end

@testset "the components are reachable through the umbrella" begin
    # `using Inet.PacketModule` has to keep working now that the module lives
    # in a package of its own.
    @test Inet.PacketModule === InetPacket.PacketModule
    @test Inet.LookupModule === InetCommon.LookupModule
    @test Inet.T1sModule === InetLinkLayer.T1sModule
    @test Inet.PacketProtocolModule === InetQueuing.PacketProtocolModule
end

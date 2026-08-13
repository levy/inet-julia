# Phase 0b of plan/pending/queuing-model-migration.md — module lookup and the
# packet protocol contract. The modules here are stand-ins carrying claims and
# counting calls: what is under test is finding the right peer and the wiring
# checks, not any element's behaviour.

using InetCommon.LookupModule
using InetQueuing.PacketProtocolModule
using InetPacket.PacketModule
using OmnetppSimulator.NetworkModule
# Lookup by reference, for the modules that are named rather than connected.
using ProjecturedKernel.ReferenceModule: Reference, FieldReferenceStep, ElementReferenceStep

# A push endpoint pair: `Producer` drives, `Consumer` accepts.
mutable struct Producer <: SimulationModule
    name::Symbol
    module_id::Int
    out::Gate
    consumer::ModuleRef
    resumed::Int
end

function Producer(name::Symbol)
    m = Producer(name, 0, Gate(nothing, :out, GateOutput;
                               annotations = Any[InterfaceClaim(ActivePacketSource)]),
                 NO_MODULE_REF, 0)
    m.out.owner = m
    m
end

PacketProtocolModule.handle_can_push_packet_changed!(::Any, m::Producer, ::Gate) =
    (m.resumed += 1; nothing)

mutable struct Consumer <: SimulationModule
    name::Symbol
    module_id::Int
    in::Gate
    accepts::Bool
    pushed::Vector{Packet}
end

function Consumer(name::Symbol; accepts::Bool = true)
    m = Consumer(name, 0, Gate(nothing, :in, GateInput;
                               annotations = Any[InterfaceClaim(PassivePacketSink)]),
                 accepts, Packet[])
    m.in.owner = m
    m
end

PacketProtocolModule.can_push_some_packet(m::Consumer, ::Gate) = m.accepts
PacketProtocolModule.can_push_packet(m::Consumer, ::Gate, ::Packet) = m.accepts
PacketProtocolModule.push_packet!(::Any, m::Consumer, ::Gate, packet::Packet) =
    (push!(m.pushed, packet); nothing)

# A pull endpoint pair: `Collector` drives, `Provider` hands packets over.
mutable struct Provider <: SimulationModule
    name::Symbol
    module_id::Int
    out::Gate
    packets::Vector{Packet}
end

function Provider(name::Symbol)
    m = Provider(name, 0, Gate(nothing, :out, GateOutput;
                               annotations = Any[InterfaceClaim(PassivePacketSource)]),
                 Packet[])
    m.out.owner = m
    m
end

PacketProtocolModule.can_pull_some_packet(m::Provider, ::Gate) = !isempty(m.packets)
PacketProtocolModule.can_pull_packet(m::Provider, ::Gate) =
    isempty(m.packets) ? nothing : m.packets[1]
PacketProtocolModule.pull_packet!(::Any, m::Provider, ::Gate) = popfirst!(m.packets)

mutable struct Collector <: SimulationModule
    name::Symbol
    module_id::Int
    in::Gate
    provider::ModuleRef
    resumed::Int
end

function Collector(name::Symbol)
    m = Collector(name, 0, Gate(nothing, :in, GateInput;
                                annotations = Any[InterfaceClaim(ActivePacketSink)]),
                  NO_MODULE_REF, 0)
    m.in.owner = m
    m
end

PacketProtocolModule.handle_can_pull_packet_changed!(::Any, m::Collector, ::Gate) =
    (m.resumed += 1; nothing)

# A transparent element: it takes packets in and passes them on, and answers a
# lookup on behalf of whatever is behind it.
mutable struct Relay <: SimulationModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
end

function Relay(name::Symbol)
    m = Relay(name, 0,
              Gate(nothing, :in, GateInput;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
              Gate(nothing, :out, GateOutput;
                   annotations = Any[InterfaceClaim(ActivePacketSource)]),
              )
    m.in.owner = m
    m.out.owner = m
    m
end

# A module that decides in code rather than by claims — the dispatcher pattern.
mutable struct Chooser <: SimulationModule
    name::Symbol
    module_id::Int
    in::Gate
    answer::Symbol      # :own, :refuse, or :silent
end

function Chooser(name::Symbol, answer::Symbol)
    m = Chooser(name, 0, Gate(nothing, :in, GateInput), answer)
    m.in.owner = m
    m
end

function LookupModule.lookup_module_interface(m::Chooser, gate::Gate, ::Type, ::Any, ::Int)
    m.answer === :own && return own_interface(gate)
    m.answer === :refuse && return nothing
    USE_GATE_CLAIMS
end

a_packet() = Packet(Filler(Bytes(100)))

@testset "lookup and contract" begin
    @testset "finding a peer along a connection" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        consumer = add_module!(network, Consumer(:consumer))
        connect_gates!(producer.out, consumer.in)

        ref = find_module_interface(producer.out, PassivePacketSink)
        @test ref !== nothing
        @test ref.target === consumer
        @test ref.gate === consumer.in
        @test ref.delay == OmnetppSimulator.ZERO_DELAY
        @test is_resolved(ref) && resolved_module(ref) === consumer

        # The walk goes the way packets travel: forwards out of an output gate,
        # backwards out of an input gate. So the consumer finds its producer
        # over the same connection, without being told where to look.
        back = find_module_interface(consumer.in, ActivePacketSource)
        @test back.target === producer

        # An interface nobody claims is not found, and a gate connected to
        # nothing reaches nothing.
        @test find_module_interface(producer.out, PassivePacketSource) === nothing
        @test find_module_interface(Producer(:lonely).out, PassivePacketSink) === nothing
    end

    @testset "delay is accumulated on the way" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        relay = add_module!(network, Relay(:relay))
        consumer = add_module!(network, Consumer(:consumer))
        connect_gates!(producer.out, relay.in; delay = to_simtime(0.001))
        connect_gates!(relay.out, consumer.in; delay = to_simtime(0.002))

        # The relay answers for what is behind it, but it is the relay that is
        # found: packets go through it, so the delay is only the first hop's.
        ref = find_module_interface(producer.out, PassivePacketSink)
        @test ref.target === relay
        @test ref.delay == to_simtime(0.001)
        @test find_module_interface(relay.out, PassivePacketSink).delay == to_simtime(0.002)
    end

    @testset "forwarding depends on what is behind" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        relay = add_module!(network, Relay(:relay))
        connect_gates!(producer.out, relay.in)

        # A relay with nothing behind it cannot promise to accept a push, so
        # the lookup fails at the relay rather than finding it.
        @test find_module_interface(producer.out, PassivePacketSink) === nothing

        consumer = add_module!(network, Consumer(:consumer))
        connect_gates!(relay.out, consumer.in)
        @test find_module_interface(producer.out, PassivePacketSink).target === relay

        # A forward naming a gate the module does not have is a modelling error.
        upstream = Producer(:upstream)
        broken = Relay(:broken)
        push!(empty!(broken.in.annotations), ForwardClaim(PassivePacketSink, :nowhere))
        connect_gates!(upstream.out, broken.in)
        connect_gates!(broken.out, Consumer(:c2).in)
        @test_throws ErrorException find_module_interface(upstream.out, PassivePacketSink)
    end

    @testset "answering in code beats claims, including a refusal" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        chooser = add_module!(network, Chooser(:chooser, :own))
        connect_gates!(producer.out, chooser.in)
        @test find_module_interface(producer.out, PassivePacketSink).target === chooser

        # Saying no ends the walk: a module that refuses is not deferring to
        # whatever lies behind it.
        network2 = Network(:Net2)
        producer2 = add_module!(network2, Producer(:producer))
        refuser = add_module!(network2, Chooser(:refuser, :refuse))
        consumer2 = add_module!(network2, Consumer(:consumer))
        connect_gates!(producer2.out, refuser.in)
        refuser_out = Gate(refuser, :out, GateOutput)
        connect_gates!(refuser_out, consumer2.in)
        @test find_module_interface(producer2.out, PassivePacketSink) === nothing

        # Staying silent defers instead: the walk carries on wherever the
        # connections do. A module that neither claims nor speaks and passes
        # straight through is invisible to a lookup.
        network3 = Network(:Net3)
        producer3 = add_module!(network3, Producer(:producer))
        quiet = add_module!(network3, Chooser(:quiet, :silent))
        consumer3 = add_module!(network3, Consumer(:consumer))
        quiet_out = Gate(quiet, :out, GateOutput)
        connect_gates!(producer3.out, quiet.in)
        connect_gates!(quiet.in, quiet_out)               # a pass-through
        connect_gates!(quiet_out, consumer3.in)
        @test find_module_interface(producer3.out, PassivePacketSink).target === consumer3

        # Where the connections stop, so does the walk: a module that says
        # nothing and leads nowhere is simply the end of the chain.
        network4 = Network(:Net4)
        producer4 = add_module!(network4, Producer(:producer))
        deadend = add_module!(network4, Chooser(:deadend, :silent))
        connect_gates!(producer4.out, deadend.in)
        @test find_module_interface(producer4.out, PassivePacketSink) === nothing
    end

    @testset "resolve_interface stores an outcome" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        consumer = add_module!(network, Consumer(:consumer))
        connect_gates!(producer.out, consumer.in)
        producer.consumer = resolve_interface(producer.out, PassivePacketSink)
        @test producer.consumer.target === consumer

        # A required peer that is missing is reported while the network is
        # built, naming the gate and what was wanted.
        lonely = Producer(:lonely)
        err = try resolve_interface(lonely.out, PassivePacketSink); nothing catch ex; ex end
        @test err isa ErrorException
        @test occursin("lonely.out", err.msg) && occursin("PassivePacketSink", err.msg)
        # An optional one simply comes back unresolved.
        @test !is_resolved(resolve_interface(lonely.out, PassivePacketSink; mandatory = false))
    end

    @testset "finding a module by reference" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        consumer = add_module!(network, Consumer(:consumer))
        connect_gates!(producer.out, consumer.in)

        # Modules a parameter names rather than a connection reaches are found
        # by evaluating a reference against the network.
        reference = Reference(FieldReferenceStep("modules"), ElementReferenceStep(2))
        ref = resolve_module(network, reference, PassivePacketSink)
        @test ref.target === consumer
        @test ref.gate === nothing          # nothing travels there; it is called
        @test ref.delay == OmnetppSimulator.ZERO_DELAY

        # The interface is checked, so a reference to the wrong module is caught
        # where it is configured rather than where it is used.
        wrong = Reference(FieldReferenceStep("modules"), ElementReferenceStep(1))
        @test_throws ErrorException resolve_module(network, wrong, PassivePacketSink)
        # A reference that does not resolve at all is reported too.
        missing_ref = Reference(FieldReferenceStep("modules"), ElementReferenceStep(9))
        @test_throws ErrorException resolve_module(network, missing_ref, PassivePacketSink)
        # An unset optional parameter needs no special case at the call site.
        @test !is_resolved(resolve_module(network, nothing, PassivePacketSink))
    end

    @testset "delivering a packet" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        consumer = add_module!(network, Consumer(:consumer))
        connect_gates!(producer.out, consumer.in)
        producer.consumer = resolve_interface(producer.out, PassivePacketSink)

        engine = SequentialSimulator(network_module_count(network))
        packet, delayed = a_packet(), a_packet()
        schedule_root!(engine, to_simtime(0.0), module_id(producer), function (ctx)
            @test can_push_some_packet(producer.consumer)
            @test can_push_packet(producer.consumer, packet)
            # Over an ideal connection delivery is a direct call, so the packet
            # has arrived by the time push_or_schedule! returns — no event.
            push_or_schedule!(ctx, producer.consumer, packet)
            @test consumer.pushed == [packet]
        end)
        advance_engine!(engine)
        @test length(consumer.pushed) == 1

        # Over a connection with a delay it becomes a scheduled event instead,
        # and the packet arrives later.
        network2 = Network(:Net2)
        producer2 = add_module!(network2, Producer(:producer))
        consumer2 = add_module!(network2, Consumer(:consumer))
        connect_gates!(producer2.out, consumer2.in; delay = to_simtime(0.5))
        producer2.consumer = resolve_interface(producer2.out, PassivePacketSink)
        engine2 = SequentialSimulator(network_module_count(network2))
        arrival = Ref(to_simtime(-1.0))
        schedule_root!(engine2, to_simtime(0.0), module_id(producer2), function (ctx)
            push_or_schedule!(ctx, producer2.consumer, delayed)
            @test isempty(consumer2.pushed)      # still in flight
        end)
        schedule_root!(engine2, to_simtime(1.0), module_id(consumer2),
                       ctx -> (arrival[] = ctx.timestamp))
        advance_engine!(engine2)
        @test consumer2.pushed == [delayed]
        @test arrival[] == to_simtime(1.0)
    end

    @testset "flow control reaches the driver" begin
        network = Network(:Net)
        producer = add_module!(network, Producer(:producer))
        consumer = add_module!(network, Consumer(:consumer; accepts = false))
        connect_gates!(producer.out, consumer.in)
        producer.consumer = resolve_interface(producer.out, PassivePacketSink)
        consumer_producer = resolve_interface(consumer.in, ActivePacketSource)

        @test !can_push_some_packet(producer.consumer)
        handle_can_push_packet_changed!(nothing, consumer_producer)
        @test producer.resumed == 1

        # The pull side works the same way, in the other direction.
        network2 = Network(:Net2)
        provider = add_module!(network2, Provider(:provider))
        collector = add_module!(network2, Collector(:collector))
        connect_gates!(provider.out, collector.in)
        collector.provider = resolve_interface(collector.in, PassivePacketSource)
        provider_collector = resolve_interface(provider.out, ActivePacketSink)

        @test !can_pull_some_packet(collector.provider)
        packet = a_packet()
        push!(provider.packets, packet)
        handle_can_pull_packet_changed!(nothing, provider_collector)
        @test collector.resumed == 1
        @test can_pull_packet(collector.provider) === packet     # a look, not a take
        @test pull_packet!(nothing, collector.provider) === packet
        @test isempty(provider.packets)
    end

    @testset "an unimplemented method names the module and the interface" begin
        silent = Chooser(:silent, :silent)
        err = try can_push_some_packet(silent, silent.in); nothing catch ex; ex end
        @test err isa ErrorException
        @test occursin("silent", err.msg) && occursin("PassivePacketSink", err.msg)

        # So does calling through a reference that was never resolved.
        @test_throws ErrorException can_push_some_packet(NO_MODULE_REF)
    end

    @testset "wiring is checked while the network is built" begin
        good = Network(:Good)
        producer = add_module!(good, Producer(:producer))
        consumer = add_module!(good, Consumer(:consumer))
        connect_gates!(producer.out, consumer.in)
        @test check_packet_connections(good) === good

        # One end pushes, the other waits to be pulled from: no packet would
        # ever move, and the model would merely look idle.
        crossed = Network(:Crossed)
        producer2 = add_module!(crossed, Producer(:producer))
        collector = add_module!(crossed, Collector(:collector))
        connect_gates!(producer2.out, collector.in)
        err = try check_packet_connections(crossed); nothing catch ex; ex end
        @test err isa ErrorException
        @test occursin("producer.out", err.msg)

        # A pull is a call that returns a packet, so a delay has nowhere to go.
        delayed = Network(:Delayed)
        provider = add_module!(delayed, Provider(:provider))
        collector2 = add_module!(delayed, Collector(:collector))
        connect_gates!(provider.out, collector2.in; delay = to_simtime(0.001))
        err2 = try check_packet_connections(delayed); nothing catch ex; ex end
        @test err2 isa ErrorException
        @test occursin("propagation delay", err2.msg)

        # A provider with nothing pulling from it is reported too.
        idle = Network(:Idle)
        provider2 = add_module!(idle, Provider(:provider))
        consumer3 = add_module!(idle, Consumer(:consumer))
        connect_gates!(provider2.out, consumer3.in)
        @test_throws ErrorException check_packet_connections(idle)
    end
end

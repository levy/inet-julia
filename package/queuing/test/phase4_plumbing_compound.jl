# Phase 4 of plan/pending/queuing-model-migration.md — the plumbing that lets
# chains be shapes other than a line, the first compound module, and the whole
# thing driven through the lifecycle as a model.

using InetQueuing.ActivePacketSourceElement
using InetQueuing.PassivePacketSinkElement
using InetQueuing.ActivePacketSinkElement
using InetQueuing.PacketQueueElement
using InetQueuing.PacketServerElement
using InetQueuing.PacketClassifierElement
using InetQueuing.PacketPlumbingElement
using InetQueuing.PriorityQueueElement
using InetQueuing.PacketSourceModule
using InetQueuing: QueuingModel
using InetPacket.PacketModule
using OmnetppSimulator.VolatileModule

@testset "plumbing and compound modules" begin
    @testset "a multiplexer merges push chains" begin
        network = Network(:Merge)
        sources = [add_module!(network, ActivePacketSourceModule(Symbol(:source, index),
                       ActivePacketSourceParameters(production_interval = 0.1 * index)))
                   for index in 1:2]
        merge = add_module!(network, PacketMultiplexerModule(:merge, 2))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(sources[1].out, merge.in[1])
        connect!(sources[2].out, merge.in[2])
        connect!(merge.out, sink.in)
        run_network!(network; until = 1.0)

        # Everything both sources made arrives, and the merge counted all of it.
        produced = sum(source -> source.statistics.num_packets, sources)
        @test produced == 11 + 6
        @test merge.num_packets == produced
        @test sink.statistics.num_packets == produced
    end

    @testset "a multiplexer passes back pressure to every producer" begin
        network = Network(:MergeSlow)
        sources = [add_module!(network, ActivePacketSourceModule(Symbol(:source, index),
                       ActivePacketSourceParameters(production_interval = 0.1)))
                   for index in 1:2]
        merge = add_module!(network, PacketMultiplexerModule(:merge, 2))
        slow = add_module!(network, PassivePacketSinkModule(:sink,
            PassivePacketSinkParameters(consumption_interval = 0.25)))
        connect!(sources[1].out, merge.in[1])
        connect!(sources[2].out, merge.in[2])
        connect!(merge.out, slow.in)
        run_network!(network; until = 2.0)

        # The pair is held to the shared sink's rate. Room is offered to the
        # producers in order, so the first one takes it every time and the
        # second is refused again — sharing a sink is not fair queuing, and
        # anything that needs fairness puts a scheduler in the way.
        @test slow.statistics.num_packets == 9
        @test sum(source -> source.statistics.num_packets, sources) == 9
        @test sources[1].statistics.num_packets == 9
        @test sources[2].statistics.num_packets == 0
    end

    @testset "a demultiplexer lets several collectors pull" begin
        network = Network(:Split)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1)))
        queue = add_module!(network, PacketQueueModule(:queue))
        split = add_module!(network, PacketDemultiplexerModule(:split, 2))
        sinks = [add_module!(network, ActivePacketSinkModule(Symbol(:sink, index),
                     ActivePacketSinkParameters(collection_interval = 0.2 * index)))
                 for index in 1:2]
        connect!(source.out, queue.in)
        connect!(queue.out, split.in)
        connect!(split.out[1], sinks[1].in)
        connect!(split.out[2], sinks[2].in)
        run_network!(network; until = 2.0)

        collected = sum(sink -> sink.statistics.num_packets, sinks)
        @test collected == split.num_packets
        @test all(sink -> sink.statistics.num_packets > 0, sinks)
        # Nothing is duplicated or lost: what arrived was produced, and what
        # was not collected is still in the queue.
        @test source.statistics.num_packets == collected + queue_length(queue)
    end

    @testset "a delayer holds each packet" begin
        network = Network(:Delay)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1)))
        delayer = add_module!(network, PacketDelayerModule(:delayer,
            PacketDelayerParameters(delay = 0.25)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, delayer.in)
        connect!(delayer.out, sink.in)
        run_network!(network; until = 1.0)

        # Several packets are in flight at once — the delayer holds them, it
        # does not serve them one at a time.
        @test source.statistics.num_packets == 11
        @test sink.statistics.num_packets == 8
        @test packets_in_flight(delayer) == 3
        @test sink.statistics.total_life_time == 8 * to_simtime(0.25)
    end

    @testset "a drawn delay reorders packets" begin
        network = Network(:Jitter)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1,
                packet = PacketTemplate(length = Volatile(intuniform(80, 800)))); seed = 6))
        delayer = add_module!(network, PacketDelayerModule(:delayer,
            PacketDelayerParameters(delay = Volatile(uniform(0.05, 0.5))); seed = 8))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, delayer.in)
        connect!(delayer.out, sink.in)
        run_network!(network; until = 5.0)

        @test sink.statistics.num_packets > 40
        # Lives differ because delays do, which is what makes this a path with
        # jitter rather than a fixed one.
        @test sink.statistics.total_life_time != sink.statistics.num_packets * to_simtime(0.275)
    end

    @testset "a priority queue behaves like one queue" begin
        network = Network(:Compound)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.05,
                packet = PacketTemplate(length = Volatile(intuniform(80, 800)))); seed = 3))
        # Short packets are urgent, the rest are not.
        urgent_first = content_based_classifier(:classifier,
            [packet -> bits(data_length(packet)) < 400, _ -> true])
        queue = priority_queue(network, :queue, 2; classifier = urgent_first)
        server = add_module!(network, PacketServerModule(:server,
            PacketServerParameters(processing_time = 0.25)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        # From outside, the compound is wired exactly like a plain queue.
        connect!(source.out, queue.in)
        connect!(queue.out, server.in)
        connect!(server.out, sink.in)
        run_network!(network; until = 3.0)

        # Nothing outside knew it was a compound: the source found the
        # classifier through the boundary, the server found the scheduler.
        @test source.statistics.num_packets > 0
        @test sink.statistics.num_packets > 0
        @test priority_queue_length(queue) ==
              queue_length(queue.queues[1]) + queue_length(queue.queues[2])
        @test source.statistics.num_packets ==
              sink.statistics.num_packets + priority_queue_length(queue) +
              priority_queue_dropped(queue) + 1

        # The urgent level is served first, so it stays short while the other
        # one backs up.
        @test queue_length(queue.queues[1]) < queue_length(queue.queues[2])
        # A compound owns no engine id; its submodules are the scheduling ones,
        # and their paths say where they live.
        @test !has_module_id(queue)
        @test length(submodules(queue)) == 4          # classifier, two queues, scheduler
    end

    @testset "a compound is invisible to the wiring" begin
        network = Network(:Through)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1)))
        queue = priority_queue(network, :queue, 2)
        server = add_module!(network, PacketServerModule(:server,
            PacketServerParameters(processing_time = 0.05)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, queue.in)
        connect!(queue.out, server.in)
        connect!(server.out, sink.in)
        initialize_network!(network)

        # The lookups reach inside: what the source found is the classifier and
        # what the server found is the scheduler, not the compound.
        @test source.consumer.target === queue.classifier
        @test server.provider.target === queue.scheduler
        # And the delay edges join the modules that really communicate, with
        # the compound in none of them.
        edges = network_delay_edges(network)
        @test !any(edge -> edge[1] == 0 || edge[2] == 0, edges)
        @test (module_id(source), module_id(queue.classifier),
               OmnetppSimulator.ZERO_DELAY) in edges
    end

    @testset "the queuing chain as a model the lifecycle runs" begin
        # Everything the lifecycle needs comes from the network the elements
        # form: how many modules, which delay edges, what to start.
        type = SimulationType(QueuingModel)
        assignment = ParameterAssignment(Dict{Symbol,Any}(
            :arrival_rate => 5.0, :service_rate => 10.0, :time_limit => 2000.0, :seed => 7))
        run = expand_simulation(configure_simulation(type, assignment))[1]
        execution = prepare_simulation_execution(run; engine = SequentialEngineSpec())
        run_simulation!(execution)
        result = finish_simulation!(execution)

        model = simulation_model(execution)
        @test model_module_count(model) == 5           # barrier, source, queue, server, sink
        @test length(model_delay_edges(model)) == 3
        # The scalars each module derived at the end of the run are in the
        # result, under the module paths they were recorded with.
        scalars = Dict(result.scalars)
        @test scalars[Symbol("Queuing.sink.packets:count")] > 9000
        @test 0.35 <= scalars[Symbol("Queuing.queue.queueLength:timeavg")] <= 0.7
        @test result.network_hash != UInt128(0)

        # The same run again is the same run.
        again = prepare_simulation_execution(
            expand_simulation(configure_simulation(type, assignment))[1];
            engine = SequentialEngineSpec())
        run_simulation!(again)
        @test finish_simulation!(again).network_hash == result.network_hash
    end

    @testset "the model describes itself" begin
        @test !isempty(model_description(QueuingModel))
    end
    # That the catalog offers this model is the umbrella's business, and is
    # tested there: package/inet/test/catalog.jl.
end

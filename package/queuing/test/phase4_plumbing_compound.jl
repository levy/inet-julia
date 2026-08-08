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
using InetQueuing.PacketMarkingModule
using InetQueuing.PacketFilterElement
using InetQueuing.PacketPredicateModule
using InetQueuing.PriorityQueueElement
using InetQueuing.PacketSourceModule
using InetQueuing: QueuingModel
using InetPacket.PacketModule
using OmnetppSimulator.VolatileModule

@testset "plumbing and compound modules" begin

    @testset "a labeler writes what a source did not" begin
        # The source says nothing about its packets; the labeler writes a value
        # every element downstream can read, because it writes the SAME tag a
        # source would have.
        network = Network(:Labeling)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        labeler = add_module!(network, PacketLabelerModule(:labeler,
            PacketLabelerParameters(label = 7)))
        # A filter for the label is how the test reads it back: only packets
        # carrying 7 reach the sink, and every one of them does.
        wants_seven = add_module!(network, PacketFilterModule(:filter,
            PacketFilterParameters(predicate = data_predicate(==, 7))))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, labeler.in)
        connect!(labeler.out, wants_seven.in)
        connect!(wants_seven.out, sink.in)
        run_network!(network; until = 1.0)

        @test labeler.statistics.num_packets == 11
        @test sink.statistics.num_packets == 11
        @test wants_seven.statistics.num_dropped == 0
    end

    @testset "a cloner sends every output its own copy" begin
        network = Network(:Cloning)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        cloner = add_module!(network, PacketClonerModule(:cloner, 3))
        sinks = [add_module!(network, PassivePacketSinkModule(Symbol(:sink, index)))
                 for index in 1:3]
        connect!(source.out, cloner.in)
        for index in 1:3
            connect!(cloner.out[index], sinks[index].in)
        end
        run_network!(network; until = 1.0)

        @test cloner_outputs(cloner) == 3
        @test cloner.statistics.num_packets == 11
        # Two copies per packet: the last output gets the original.
        @test cloner.statistics.num_copies == 22
        @test all(sink -> sink.statistics.num_packets == 11, sinks)
    end

    @testset "a duplicator thickens one stream in place" begin
        network = Network(:Duplicating)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        duplicator = add_module!(network, PacketDuplicatorModule(:duplicator,
            PacketDuplicatorParameters(predicate = ordinal_predicate(n -> n % 2 == 0))))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, duplicator.in)
        connect!(duplicator.out, sink.in)
        run_network!(network; until = 1.0)

        # Eleven packets, every second one sent twice: five duplicates.
        @test duplicator.statistics.num_packets == 11
        @test duplicator.statistics.num_duplicates == 5
        @test sink.statistics.num_packets == 16
    end

    @testset "copies carry their own tags" begin
        # A copy shares its content and gets its own tags, so a labeler after a
        # cloner can mark each branch differently — which would be impossible
        # if the tag sets were shared.
        network = Network(:CopyTags)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.5))
        cloner = add_module!(network, PacketClonerModule(:cloner, 2))
        first_label = add_module!(network, PacketLabelerModule(:first,
            PacketLabelerParameters(label = 1)))
        second_label = add_module!(network, PacketLabelerModule(:second,
            PacketLabelerParameters(label = 2)))
        # Each branch keeps only its OWN label. Shared tag sets would mean the
        # second labeler overwrote the first's work, and one filter would drop
        # everything.
        first_filter = add_module!(network, PacketFilterModule(:first_filter,
            PacketFilterParameters(predicate = data_predicate(==, 1))))
        second_filter = add_module!(network, PacketFilterModule(:second_filter,
            PacketFilterParameters(predicate = data_predicate(==, 2))))
        first_sink = add_module!(network, PassivePacketSinkModule(:sink1))
        second_sink = add_module!(network, PassivePacketSinkModule(:sink2))
        connect!(source.out, cloner.in)
        connect!(cloner.out[1], first_label.in)
        connect!(first_label.out, first_filter.in)
        connect!(first_filter.out, first_sink.in)
        connect!(cloner.out[2], second_label.in)
        connect!(second_label.out, second_filter.in)
        connect!(second_filter.out, second_sink.in)
        run_network!(network; until = 1.0)

        @test first_sink.statistics.num_packets == 3
        @test second_sink.statistics.num_packets == 3
        @test first_filter.statistics.num_dropped == 0
        @test second_filter.statistics.num_dropped == 0
    end

    @testset "a multiplexer merges push chains" begin
        network = Network(:Merge)
        sources = [add_module!(network, ActivePacketSourceModule(Symbol(:source, index);
            production_interval = 0.1 * index))
                   for index in 1:2]
        merge = add_module!(network, PacketMultiplexerModule(:merge, 2))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(sources[1].out, merge.in[1])
        connect!(sources[2].out, merge.in[2])
        connect!(merge.out, sink.in)
        run_network!(network; until = 1.0)

        # Everything both sources made arrives, and the merge counted all of it.
        produced = sum(source -> source.num_packets, sources)
        @test produced == 11 + 6
        @test merge.num_packets == produced
        @test sink.statistics.num_packets == produced
    end

    @testset "a multiplexer passes back pressure to every producer" begin
        network = Network(:MergeSlow)
        sources = [add_module!(network, ActivePacketSourceModule(Symbol(:source, index);
            production_interval = 0.1))
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
        @test sum(source -> source.num_packets, sources) == 9
        @test sources[1].num_packets == 9
        @test sources[2].num_packets == 0
    end

    @testset "a demultiplexer lets several collectors pull" begin
        network = Network(:Split)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
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
        @test source.num_packets == collected + queue_length(queue)
    end

    @testset "a delayer holds each packet" begin
        network = Network(:Delay)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        delayer = add_module!(network, PacketDelayerModule(:delayer,
            PacketDelayerParameters(delay = 0.25)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, delayer.in)
        connect!(delayer.out, sink.in)
        run_network!(network; until = 1.0)

        # Several packets are in flight at once — the delayer holds them, it
        # does not serve them one at a time.
        @test source.num_packets == 11
        @test sink.statistics.num_packets == 8
        @test packets_in_flight(delayer) == 3
        @test sink.statistics.total_life_time == 8 * to_simtime(0.25)
    end

    @testset "a drawn delay reorders packets" begin
        network = Network(:Jitter)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1,
            packet = PacketTemplate(length = Volatile(intuniform(80, 800))),
            seed = 6))
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
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.05,
            packet = PacketTemplate(length = Volatile(intuniform(80, 800))),
            seed = 3))
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
        @test source.num_packets > 0
        @test sink.statistics.num_packets > 0
        @test priority_queue_length(queue) ==
              queue_length(queue.queues[1]) + queue_length(queue.queues[2])
        @test source.num_packets ==
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
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
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

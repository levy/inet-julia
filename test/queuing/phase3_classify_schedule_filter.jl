# Phase 3 of plan/pending/queuing-model-migration.md — the elements that make a
# chain branch: a classifier forking it, a scheduler joining it again, and a
# filter thinning it out.

using Inet.ActivePacketSourceElement
using Inet.PassivePacketSinkElement
using Inet.PacketQueueElement
using Inet.PacketServerElement
using Inet.PacketClassifierElement
using Inet.PacketSchedulerElement
using Inet.PacketFilterElement
using Inet.PacketSourceModule
using Inet.PacketModule
using OmnetppSimulator.VolatileModule

# Two priorities: a classifier fans packets into a queue each, a scheduler
# drains them in order, and one server takes them away. This is a priority
# queue, assembled from the parts rather than built as one.
function priority_chain(; production_interval = 0.1, processing_time = 0.25,
                          classifier = nothing, seed = 1)
    network = Network(:Priority)
    source = add_module!(network, ActivePacketSourceModule(:source,
        ActivePacketSourceParameters(production_interval = production_interval,
            packet = PacketTemplate(length = Volatile(intuniform(80, 800)))); seed = seed))
    fork = add_module!(network, classifier === nothing ?
        priority_classifier(:classifier, 2) : classifier)
    queues = [add_module!(network, PacketQueueModule(Symbol(:queue, index)))
              for index in 1:2]
    join = add_module!(network, priority_scheduler(:scheduler, 2))
    server = add_module!(network, PacketServerModule(:server,
        PacketServerParameters(processing_time = processing_time)))
    sink = add_module!(network, PassivePacketSinkModule(:sink))
    connect!(source.out, fork.in)
    for index in 1:2
        connect!(fork.out[index], queues[index].in)
        connect!(queues[index].out, join.in[index])
    end
    connect!(join.out, server.in)
    connect!(server.out, sink.in)
    (; network, source, fork, queues, join, server, sink)
end

@testset "classifier, scheduler and filter" begin
    @testset "a classifier forks by content" begin
        # Short packets one way, everything else the other.
        is_short = packet -> bits(data_length(packet)) < 400
        chain = priority_chain(classifier =
            content_based_classifier(:classifier, [is_short, _ -> true]))
        run_network!(chain.network; until = 2.0)

        @test classifier_outputs(chain.fork) == 2
        @test chain.fork.statistics.num_packets == chain.source.statistics.num_packets
        # Both outputs were used, and each got only what belongs to it.
        @test all(count -> count > 0, chain.fork.statistics.per_output)
        @test sum(chain.fork.statistics.per_output) == chain.fork.statistics.num_packets
        held = vcat([[queue_packet(queue, i) for i in 1:queue_length(queue)]
                     for queue in chain.queues]...)
        @test all(is_short, [queue_packet(chain.queues[1], i)
                             for i in 1:queue_length(chain.queues[1])])
        @test !any(is_short, [queue_packet(chain.queues[2], i)
                              for i in 1:queue_length(chain.queues[2])])
    end

    @testset "a priority classifier fills the first output that will take it" begin
        network = Network(:Priority)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1)))
        fork = add_module!(network, priority_classifier(:classifier, 2))
        # The first queue holds two packets; after that the classifier has to
        # use the second.
        first = add_module!(network, PacketQueueModule(:first,
            PacketQueueParameters(packet_capacity = 2)))
        second = add_module!(network, PacketQueueModule(:second))
        join = add_module!(network, priority_scheduler(:scheduler, 2))
        server = add_module!(network, PacketServerModule(:server,
            PacketServerParameters(processing_time = 100.0)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, fork.in)
        connect!(fork.out[1], first.in)
        connect!(fork.out[2], second.in)
        connect!(first.out, join.in[1])
        connect!(second.out, join.in[2])
        connect!(join.out, server.in)
        connect!(server.out, sink.in)
        run_network!(network; until = 1.0)

        @test queue_length(first) == 2                  # filled, then passed over
        @test queue_length(second) > 0
        @test fork.statistics.per_output[1] == 3        # two held, one in the server
        @test fork.statistics.per_output[2] == queue_length(second)
    end

    @testset "a priority scheduler drains the first input first" begin
        chain = priority_chain(production_interval = 0.05, processing_time = 0.25)
        run_network!(chain.network; until = 2.0)

        # The classifier prefers the first queue while it will take packets, and
        # a priority queue never has anything waiting behind an empty one: the
        # scheduler empties the first before touching the second.
        @test chain.join.statistics.num_packets == chain.server.statistics.num_packets +
              (chain.server.states.packet === nothing ? 0 : 1)
        @test scheduler_inputs(chain.join) == 2
        @test chain.join.statistics.per_input[1] > 0
        served = sum(chain.join.statistics.per_input)
        @test served == chain.join.statistics.num_packets
    end

    @testset "the scheduler follows its inputs as they fill" begin
        # A server is idle until something arrives, and it is the scheduler that
        # has to pass that news along from whichever queue filled.
        chain = priority_chain(production_interval = 1.0, processing_time = 0.1)
        run_network!(chain.network; until = 5.0)
        @test chain.sink.statistics.num_packets == 5
        # Nothing waits: each packet is served long before the next arrives.
        @test all(queue -> queue_length(queue) == 0, chain.queues)
    end

    @testset "a filter drops what does not match" begin
        network = Network(:Filter)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1,
                packet = PacketTemplate(length = Volatile(intuniform(80, 800)))); seed = 2))
        keep_short = add_module!(network, PacketFilterModule(:filter,
            PacketFilterParameters(predicate = packet -> bits(data_length(packet)) < 400)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, keep_short.in)
        connect!(keep_short.out, sink.in)
        run_network!(network; until = 2.0)

        @test keep_short.statistics.num_passed + keep_short.statistics.num_dropped ==
              source.statistics.num_packets
        @test keep_short.statistics.num_dropped > 0
        @test sink.statistics.num_packets == keep_short.statistics.num_passed
        # Only short packets made it through.
        @test sink.statistics.total_length < 400 * sink.statistics.num_packets
    end

    @testset "a filter with back pressure refuses instead of dropping" begin
        # Back pressure changes the answer to "can you take *this* packet",
        # so it is felt by a peer that asks with a packet in hand. A server
        # does: it will not start serving one it could not deliver.
        function filtered_chain(backpressure)
            network = Network(:Backpressure)
            source = add_module!(network, ActivePacketSourceModule(:source,
                ActivePacketSourceParameters(production_interval = 0.1)))
            queue = add_module!(network, PacketQueueModule(:queue))
            server = add_module!(network, PacketServerModule(:server,
                PacketServerParameters(processing_time = 0.01)))
            filter = add_module!(network, PacketFilterModule(:filter,
                PacketFilterParameters(predicate = _ -> false, backpressure = backpressure)))
            sink = add_module!(network, PassivePacketSinkModule(:sink))
            connect!(source.out, queue.in)
            connect!(queue.out, server.in)
            connect!(server.out, filter.in)
            connect!(filter.out, sink.in)
            run_network!(network; until = 1.0)
            (; source, queue, server, filter, sink)
        end

        # With back pressure the filter never accepts, so the server never
        # starts and everything the source made is still waiting: refusing is
        # not losing.
        refusing = filtered_chain(true)
        @test refusing.source.statistics.num_packets == 11
        @test queue_length(refusing.queue) == 11
        @test refusing.server.statistics.num_packets == 0
        @test refusing.filter.statistics.num_dropped == 0

        # Without it the filter accepts everything and drops what does not
        # match, so the same chain runs dry instead.
        dropping = filtered_chain(false)
        @test queue_length(dropping.queue) == 0
        @test dropping.filter.statistics.num_dropped == dropping.server.statistics.num_packets
        @test dropping.sink.statistics.num_packets == 0
    end

    @testset "a filter passes flow control through" begin
        network = Network(:Through)
        source = add_module!(network, ActivePacketSourceModule(:source,
            ActivePacketSourceParameters(production_interval = 0.1)))
        pass = add_module!(network, PacketFilterModule(:filter,
            PacketFilterParameters(predicate = _ -> true)))
        slow = add_module!(network, PassivePacketSinkModule(:sink,
            PassivePacketSinkParameters(consumption_interval = 0.25)))
        connect!(source.out, pass.in)
        connect!(pass.out, slow.in)
        run_network!(network; until = 1.0)

        # The filter holds nothing, so the sink's rate is what the source ends
        # up producing at — the refusal and the recovery both travel through.
        @test slow.statistics.num_packets == 5
        @test source.statistics.num_packets == 5
        @test pass.statistics.num_dropped == 0
    end

    @testset "what a forked chain records" begin
        chain = priority_chain(production_interval = 0.1, processing_time = 0.3)
        recorder = Recorder()
        run_network!(chain.network; until = 2.0, recorder = recorder)

        @test statistic_scalar(recorder, "Priority.classifier", "packets:count") ==
              chain.fork.statistics.num_packets
        # Each branch is counted separately, so where packets went is visible
        # without reading the queues.
        @test statistic_scalar(recorder, "Priority.classifier", "packets[1]:count") +
              statistic_scalar(recorder, "Priority.classifier", "packets[2]:count") ==
              chain.fork.statistics.num_packets
        @test statistic_scalar(recorder, "Priority.scheduler", "packets:count") ==
              chain.join.statistics.num_packets
        @test !isempty(statistic_samples(recorder, "Priority.queue1", "queueLength"))
    end
end

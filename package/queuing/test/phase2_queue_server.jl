# Phase 2 of plan/pending/queuing-model-migration.md — the queue and the
# servers, and the chain they make with the endpoints: source, queue, server,
# sink. This is the shape most models with a bottleneck in them have.

using InetQueuing.ActivePacketSourceElement
using InetQueuing.PassivePacketSinkElement
using InetQueuing.PacketQueueElement
using InetQueuing.PacketServerElement
using InetQueuing.InstantServerElement
using InetQueuing.PacketSourceModule
using InetPacket.PacketModule
using OmnetppSimulator.VolatileModule

# The canonical chain, as one function so the tests differ only where they mean
# to: packets are produced, wait their turn, are served one at a time, and are
# counted at the end.
function queue_chain(; production_interval, processing_time, packet_capacity = nothing,
                       dropper = nothing, length = Bytes(100), seed = 1)
    network = Network(:Chain)
    source = add_module!(network, ActivePacketSourceModule(:source; production_interval = production_interval,
                                     packet = PacketTemplate(length = length), seed = seed))
    queue = add_module!(network, PacketQueueModule(:queue,
        PacketQueueParameters(packet_capacity = packet_capacity, dropper = dropper)))
    server = add_module!(network, PacketServerModule(:server,
        PacketServerParameters(processing_time = processing_time); seed = seed + 100))
    sink = add_module!(network, PassivePacketSinkModule(:sink))
    connect!(source.out, queue.in)
    connect!(queue.out, server.in)
    connect!(server.out, sink.in)
    (; network, source, queue, server, sink)
end

@testset "queue and server" begin
    @testset "the canonical chain" begin
        chain = queue_chain(production_interval = 0.1, processing_time = 0.04)
        run_network!(chain.network; until = 1.0)

        # Service is faster than production, so nothing queues up for long and
        # everything produced gets through except what is still in the server.
        @test chain.source.num_packets == 11
        @test chain.sink.statistics.num_packets == 10
        @test queue_length(chain.queue) == 0
        # Each packet waited for nothing and spent the service time in the
        # server, so its life is exactly one service time.
        @test chain.sink.statistics.total_life_time == 10 * to_simtime(0.04)
    end

    @testset "a server slower than the source builds a queue" begin
        chain = queue_chain(production_interval = 0.1, processing_time = 0.25)
        run_network!(chain.network; until = 1.0)

        # The server takes them at its own rate and the rest wait: what was
        # produced is either served, in the server, or in the queue.
        @test chain.sink.statistics.num_packets == 4
        @test queue_length(chain.queue) ==
              chain.source.num_packets - chain.sink.statistics.num_packets - 1
        # Waiting time grows, so the average is well above zero.
        @test chain.queue.statistics.total_queueing_time > to_simtime(0.5)
    end

    @testset "a queue with a capacity and no dropper pushes back" begin
        chain = queue_chain(production_interval = 0.1, processing_time = 0.25,
                            packet_capacity = 2)
        run_network!(chain.network; until = 2.0)

        # The queue refuses when it is full, and the source waits rather than
        # losing packets: nothing is dropped, and production is held back to
        # what the server can take.
        @test chain.queue.statistics.num_dropped == 0
        @test queue_length(chain.queue) <= 2
        @test chain.source.num_packets ==
              chain.sink.statistics.num_packets + queue_length(chain.queue) + 1
        # Once full the producer stops, and it is the queue emptying that starts
        # it again — without that it would stall for the rest of the run.
        @test chain.sink.statistics.num_packets >= 7
    end

    @testset "a queue with a dropper loses packets instead" begin
        chain = queue_chain(production_interval = 0.1, processing_time = 0.25,
                            packet_capacity = 2, dropper = drop_at_end)
        run_network!(chain.network; until = 2.0)

        # Now the source runs freely and the queue throws away what does not
        # fit, so everything produced is either delivered, held, or dropped.
        @test chain.source.num_packets == 21
        @test chain.queue.statistics.num_dropped > 0
        @test chain.source.num_packets ==
              chain.sink.statistics.num_packets + queue_length(chain.queue) +
              chain.queue.statistics.num_dropped + 1
    end

    @testset "which packet a full queue drops" begin
        # Drop-tail throws away what has just arrived, so what was already
        # waiting is what eventually gets served.
        tail = queue_chain(production_interval = 0.1, processing_time = 10.0,
                           packet_capacity = 2, dropper = drop_at_end)
        run_network!(tail.network; until = 1.0)
        @test queue_length(tail.queue) == 2
        first_two = [queue_packet(tail.queue, i) for i in 1:2]

        # Drop-head makes room by throwing away the oldest, so a full queue
        # ends up holding the newest packets instead.
        head = queue_chain(production_interval = 0.1, processing_time = 10.0,
                           packet_capacity = 2, dropper = drop_at_begin)
        run_network!(head.network; until = 1.0)
        @test queue_length(head.queue) == 2
        @test tail.queue.statistics.num_dropped == head.queue.statistics.num_dropped
        # Same arrivals, same number dropped, different survivors.
        @test [queue_packet(head.queue, i) for i in 1:2] != first_two
    end

    @testset "the preset queues" begin
        network = Network(:Presets)
        tail = add_module!(network, drop_tail_queue(:tail; packet_capacity = 5))
        head = add_module!(network, drop_head_queue(:head; packet_capacity = 5))
        @test tail.parameters.packet_capacity == 5
        @test tail.parameters.dropper === drop_at_end
        @test head.parameters.dropper === drop_at_begin
    end

    @testset "a comparator keeps the queue sorted" begin
        # Rank short packets ahead of long ones, so the queue is a priority
        # queue over length rather than a first-in-first-out one.
        shortest_first = (a, b) -> data_length(a) < data_length(b)
        network = Network(:Sorted)
        source = add_module!(network, ActivePacketSourceModule(:source; production_interval = 0.1,
                packet = PacketTemplate(length = Volatile(intuniform(80, 8000))), seed = 4))
        queue = add_module!(network, PacketQueueModule(:queue,
            PacketQueueParameters(comparator = shortest_first)))
        server = add_module!(network, PacketServerModule(:server,
            PacketServerParameters(processing_time = 10.0)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, queue.in)
        connect!(queue.out, server.in)
        connect!(server.out, sink.in)
        run_network!(network; until = 1.0)

        held = [data_length(queue_packet(queue, i)) for i in 1:queue_length(queue)]
        @test queue_length(queue) > 2
        @test issorted(held)
    end

    @testset "a server holds one packet at a time" begin
        chain = queue_chain(production_interval = 0.01, processing_time = 0.1)
        run_network!(chain.network; until = 0.5)

        # However fast packets arrive, exactly one is in service and the rest
        # are in the queue.
        @test chain.server.states.packet !== nothing
        @test chain.sink.statistics.num_packets == 5
        # Every served packet took the same fixed time.
        @test chain.server.statistics.total_service_time ==
              chain.server.statistics.num_packets * to_simtime(0.1)
    end

    @testset "service time can depend on packet length" begin
        network = Network(:Bitrate)
        source = add_module!(network, ActivePacketSourceModule(:source; production_interval = 1.0,
                                         packet = PacketTemplate(length = Bytes(125))))
        queue = add_module!(network, PacketQueueModule(:queue))
        # A thousand bits at a thousand bits per second is one second of
        # service, whatever the fixed processing time says.
        server = add_module!(network, PacketServerModule(:server,
            PacketServerParameters(processing_time = 0.0, processing_bitrate = 1000.0)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, queue.in)
        connect!(queue.out, server.in)
        connect!(server.out, sink.in)
        run_network!(network; until = 5.0)

        @test server.statistics.num_packets == 5
        @test server.statistics.total_service_time == 5 * to_simtime(1.0)
    end

    @testset "an instant server takes no time" begin
        network = Network(:Instant)
        source = add_module!(network, ActivePacketSourceModule(:source; production_interval = 0.1))
        queue = add_module!(network, PacketQueueModule(:queue))
        server = add_module!(network, InstantServerModule(:server))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, queue.in)
        connect!(queue.out, server.in)
        connect!(server.out, sink.in)
        run_network!(network; until = 1.0)

        # Nothing waits: every packet crosses the whole chain in the event that
        # produced it, so the queue is never left holding anything.
        @test sink.statistics.num_packets == 11
        @test queue_length(queue) == 0
        @test sink.statistics.total_life_time == SimTime(0)
        @test queue.statistics.total_queueing_time == SimTime(0)
    end

    @testset "what a chain records" begin
        chain = queue_chain(production_interval = 0.1, processing_time = 0.25,
                            packet_capacity = 3, dropper = drop_at_end)
        recorder = Recorder()
        run_network!(chain.network; until = 2.0, recorder = recorder)

        lengths = statistic_samples(recorder, "Chain.queue", "queueLength")
        @test !isempty(lengths)
        @test maximum(sample -> sample[2], lengths) <= 3.0

        queueing = statistic_samples(recorder, "Chain.queue", "queueingTime")
        @test length(queueing) == chain.queue.statistics.num_pulled
        # A packet that arrives at an empty queue with the server idle is pulled
        # straight back out in the same event and waited for nothing.
        @test all(sample -> sample[2] >= 0, queueing)
        @test any(sample -> sample[2] > 0, queueing)

        @test statistic_scalar(recorder, "Chain.queue", "droppedPacketsQueueOverflow:count") ==
              chain.queue.statistics.num_dropped
        # The mean length comes from the integral kept as the queue changed, so
        # it is a time average rather than an average over samples.
        timeavg = statistic_scalar(recorder, "Chain.queue", "queueLength:timeavg")
        @test 0 < timeavg <= 3
        @test statistic_scalar(recorder, "Chain.server", "processingTime:mean") ≈ 0.25
    end

    @testset "an M/M/1 queue behaves like one" begin
        # Arrivals at 5 per second into a server taking 0.1s on average is a
        # utilisation of one half, where the theory says the mean number
        # waiting is rho^2/(1-rho) = 0.5 and the mean wait is 0.1s.
        network = Network(:MM1)
        source = add_module!(network, ActivePacketSourceModule(:source; production_interval = Volatile(exponential(0.2)), seed = 20))
        queue = add_module!(network, PacketQueueModule(:queue))
        server = add_module!(network, PacketServerModule(:server,
            PacketServerParameters(processing_time = Volatile(exponential(0.1))); seed = 21))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect!(source.out, queue.in)
        connect!(queue.out, server.in)
        connect!(server.out, sink.in)
        # A long run is what makes the averages meaningful, and keeping every
        # sample of a long run is what makes it slow: the scalars are derived
        # from the model's own state, so the time series can be left out.
        recorder = Recorder(capture_vectors = false)
        run_network!(network; until = 5000.0, recorder = recorder)

        arrivals = source.num_packets
        @test 23000 <= arrivals <= 27000             # about 5 per second
        mean_queue_length = statistic_scalar(recorder, "MM1.queue", "queueLength:timeavg")
        mean_wait = statistic_scalar(recorder, "MM1.queue", "queueingTime:mean")
        @test 0.35 <= mean_queue_length <= 0.7       # theory: 0.5
        @test 0.07 <= mean_wait <= 0.14              # theory: 0.1
        # Little's law relates the two, and it holds on the measured numbers.
        @test mean_queue_length ≈ (arrivals / 5000.0) * mean_wait rtol = 0.05
    end
end

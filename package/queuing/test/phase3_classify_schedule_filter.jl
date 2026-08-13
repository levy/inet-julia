# Phase 3 of plan/pending/queuing-model-migration.md — the elements that make a
# chain branch: a classifier forking it, a scheduler joining it again, and a
# filter thinning it out.

# Consecutive equal values, as the runs a bursty classifier produces.
function _runs(values)
    runs, current = Vector{Int}[], Int[]
    for value in values
        if isempty(current) || value == current[end]
            push!(current, value)
        else
            push!(runs, current); current = Int[value]
        end
    end
    isempty(current) || push!(runs, current)
    runs
end

using InetQueuing.ActivePacketSourceElement
using InetQueuing.PassivePacketSinkElement
using InetQueuing.PacketQueueElement
using InetQueuing.PacketServerElement
using InetQueuing.PacketClassifierElement
using InetQueuing.PacketSchedulerElement
using InetQueuing.PacketFilterElement
using InetQueuing.PacketSourceModule
using InetQueuing.PacketPredicateModule
using InetPacket.PacketModule
using OmnetppSimulator.VolatileModule

# Two priorities: a classifier fans packets into a queue each, a scheduler
# drains them in order, and one server takes them away. This is a priority
# queue, assembled from the parts rather than built as one.
function priority_chain(; production_interval = 0.1, processing_time = 0.25,
                          classifier = nothing, seed = 1)
    network = Network(:Priority)
    source = add_module!(network, ActivePacketSourceModule(:source;
        production_interval = production_interval,
        packet = PacketTemplate(length = Volatile(intuniform(80, 800))),
        seed = seed))
    fork = add_module!(network, classifier === nothing ?
        priority_classifier(:classifier, 2) : classifier)
    queues = [add_module!(network, PacketQueueModule(Symbol(:queue, index)))
              for index in 1:2]
    join = add_module!(network, priority_scheduler(:scheduler, 2))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = processing_time))
    sink = add_module!(network, PassivePacketSinkModule(:sink))
    connect_gates!(source.out, fork.in)
    for index in 1:2
        connect_gates!(fork.out[index], queues[index].in)
        connect_gates!(queues[index].out, join.in[index])
    end
    connect_gates!(join.out, server.in)
    connect_gates!(server.out, sink.in)
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
        @test chain.fork.num_packets == chain.source.num_packets
        # Both outputs were used, and each got only what belongs to it.
        @test all(count -> count > 0, chain.fork.per_output)
        @test sum(chain.fork.per_output) == chain.fork.num_packets
        held = vcat([[queue_packet(queue, i) for i in 1:queue_length(queue)]
                     for queue in chain.queues]...)
        @test all(is_short, [queue_packet(chain.queues[1], i)
                             for i in 1:queue_length(chain.queues[1])])
        @test !any(is_short, [queue_packet(chain.queues[2], i)
                              for i in 1:queue_length(chain.queues[2])])
    end

    @testset "a priority classifier fills the first output that will take it" begin
        network = Network(:Priority)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        fork = add_module!(network, priority_classifier(:classifier, 2))
        # The first queue holds two packets; after that the classifier has to
        # use the second.
        first = add_module!(network, PacketQueueModule(:first; packet_capacity = 2))
        second = add_module!(network, PacketQueueModule(:second))
        join = add_module!(network, priority_scheduler(:scheduler, 2))
        server = add_module!(network, PacketServerModule(:server; processing_time = 100.0))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, fork.in)
        connect_gates!(fork.out[1], first.in)
        connect_gates!(fork.out[2], second.in)
        connect_gates!(first.out, join.in[1])
        connect_gates!(second.out, join.in[2])
        connect_gates!(join.out, server.in)
        connect_gates!(server.out, sink.in)
        run_network!(network; until = 1.0)

        @test queue_length(first) == 2                  # filled, then passed over
        @test queue_length(second) > 0
        @test fork.per_output[1] == 3        # two held, one in the server
        @test fork.per_output[2] == queue_length(second)
    end

    @testset "a weighted round robin gives each output its share" begin
        # The shares are the point, so the classifier is asked directly: it
        # consults nothing, which is exactly what distinguishes it from the
        # priority one.
        classifier = weighted_round_robin_classifier(:classifier, [3, 1])
        picks = [classifier.classifier(classifier, nothing) for _ in 1:12]
        @test picks == [1, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2]

        # Equal weights are plain round robin.
        plain = weighted_round_robin_classifier(:plain, [1, 1, 1])
        @test [plain.classifier(plain, nothing) for _ in 1:6] == [1, 2, 3, 1, 2, 3]

        # A zero weight means an output that never gets a turn.
        skewed = weighted_round_robin_classifier(:skewed, [2, 0, 1])
        @test [skewed.classifier(skewed, nothing) for _ in 1:6] ==
              [1, 1, 3, 1, 1, 3]

        @test_throws ErrorException weighted_round_robin_classifier(:bad, [1, -1])
        @test_throws ErrorException weighted_round_robin_classifier(:zero, [0, 0])
    end

    @testset "a weighted round robin scheduler skips what is empty" begin
        # Two queues, only the second ever filled: the scheduler must not stall
        # on the first input's turn, or nothing would ever be pulled.
        network = Network(:Wrr)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        first = add_module!(network, PacketQueueModule(:first))
        second = add_module!(network, PacketQueueModule(:second))
        join = add_module!(network, weighted_round_robin_scheduler(:scheduler, [1, 1]))
        server = add_module!(network, PacketServerModule(:server; processing_time = 0.01))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, second.in)          # the FIRST queue is never fed
        connect_gates!(first.out, join.in[1])
        connect_gates!(second.out, join.in[2])
        connect_gates!(join.out, server.in)
        connect_gates!(server.out, sink.in)
        run_network!(network; until = 1.0)

        @test source.num_packets == 11
        # Everything that arrived was pulled — the empty first input never got
        # to hold the second one up. The last packet is still in the server
        # when the run ends, which is why the sink is one short.
        @test queue_length(second) == 0
        # (The counters record COMPLETED work, so the packet the server is
        # holding when the run ends is in neither of them.)
        @test sink.num_packets == 10
    end

    @testset "a Markov classifier walks its states" begin
        # Bursty rather than interleaved: a state that mostly returns to itself
        # sends runs one way before switching. Over many packets the shares
        # approach the chain's stationary distribution — (2/3, 1/3) here.
        classifier = markov_classifier(:classifier, [[0.9, 0.1], [0.2, 0.8]]; seed = 3)
        picks = [classifier.classifier(classifier, nothing) for _ in 1:2000]
        @test all(pick -> pick in (1, 2), picks)
        @test 0.6 <= count(==(1), picks) / length(picks) <= 0.73
        # It really does switch, and it really does run.
        @test 1 in picks && 2 in picks
        @test maximum(length(run) for run in _runs(picks)) >= 5

        # The first packet leaves by the INITIAL state, not the one after it.
        starts_second = markov_classifier(:second, [[0.9, 0.1], [0.2, 0.8]]; initial = 2)
        @test starts_second.classifier(starts_second, nothing) == 2

        @test_throws ErrorException markov_classifier(:ragged, [[1.0], [0.5, 0.5]])
        @test_throws ErrorException markov_classifier(:nostate, [[1.0]]; initial = 2)
    end

    @testset "predicates: comparing what is in a packet" begin
        rng = MersenneTwister(1)
        made(data) = create_packet(PacketTemplate(length = Bytes(10), data = data),
                                   rng, to_simtime(0.0))

        equals_three = data_predicate(==, 3)
        @test !equals_three(made(1))
        @test equals_three(made(3))
        @test !equals_three(made(5))
        # A packet with nothing written on it is a plain no, not an error: a
        # stream where only some packets are labelled is an ordinary thing.
        @test !equals_three(made(nothing))

        @test data_predicate(>=, 3)(made(5))
        @test data_predicate(in, (1, 4, 9))(made(4))
        @test !data_predicate(in, (1, 4, 9))(made(2))
    end

    @testset "predicates: asking which packet this is" begin
        rng = MersenneTwister(1)
        made() = create_packet(PacketTemplate(length = Bytes(10)), rng, to_simtime(0.0))

        every_third = ordinal_predicate(n -> n % 3 == 0)
        @test [every_third(made()) for _ in 1:7] ==
              Bool[false, false, true, false, false, true, false]

        # The count is the predicate's own, so two of them made from one rule
        # count their own streams.
        rule = n -> n % 2 == 0
        first, second = ordinal_predicate(rule), ordinal_predicate(rule)
        @test !first(made())
        @test !second(made())
        @test first(made())
    end

    @testset "predicates: naming one instead of writing it" begin
        rng = MersenneTwister(1)
        made(data) = create_packet(PacketTemplate(length = Bytes(10), data = data),
                                   rng, to_simtime(0.0))

        # A name takes its parameters, so one name covers a family.
        @test packet_predicate(:data_equals, 3)(made(3))
        @test !packet_predicate(:data_equals, 3)(made(4))
        @test packet_predicate(:always)(made(nothing))
        @test !packet_predicate(:never)(made(nothing))

        keeps = packet_predicate(:except_every_nth, 3)
        @test [keeps(made(1)) for _ in 1:6] == Bool[true, true, false, true, true, false]

        @test :data_equals in packet_predicate_names()
        # An unknown name says what it does know.
        @test_throws ErrorException packet_predicate(:no_such_policy)

        # Registering is open: a model may add its own.
        register_packet_predicate!(:test_only_even_data,
                                   () -> (packet -> (d = packet_data(packet);
                                                     d !== nothing && iseven(d))))
        @test packet_predicate(:test_only_even_data)(made(4))
        @test !packet_predicate(:test_only_even_data)(made(3))
    end

    @testset "a priority scheduler drains the first input first" begin
        chain = priority_chain(production_interval = 0.05, processing_time = 0.25)
        run_network!(chain.network; until = 2.0)

        # The classifier prefers the first queue while it will take packets, and
        # a priority queue never has anything waiting behind an empty one: the
        # scheduler empties the first before touching the second.
        @test chain.join.num_packets == chain.server.num_packets +
              (chain.server.packet === nothing ? 0 : 1)
        @test scheduler_inputs(chain.join) == 2
        @test chain.join.per_input[1] > 0
        served = sum(chain.join.per_input)
        @test served == chain.join.num_packets
    end

    @testset "the scheduler follows its inputs as they fill" begin
        # A server is idle until something arrives, and it is the scheduler that
        # has to pass that news along from whichever queue filled.
        chain = priority_chain(production_interval = 1.0, processing_time = 0.1)
        run_network!(chain.network; until = 5.0)
        @test chain.sink.num_packets == 5
        # Nothing waits: each packet is served long before the next arrives.
        @test all(queue -> queue_length(queue) == 0, chain.queues)
    end

    @testset "a filter drops what does not match" begin
        network = Network(:Filter)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1,
            packet = PacketTemplate(length = Volatile(intuniform(80, 800))),
            seed = 2))
        keep_short = add_module!(network, PacketFilterModule(:filter;
            predicate = packet -> bits(data_length(packet)) < 400))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, keep_short.in)
        connect_gates!(keep_short.out, sink.in)
        run_network!(network; until = 2.0)

        @test keep_short.num_passed + keep_short.num_dropped ==
              source.num_packets
        @test keep_short.num_dropped > 0
        @test sink.num_packets == keep_short.num_passed
        # Only short packets made it through.
        @test sink.total_length < 400 * sink.num_packets
    end

    @testset "a filter with back pressure refuses instead of dropping" begin
        # Back pressure changes the answer to "can you take *this* packet",
        # so it is felt by a peer that asks with a packet in hand. A server
        # does: it will not start serving one it could not deliver.
        function filtered_chain(backpressure)
            network = Network(:Backpressure)
            source = add_module!(network, ActivePacketSourceModule(:source;
                production_interval = 0.1))
            queue = add_module!(network, PacketQueueModule(:queue))
            server = add_module!(network, PacketServerModule(:server;
                processing_time = 0.01))
            filter = add_module!(network, PacketFilterModule(:filter;
                predicate = _ -> false,
                backpressure = backpressure))
            sink = add_module!(network, PassivePacketSinkModule(:sink))
            connect_gates!(source.out, queue.in)
            connect_gates!(queue.out, server.in)
            connect_gates!(server.out, filter.in)
            connect_gates!(filter.out, sink.in)
            run_network!(network; until = 1.0)
            (; source, queue, server, filter, sink)
        end

        # With back pressure the filter never accepts, so the server never
        # starts and everything the source made is still waiting: refusing is
        # not losing.
        refusing = filtered_chain(true)
        @test refusing.source.num_packets == 11
        @test queue_length(refusing.queue) == 11
        @test refusing.server.num_packets == 0
        @test refusing.filter.num_dropped == 0

        # Without it the filter accepts everything and drops what does not
        # match, so the same chain runs dry instead.
        dropping = filtered_chain(false)
        @test queue_length(dropping.queue) == 0
        @test dropping.filter.num_dropped == dropping.server.num_packets
        @test dropping.sink.num_packets == 0
    end

    @testset "a filter passes flow control through" begin
        network = Network(:Through)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        pass = add_module!(network, PacketFilterModule(:filter; predicate = _ -> true))
        slow = add_module!(network, PassivePacketSinkModule(:sink;
            consumption_interval = 0.25))
        connect_gates!(source.out, pass.in)
        connect_gates!(pass.out, slow.in)
        run_network!(network; until = 1.0)

        # The filter holds nothing, so the sink's rate is what the source ends
        # up producing at — the refusal and the recovery both travel through.
        @test slow.num_packets == 5
        @test source.num_packets == 5
        @test pass.num_dropped == 0
    end

    @testset "what a forked chain records" begin
        chain = priority_chain(production_interval = 0.1, processing_time = 0.3)
        recorder = Recorder()
        run_network!(chain.network; until = 2.0, recorder = recorder)

        @test statistic_scalar(recorder, "Priority.classifier", "packets:count") ==
              chain.fork.num_packets
        # Each branch is counted separately, so where packets went is visible
        # without reading the queues.
        @test statistic_scalar(recorder, "Priority.classifier", "packets[1]:count") +
              statistic_scalar(recorder, "Priority.classifier", "packets[2]:count") ==
              chain.fork.num_packets
        @test statistic_scalar(recorder, "Priority.scheduler", "packets:count") ==
              chain.join.num_packets
        @test !isempty(statistic_samples(recorder, "Priority.queue1", "queueLength"))
    end
end

# Phase 1 of plan/pending/queuing-model-migration.md — the four endpoint
# elements. Each pairs a driver with a passive peer, once for pushing and once
# for pulling, so this is where the protocol is exercised end to end for the
# first time.

using InetQueuing.ActivePacketSourceElement
using InetQueuing.PassivePacketSourceElement
using InetQueuing.PassivePacketSinkElement
using InetQueuing.ActivePacketSinkElement
using InetQueuing.PacketSourceModule
using InetPacket.PacketModule
using OmnetppSimulator.VolatileModule
using OmnetppSimulator: MersenneTwister, to_simtime

@testset "sources and sinks" begin
    @testset "a source pushes into a sink" begin
        network = Network(:Push)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1,
            packet = PacketTemplate(length = Bytes(100))))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 1.0)

        # The first packet is produced as the run starts and one every interval
        # after that, up to and including the last instant of the run.
        @test source.num_packets == 11
        @test sink.num_packets == 11
        @test sink.total_length == 11 * 800

        # Over an ideal connection the packet crosses inside the producer's own
        # event, so nothing was scheduled to deliver it and no time passed.
        @test sink.total_life_time == SimTime(0)
    end

    @testset "a sink that consumes slowly holds the source back" begin
        network = Network(:BackPressure)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        sink = add_module!(network, PassivePacketSinkModule(:sink;
            consumption_interval = 0.25))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 1.0)

        # The sink refuses for a quarter of a second after each packet, so the
        # pair settles at the sink's rate rather than the source's: production
        # is delayed, not queued up behind the refusal.
        @test sink.num_packets == 5
        @test source.num_packets == sink.num_packets
    end

    @testset "a source writes data on its packets" begin
        # The value a packet carries is what every content-based element
        # downstream reads; a constant is the same on every packet, a Volatile
        # is drawn per packet like the length.
        network = Network(:Data)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1,
            packet = PacketTemplate(length = Bytes(100),
                                    data = 7)))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 0.5)
        @test sink.num_packets == 6

        varied = Network(:VariedData)
        varied_source = add_module!(varied, ActivePacketSourceModule(:source;
            production_interval = 0.1,
            packet = PacketTemplate(length = Bytes(100),
                                    data = Volatile(intuniform(0, 3))),
            seed = 5))
        collector = add_module!(varied, PassivePacketSinkModule(:sink))
        connect_gates!(varied_source.out, collector.in)
        run_network!(varied, until = 2.0)
        @test collector.num_packets == 21

        # A packet with no data says so rather than guessing a default.
        plain = create_packet(PacketTemplate(length = Bytes(100)), MersenneTwister(1),
                              to_simtime(0.0))
        @test packet_data(plain) === nothing
        stamped = create_packet(PacketTemplate(length = Bytes(100), data = 7),
                                MersenneTwister(1), to_simtime(0.0))
        @test packet_data(stamped) == 7
    end

    @testset "a sink pulls from a source" begin
        network = Network(:Pull)
        source = add_module!(network, PassivePacketSourceModule(:source;
            packet = PacketTemplate(length = Bytes(50))))
        sink = add_module!(network, ActivePacketSinkModule(:sink;
            collection_interval = 0.2))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 1.0)

        @test sink.num_packets == 6
        @test source.num_packets == 6
        @test sink.total_length == 6 * 400
    end

    @testset "a source that provides slowly holds the sink back" begin
        network = Network(:SlowProvider)
        source = add_module!(network, PassivePacketSourceModule(:source;
            providing_interval = 0.25))
        sink = add_module!(network, ActivePacketSinkModule(:sink;
            collection_interval = 0.1))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 1.0)

        # The sink asks every tenth of a second and is told no until the source
        # has something again, so the pair runs at the source's rate.
        @test sink.num_packets == 5
        @test source.num_packets == 5
    end

    @testset "looking at the next packet does not take it" begin
        network = Network(:Peek)
        source = add_module!(network, PassivePacketSourceModule(:source))
        sink = add_module!(network, ActivePacketSinkModule(:sink;
            collection_interval = 0.5))
        connect_gates!(source.out, sink.in)
        initialize_network!(network)

        # A collector may look before committing, and gets the same packet when
        # it does commit.
        offered = can_pull_packet(sink.provider)
        @test offered !== nothing
        @test can_pull_packet(sink.provider) === offered
        @test source.num_packets == 0        # looking is not taking
        engine = SequentialEngine(network_module_count(network))
        schedule_root!(engine, to_simtime(0.0), module_id(sink), function (ctx)
            @test pull_packet!(ctx, sink.provider) === offered
        end)
        advance_engine!(engine)
        @test source.num_packets == 1
    end

    @testset "a delayed connection makes delivery an event" begin
        network = Network(:Link)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in; delay = to_simtime(0.05))
        run_network!(network; until = 1.0)

        # Every packet spends the propagation delay in flight, so each arrives
        # one delay after it was made and the last one is still on the wire.
        @test source.num_packets == 11
        @test sink.num_packets == 10
        @test sink.total_life_time == 10 * to_simtime(0.05)
    end

    @testset "packet length can be drawn per packet" begin
        network = Network(:Random)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.1,
            packet = PacketTemplate(length = Volatile(intuniform(80, 800))),
            seed = 7))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 1.0)

        @test sink.num_packets == 11
        # Lengths vary, and every one is inside the range asked for.
        @test sink.total_length != 11 * 80
        @test 11 * 80 <= sink.total_length <= 11 * 800
    end

    @testset "production interval can be drawn per packet" begin
        network = Network(:RandomInterval)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = Volatile(exponential(0.1)),
            seed = 3))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)
        run_network!(network; until = 10.0)

        # Around a hundred packets in ten seconds at a mean interval of 0.1s,
        # and the same seed gives the same run.
        @test 60 <= sink.num_packets <= 140

        again = Network(:RandomInterval)
        source2 = add_module!(again, ActivePacketSourceModule(:source;
            production_interval = Volatile(exponential(0.1)),
            seed = 3))
        sink2 = add_module!(again, PassivePacketSinkModule(:sink))
        connect_gates!(source2.out, sink2.in)
        run_network!(again; until = 10.0)
        @test sink2.num_packets == sink.num_packets
    end

    @testset "a run is reproducible" begin
        function build()
            network = Network(:Hashed)
            source = add_module!(network, ActivePacketSourceModule(:source;
                production_interval = Volatile(exponential(0.1)),
                seed = 11))
            sink = add_module!(network, PassivePacketSinkModule(:sink))
            connect_gates!(source.out, sink.in)
            network
        end
        first_run = run_network!(build(); until = 5.0)
        second_run = run_network!(build(); until = 5.0)
        @test network_hash(first_run) == network_hash(second_run)
        @test total_event_count(first_run) == total_event_count(second_run)

        # A different seed is a different run.
        other = Network(:Hashed)
        source = add_module!(other, ActivePacketSourceModule(:source;
            production_interval = Volatile(exponential(0.1)),
            seed = 12))
        sink = add_module!(other, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)
        @test network_hash(run_network!(other; until = 5.0)) != network_hash(first_run)
    end

    @testset "what a run records" begin
        network = Network(:Recorded)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.25,
            packet = PacketTemplate(length = Bytes(125))))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in; delay = to_simtime(0.01))
        recorder = Recorder()
        run_network!(network; until = 1.0, recorder = recorder)

        # Time series carry a sample per packet, under the module's own path and
        # under the name INET records the same statistic by.
        lengths = statistic_samples(recorder, "Recorded.sink", "packetLengths")
        @test length(lengths) == 4
        @test all(sample -> sample[2] == 1000.0, lengths)
        @test first(lengths)[1] ≈ 0.01

        # Durations are recorded in seconds, as INET records them.
        life_times = statistic_samples(recorder, "Recorded.sink", "packetLifeTime")
        @test all(sample -> sample[2] ≈ 0.01, life_times)

        # Scalars summarise the whole run and are derived at the end of it.
        @test statistic_scalar(recorder, "Recorded.source", "packets:count") == 5
        @test statistic_scalar(recorder, "Recorded.sink", "packets:count") == 4
        @test statistic_scalar(recorder, "Recorded.sink", "packetLengths:sum") == 4000
        @test statistic_scalar(recorder, "Recorded.sink", "packetLifeTime:mean") ≈ 0.01

        # Recording is optional, and a run without it computes the same thing.
        plain = Network(:Recorded)
        source2 = add_module!(plain, ActivePacketSourceModule(:source;
            production_interval = 0.25,
            packet = PacketTemplate(length = Bytes(125))))
        sink2 = add_module!(plain, PassivePacketSinkModule(:sink))
        connect_gates!(source2.out, sink2.in; delay = to_simtime(0.01))
        run_network!(plain; until = 1.0)
        @test sink2.num_packets == 4
    end

    @testset "a network can be run again" begin
        network = Network(:Reset)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = Volatile(exponential(0.1)),
            seed = 5))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)

        first_run = run_network!(network; until = 2.0)
        produced = sink.num_packets
        reset_network!(network)
        @test sink.num_packets == 0
        second_run = run_network!(network; until = 2.0)
        # Reset puts the generators back where they started, so the second run
        # is the first one over again.
        @test sink.num_packets == produced
        @test network_hash(second_run) == network_hash(first_run)
    end

    @testset "a run after a reset still records" begin
        # A generated reset writes every statistic back to what it was
        # declared as, and the recording handle is one of them. That is only
        # safe because a run registers the statistics again — which is what
        # this pins.
        network = Network(:Rerecorded)
        source = add_module!(network, ActivePacketSourceModule(:source;
            production_interval = 0.25,
            packet = PacketTemplate(length = Bytes(125))))
        sink = add_module!(network, PassivePacketSinkModule(:sink))
        connect_gates!(source.out, sink.in)

        first_recorder = Recorder()
        run_network!(network; until = 1.0, recorder = first_recorder)
        @test statistic_scalar(first_recorder, "Rerecorded.sink", "packets:count") == 5

        reset_network!(network)
        second_recorder = Recorder()
        run_network!(network; until = 1.0, recorder = second_recorder)
        @test statistic_scalar(second_recorder, "Rerecorded.sink", "packets:count") == 5
        @test length(statistic_samples(second_recorder, "Rerecorded.sink", "packetLengths")) == 5
    end
end

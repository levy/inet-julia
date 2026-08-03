# ============================================================================
# T1S stats phase 7 — VectorFileReader round-trip.
# ============================================================================
using Test
using Omnetpp

@testset "read own writer output — round trip" begin
    mktempdir() do tmp
        path = joinpath(tmp, "test.vec")
        w = VectorFileWriter(path)
        h_curid = register_vector!(w, "Net.node[0].plca", "curID";
                                   attributes = ["title" => "curID trace"])
        h_delay = register_vector!(w, "Net.node[1].plca", "packetPendingDelay";
                                   attributes = ["unit" => "s"])
        begin_recording!(w, "test-run-42";
                         attributes = ["network" => "MultidropNetwork"])
        # Emit a few samples on each.
        for (t, v) in ((0.0, 0.0), (5e-6, 1.0), (10e-6, 2.0))
            record!(w, h_curid, Omnetpp.to_simtime(t), Omnetpp.vec_fmt(v, 14))
        end
        for (t, v) in ((3e-6, 231.6e-6), (20e-6, 40.0e-6))
            record!(w, h_delay, Omnetpp.to_simtime(t), Omnetpp.vec_fmt(v, 14))
        end
        end_recording!(w)

        # Read it back.
        file = read_vec_file(path)
        @test file.version == 3
        @test file.run_name == "test-run-42"
        @test file.attributes["network"] == "MultidropNetwork"
        @test length(file.vectors) == 2

        v_curid = find_vector(file, "Net.node[0].plca", "curID")
        @test v_curid !== nothing
        @test v_curid.columns === :TV
        @test v_curid.attributes["title"] == "curID trace"
        @test length(v_curid.samples) == 3
        @test v_curid.samples[1].value == 0.0
        @test v_curid.samples[3].value == 2.0
        @test v_curid.samples[3].time ≈ 10e-6 atol = 1e-15

        v_delay = find_vector(file, "Net.node[1].plca", "packetPendingDelay")
        @test v_delay !== nothing
        @test v_delay.attributes["unit"] == "s"
        @test length(v_delay.samples) == 2
        @test v_delay.samples[1].value ≈ 231.6e-6 atol = 1e-12
    end
end

@testset "read an ETV-format vector" begin
    mktempdir() do tmp
        path = joinpath(tmp, "etv.vec")
        w = VectorFileWriter(path)
        h = register_vector!(w, "Net.node[0]", "queueLength";
                             record_event_numbers = true)
        begin_recording!(w, "etv-test")
        record!(w, h, Omnetpp.to_simtime(1e-6), "5.0"; event_number = 42)
        record!(w, h, Omnetpp.to_simtime(2e-6), "7.0"; event_number = 43)
        end_recording!(w)

        file = read_vec_file(path)
        v = find_vector(file, "Net.node[0]", "queueLength")
        @test v.columns === :ETV
        @test v.samples[1].event_number == 42
        @test v.samples[2].event_number == 43
    end
end

@testset "find_vector returns nothing on absent key" begin
    mktempdir() do tmp
        path = joinpath(tmp, "empty.vec")
        w = VectorFileWriter(path)
        begin_recording!(w, "empty")
        end_recording!(w)
        file = read_vec_file(path)
        @test find_vector(file, "Nope", "None") === nothing
    end
end

using Test
using AnalogTuring

@testset "AnalogMemory -- AnalogRegister stores and reads jittered" begin
    set_jitter_ratio!(0.03); enable_jitter!()
    r = AnalogRegister(7.0; label = "test")
    samples = [get_value(r) for _ in 1:1000]
    @test 6.7 < (sum(samples) / length(samples)) < 7.3
    # not all identical
    @test length(unique(round.(samples, digits=6))) > 100
end

@testset "AnalogMemory -- AnalogRegister rejects non-finite" begin
    @test_throws ArgumentError AnalogRegister(NaN)
    r = AnalogRegister(5.0)
    @test_throws ArgumentError set!(r, Inf)
end

@testset "AnalogMemory -- crystalize_register! freezes value" begin
    r = AnalogRegister(7.0)
    crystalize_register!(r)
    for _ in 1:200
        @test get_value(r) == 7.0
    end
end

@testset "AnalogMemory -- crystalized register rejects writes (with warn)" begin
    r = AnalogRegister(7.0)
    crystalize_register!(r)
    set!(r, 999.0)  # warns, no-op
    @test get_value(r) == 7.0
    uncrystalize_register!(r)
    set!(r, 3.0)
    samples = [get_value(r) for _ in 1:200]
    @test 2.7 < (sum(samples) / length(samples)) < 3.3
end

@testset "AnalogMemory -- AnalogAccumulator integrates with decay" begin
    acc = AnalogAccumulator(decay_rate = 0.5)
    accumulate!(acc, 10.0)
    accumulate!(acc, 10.0)
    # First: 0*0.5 + 10 = 10. Second: 10*0.5 + 10 = 15.
    # plus jitter ~3%
    v = value(acc)
    @test 13.5 < v < 16.5
end

@testset "AnalogMemory -- AnalogAccumulator validates" begin
    @test_throws ArgumentError AnalogAccumulator(decay_rate = -0.1)
    @test_throws ArgumentError AnalogAccumulator(decay_rate = 1.1)
    @test_throws ArgumentError AnalogAccumulator(initial = NaN)
    acc = AnalogAccumulator()
    @test_throws ArgumentError accumulate!(acc, NaN)
end

@testset "AnalogMemory -- reset! clears the accumulator" begin
    acc = AnalogAccumulator(decay_rate = 0.0)
    accumulate!(acc, 50.0)
    reset!(acc; to = 0.0)
    @test value(acc) ≈ 0.0 atol = 1e-1
end

@testset "AnalogMemory -- HopfieldCache store and recall" begin
    cache = HopfieldCache(capacity = 8)
    store!(cache, [1.0, 0.0, 0.0], 100.0)
    store!(cache, [0.0, 1.0, 0.0], 200.0)
    store!(cache, [0.0, 0.0, 1.0], 300.0)

    r = recall(cache, [1.0, 0.0, 0.0])
    @test r !== nothing
    val, sim = r
    @test sim ≈ 1.0 atol = 1e-6
    @test 95.0 < val < 105.0  # jitter
end

@testset "AnalogMemory -- HopfieldCache returns nothing on weak similarity" begin
    cache = HopfieldCache(capacity = 4)
    store!(cache, [1.0, 0.0, 0.0], 100.0)
    @test recall(cache, [-1.0, 0.0, 0.0]; min_similarity = 0.5) === nothing
end

@testset "AnalogMemory -- HopfieldCache evicts weakest non-crystalized" begin
    cache = HopfieldCache(capacity = 2)
    store!(cache, [1.0, 0.0], 1.0; initial_strength = 5.0)
    store!(cache, [0.0, 1.0], 2.0; initial_strength = 1.0)
    store!(cache, [1.0, 1.0], 3.0; initial_strength = 1.0)  # evicts the second
    @test length(cache.entries) == 2
    # the strongest one (key=[1,0]) must remain
    found = recall(cache, [1.0, 0.0])
    @test found !== nothing
end

@testset "AnalogMemory -- crystalize threshold locks entries" begin
    cache = HopfieldCache(capacity = 4, crystalize_threshold = 2.0)
    e = store!(cache, [1.0, 0.0], 50.0; initial_strength = 1.0)
    @test e.crystalized == false
    # bump it up via repeated stores
    store!(cache, [1.0, 0.0], 50.0; initial_strength = 1.5)
    @test cache.entries[1].crystalized == true
    # crystalized recall returns exact (no jitter)
    val, _ = recall(cache, [1.0, 0.0])
    @test val == cache.entries[1].value
end

@testset "AnalogMemory -- recall_top_k returns sorted matches" begin
    cache = HopfieldCache(capacity = 8)
    store!(cache, [1.0, 0.0, 0.0], 1.0)
    store!(cache, [0.9, 0.1, 0.0], 2.0)
    store!(cache, [0.0, 1.0, 0.0], 3.0)
    top = recall_top_k(cache, [1.0, 0.0, 0.0], 2; min_similarity = 0.0)
    @test length(top) == 2
    @test top[1][2] >= top[2][2]
end

@testset "AnalogMemory -- HopfieldCache validates inputs" begin
    @test_throws ArgumentError HopfieldCache(capacity = 0)
    @test_throws ArgumentError HopfieldCache(crystalize_threshold = -1)
    @test_throws ArgumentError HopfieldCache(decay_rate = 1.5)
    cache = HopfieldCache()
    @test_throws ArgumentError store!(cache, [NaN, 0.0], 1.0)
    @test_throws ArgumentError store!(cache, [1.0, 0.0], NaN)
    @test_throws ArgumentError store!(cache, [1.0, 0.0], 1.0; initial_strength = -1)
    @test_throws ArgumentError recall(cache, [NaN])
    @test_throws ArgumentError recall(cache, [1.0]; min_similarity = 2.0)
    @test_throws ArgumentError recall_top_k(cache, [1.0], 0)
end

@testset "AnalogMemory -- AmbientField samples within breadth" begin
    field = ambient_field(baseline = 0.1, breadth = 0.5)
    samples = sample_field(field; n = 5000)
    @test all(s > 0 for s in samples)
    @test minimum(samples) >= 0.1 * exp(-0.5) - 1e-9
    @test maximum(samples) <= 0.1 * exp(0.5) + 1e-9
end

@testset "AnalogMemory -- AmbientField validates" begin
    @test_throws ArgumentError ambient_field(baseline = -1.0)
    @test_throws ArgumentError ambient_field(breadth = 0.0)
    @test_throws ArgumentError ambient_field(breadth = -0.5)
    field = ambient_field()
    @test_throws ArgumentError sample_field(field; n = 0)
end

println("✅ AnalogMemory tests complete.")

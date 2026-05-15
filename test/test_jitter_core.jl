using Test
using AnalogTuring

@testset "JitterCore -- constants are pinned" begin
    @test JITTER_RATIO_DEFAULT == 0.03
    @test JITTER_RATIO_MIN == 0.0
    @test JITTER_RATIO_MAX == 0.10
    @test CRYSTALIZE_SENTINEL == -9999.0
end

@testset "JitterCore -- enable/disable toggle" begin
    enable_jitter!()
    @test is_jitter_enabled() == true
    disable_jitter!()
    @test is_jitter_enabled() == false
    enable_jitter!()
    @test is_jitter_enabled() == true
end

@testset "JitterCore -- set_jitter_ratio! validates" begin
    @test_throws ArgumentError set_jitter_ratio!(NaN)
    @test_throws ArgumentError set_jitter_ratio!(Inf)
    @test_throws ArgumentError set_jitter_ratio!(-0.01)
    @test_throws ArgumentError set_jitter_ratio!(0.5)  # above max
    @test set_jitter_ratio!(0.05) == 0.05
    @test get_jitter_ratio() == 0.05
    set_jitter_ratio!(JITTER_RATIO_DEFAULT)  # restore
end

@testset "JitterCore -- jitter_value preserves expected value" begin
    enable_jitter!()
    set_jitter_ratio!(0.05)
    samples = [jitter_value(10.0) for _ in 1:5000]
    @test 9.97 < (sum(samples) / length(samples)) < 10.03   # E[jittered] ≈ x
    # all within bound
    @test all(abs(s - 10.0) <= 0.05 * 10.0 + 1e-9 for s in samples)
end

@testset "JitterCore -- jitter is bounded by ratio" begin
    set_jitter_ratio!(0.03)
    for _ in 1:1000
        out = jitter_value(100.0)
        @test 97.0 <= out <= 103.0
    end
end

@testset "JitterCore -- sentinel passes through unchanged" begin
    for _ in 1:100
        @test jitter_value(CRYSTALIZE_SENTINEL) == CRYSTALIZE_SENTINEL
    end
end

@testset "JitterCore -- zero stays zero" begin
    for _ in 1:100
        @test jitter_value(0.0) == 0.0
    end
end

@testset "JitterCore -- non-finite passes through with warn" begin
    @test isnan(jitter_value(NaN))
    @test isinf(jitter_value(Inf))
end

@testset "JitterCore -- jitter disabled is identity" begin
    disable_jitter!()
    for _ in 1:100
        @test jitter_value(7.5) == 7.5
    end
    enable_jitter!()
end

@testset "JitterCore -- Crystalized wrapper is exempt from jitter" begin
    c = crystalize(5.0)
    @test c isa Crystalized
    @test c.value == 5.0
    for _ in 1:100
        @test jitter_value(c) == 5.0
    end
    @test is_crystalized(c) == true
    @test is_crystalized(5.0) == false
end

@testset "JitterCore -- crystalize is idempotent" begin
    c1 = crystalize(3.0)
    c2 = crystalize(c1)
    @test c1 === c2  # GRUG: double-wrap returns the same object
end

@testset "JitterCore -- AnalogValue construction and basic ops" begin
    a = AnalogValue(2.5)
    @test a.current == 2.5
    @test a.baseline == 2.5
    @test a.crystalized == false
    @test is_crystalized(a) == false
end

@testset "JitterCore -- snap_back validates inputs" begin
    @test_throws ArgumentError snap_back(1.0, 1.0; alpha = -0.1)
    @test_throws ArgumentError snap_back(1.0, 1.0; alpha = 1.1)
    @test_throws ArgumentError snap_back(1.0, 1.0; baseline_jitter = -1e-3)
    new_c, new_b = snap_back(2.0, 1.0; alpha = 0.5, baseline_jitter = 0.0)
    @test new_c == 1.5
    @test new_b == 1.0
end

@testset "JitterCore -- jitter_and_snap is bounded around input" begin
    set_jitter_ratio!(0.05)
    samples = [jitter_and_snap(20.0) for _ in 1:1000]
    @test all(15.0 < s < 25.0 for s in samples)
    # AVERAGE near 20
    @test 19.5 < (sum(samples) / length(samples)) < 20.5
end

@testset "JitterCore -- AnalogValue jitter_and_snap drifts baseline within bounds" begin
    a = AnalogValue(10.0)
    initial_baseline = a.baseline
    for _ in 1:100
        jitter_and_snap(a)
    end
    # Baseline should have drifted but stayed near 10
    @test 9.0 < a.baseline < 11.0
    @test a.jitter_count == 100
end

@testset "JitterCore -- crystalized AnalogValue does not drift" begin
    a = AnalogValue(10.0)
    a.crystalized = true
    for _ in 1:100
        jitter_and_snap(a)
    end
    @test a.current == 10.0
    @test a.baseline == 10.0
    @test a.jitter_count == 0  # crystalized never increments
end

println("✅ JitterCore tests complete.")

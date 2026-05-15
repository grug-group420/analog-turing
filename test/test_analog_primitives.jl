using Test
using AnalogTuring

@testset "AnalogPrimitives -- aadd is approximately correct + jittered" begin
    set_jitter_ratio!(0.03); enable_jitter!()
    samples = [aadd(2.0, 2.0) for _ in 1:1000]
    @test 3.5 < (sum(samples) / length(samples)) < 4.5
    # at most ratio*|x| variance per term, so at most ~6% of 4 = 0.24
    @test all(3.5 < s < 4.5 for s in samples)
    # not all identical
    @test length(unique(round.(samples, digits=6))) > 100
end

@testset "AnalogPrimitives -- crystalize propagates" begin
    # both crystalized → exact
    @test aadd(crystalize(2.0), crystalize(2.0)) == 4.0
    @test asub(crystalize(5.0), crystalize(3.0)) == 2.0
    @test amul(crystalize(2.0), crystalize(3.0)) == 6.0
    @test adiv(crystalize(10.0), crystalize(2.0)) == 5.0

    # one not crystalized → still jitters
    set_jitter_ratio!(0.03)
    samples = [aadd(crystalize(2.0), 2.0) for _ in 1:200]
    @test length(unique(round.(samples, digits=6))) > 50
end

@testset "AnalogPrimitives -- adiv guards against divide-by-zero" begin
    @test_throws DivideError adiv(5.0, 0.0)
    @test_throws DivideError adiv(crystalize(5.0), crystalize(0.0))
end

@testset "AnalogPrimitives -- asqrt rejects negatives" begin
    @test_throws DomainError asqrt(-1.0)
    @test asqrt(crystalize(4.0)) == 2.0
end

@testset "AnalogPrimitives -- alog rejects non-positive" begin
    @test_throws DomainError alog(0.0)
    @test_throws DomainError alog(-1.0)
    @test alog(crystalize(1.0)) == 0.0
end

@testset "AnalogPrimitives -- aabs is non-negative" begin
    set_jitter_ratio!(0.03)
    for x in [-5.0, -0.001, 0.0, 0.5, 100.0]
        for _ in 1:50
            r = aabs(x)
            @test r >= -1e-3   # tiny jitter slack
        end
    end
end

@testset "AnalogPrimitives -- aexp warns on overflow" begin
    # 1000.0 → overflow Inf
    @test isinf(aexp(crystalize(1000.0)))
    @test aexp(crystalize(0.0)) == 1.0
end

@testset "AnalogPrimitives -- crisp comparison is jittered" begin
    set_jitter_ratio!(0.05)
    not_equal_count = 0
    for _ in 1:1000
        if !aeq(1.0, 1.0; tol = 1e-6)
            not_equal_count += 1
        end
    end
    # very small tol with 5% jitter: some realizations should differ
    @test not_equal_count > 0
    # crystalized version is exact-equal
    @test aeq(crystalize(1.0), crystalize(1.0)) == true
end

@testset "AnalogPrimitives -- alt / agt orderings hold under jitter" begin
    set_jitter_ratio!(0.03)
    correct = 0
    for _ in 1:1000
        if alt(1.0, 100.0)
            correct += 1
        end
    end
    @test correct > 990  # well-separated values almost always correct
end

@testset "AnalogPrimitives -- afuzzy_eq returns 1 at zero diff and decays" begin
    # crystalized → no jitter on the comparison values
    @test afuzzy_eq(crystalize(0.0), crystalize(0.0); tol = 1.0) ≈ 1.0 atol=1e-9
    @test afuzzy_eq(crystalize(0.0), crystalize(1.0); tol = 1.0) ≈ exp(-1.0) atol=1e-9
    @test afuzzy_eq(crystalize(0.0), crystalize(10.0); tol = 1.0) < 1e-6
end

@testset "AnalogPrimitives -- afuzzy_lt is symmetric around the boundary" begin
    @test afuzzy_lt(crystalize(0.0), crystalize(0.0)) ≈ 0.5 atol=1e-9
    @test afuzzy_lt(crystalize(0.0), crystalize(10.0)) > 0.99
    @test afuzzy_lt(crystalize(10.0), crystalize(0.0)) < 0.01
end

@testset "AnalogPrimitives -- afuzzy_lt validates tol" begin
    @test_throws ArgumentError afuzzy_lt(0.0, 1.0; tol = 0.0)
    @test_throws ArgumentError afuzzy_lt(0.0, 1.0; tol = -1.0)
end

@testset "AnalogPrimitives -- amin/amax return correct extremes" begin
    set_jitter_ratio!(0.03)
    @test 1.5 < amin(2.0, 5.0) < 2.5
    @test 4.5 < amax(2.0, 5.0) < 5.5
    @test amin(crystalize(2.0), crystalize(5.0)) == 2.0
    @test amax(crystalize(2.0), crystalize(5.0)) == 5.0

    @test_throws ArgumentError amin(Float64[])
    @test_throws ArgumentError amax(Float64[])
end

@testset "AnalogPrimitives -- aclamp constrains within bounds" begin
    set_jitter_ratio!(0.03)
    # within bounds, should pass through with jitter
    samples = [aclamp(5.0, crystalize(0.0), crystalize(10.0)) for _ in 1:500]
    @test all(0.0 <= s <= 10.0 + 0.03 * 10.0 for s in samples)
    # outside, should clamp
    @test aclamp(-100.0, crystalize(0.0), crystalize(10.0)) == 0.0
    @test aclamp(crystalize(100.0), crystalize(0.0), crystalize(10.0)) == 10.0
    # bad bounds
    @test_throws ArgumentError aclamp(5.0, 10.0, 0.0)
end

@testset "AnalogPrimitives -- asum / aprod / amean basic correctness" begin
    @test asum([crystalize(1.0), crystalize(2.0), crystalize(3.0)]) == 6.0
    @test aprod([crystalize(2.0), crystalize(3.0), crystalize(4.0)]) == 24.0
    @test amean([crystalize(2.0), crystalize(4.0), crystalize(6.0)]) == 4.0
    @test asum(Float64[]) == 0.0
    @test aprod(Float64[]) == 1.0
    @test_throws ArgumentError amean(Float64[])
end

@testset "AnalogPrimitives -- aselect picks via fuzzy condition" begin
    n_true = 0
    for _ in 1:5000
        if aselect(0.5, 1.0, 0.0) == 1.0
            n_true += 1
        end
    end
    @test 2200 < n_true < 2800

    # extreme conditions tilted hard
    n_at_high = 0
    for _ in 1:1000
        if aselect(0.99, 1.0, 0.0) == 1.0
            n_at_high += 1
        end
    end
    @test n_at_high > 950
end

@testset "AnalogPrimitives -- aselect validates condition" begin
    @test_throws ArgumentError aselect(NaN, 1.0, 0.0)
    @test_throws ArgumentError aselect(Inf, 1.0, 0.0)
end

println("✅ AnalogPrimitives tests complete.")

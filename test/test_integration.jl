using Test
using AnalogTuring

# GRUG: integration tests prove the modules compose. these are the
# headline demos -- analog factorial, analog fixed-point, analog
# population vote loop, hopfield-cached lookup chain.

@testset "INTEGRATION -- analog factorial via arecurse + amul" begin
    # Factorial with crystalized inputs gives exact result.
    fact = arecurse(crystalize(6.0)) do recurse, n
        n_val = n.value
        if n_val <= 1
            return crystalize(1.0)
        end
        return amul(n, recurse(crystalize(n_val - 1)))
    end
    @test fact == 720.0
end

@testset "INTEGRATION -- Newton's method with jitter still converges" begin
    # Find sqrt(2) via Newton's method:  x_{n+1} = (x_n + 2/x_n) / 2
    set_jitter_ratio!(0.005)  # small jitter for convergence demo
    fp = afixed_point(x -> (x + 2.0 / x) / 2.0, 1.0;
                      tol = 1e-3, stable_for = 5)
    @test abs(fp - sqrt(2)) < 1e-2
end

@testset "INTEGRATION -- analog vote loop with reinforcement" begin
    pop = Population()
    register!(pop, "alpha"; strength = 2.0)
    register!(pop, "beta";  strength = 2.0)
    register!(pop, "gamma"; strength = 2.0)

    # Run 200 turns, reinforce whoever wins; expect runaway dominance to
    # emerge (one bead saturates) thanks to positive feedback.
    for _ in 1:200
        fired = fire!(pop)
        if isempty(fired); continue; end
        winner = vote(pop, fired; sharpness = 2.0)
        if winner !== nothing
            bulk_reinforce!(pop, [winner]; delta = 0.3)
        end
        bulk_decay!(pop; rate = 0.005)
    end
    strengths = Dict(
        "alpha" => AnalogTuring.StrengthField.get_bead(pop, "alpha").strength,
        "beta"  => AnalogTuring.StrengthField.get_bead(pop, "beta").strength,
        "gamma" => AnalogTuring.StrengthField.get_bead(pop, "gamma").strength,
    )
    # at least one should have climbed; spread should be non-trivial
    max_s = maximum(values(strengths))
    min_s = minimum(values(strengths))
    @test max_s >= 4.0
    @test max_s - min_s > 0.5
end

@testset "INTEGRATION -- HopfieldCache as memoization for analog factorial" begin
    cache = HopfieldCache(capacity = 32, crystalize_threshold = 3.0)

    # First pass: compute and cache fact(n) for n=1..6
    for n in 1.0:6.0
        truth = factorial(Int(n))
        store!(cache, [n], Float64(truth); initial_strength = 1.0)
    end
    # Second pass: recall everything back, verify within jitter band
    for n in 1.0:6.0
        r = recall(cache, [n])
        @test r !== nothing
        val, sim = r
        @test sim ≈ 1.0 atol = 1e-6
        truth = factorial(Int(n))
        @test abs(val - truth) <= 0.05 * truth + 1e-3
    end
end

@testset "INTEGRATION -- crystalized invariants survive jitter rampup" begin
    # Build a crystalized constant; jack jitter ratio to max; verify constant
    # still propagates exactly through composed analog ops.
    set_jitter_ratio!(0.10)  # max
    pi_c = crystalize(π)
    e_c  = crystalize(ℯ)
    # exact: π * e
    @test amul(pi_c, e_c) ≈ π * ℯ atol = 1e-12
    # exact: π / e
    @test adiv(pi_c, e_c) ≈ π / ℯ atol = 1e-12
    # exact: sqrt(π)
    @test asqrt(pi_c) ≈ sqrt(π) atol = 1e-12
    # restore
    set_jitter_ratio!(JITTER_RATIO_DEFAULT)
end

@testset "INTEGRATION -- analog control loop with timeout guard" begin
    # Bounded computation that must finish inside the timeout.
    result = awith_timeout(0.5) do
        s = 0.0
        aloop(100) do i
            s = aadd(s, Float64(i))
        end
        return s
    end
    # crystalized-free, so jittered, but should be in the right ballpark
    @test 4900 < result < 5100   # exact would be 5050
end

@testset "INTEGRATION -- aretry recovers transient analog failure" begin
    counter = Ref(0)
    out = aretry(attempts = 5) do _
        counter[] += 1
        # Pretend the first 2 attempts hit a transient analog domain error
        if counter[] < 3
            asqrt(-1.0)   # throws
        end
        return aadd(crystalize(2.0), crystalize(3.0))
    end
    @test out == 5.0
    @test counter[] == 3
end

@testset "INTEGRATION -- ambient field always-on guarantee" begin
    # Even with all weights at 0, the floor leaks selection, no exceptions.
    counts = zeros(Int, 3)
    for _ in 1:3000
        idx = weighted_coinflip([0.0, 0.0, 0.0])
        counts[idx] += 1
    end
    @test sum(counts) == 3000  # never threw
    # roughly uniform because all flat
    @test all(c > 500 for c in counts)
end

println("✅ Integration tests complete.")

using Test
using AnalogTuring

@testset "AnalogControl -- abranch crisp" begin
    @test abranch(() -> true, () -> :left, () -> :right) === :left
    @test abranch(() -> false, () -> :left, () -> :right) === :right
    # cond_fn must return Bool
    @test_throws ArgumentError abranch(() -> 1.0, () -> :a, () -> :b)
end

@testset "AnalogControl -- afuzzy_branch samples by score" begin
    n_left = 0
    for _ in 1:5000
        if afuzzy_branch(0.7, () -> :left, () -> :right) === :left
            n_left += 1
        end
    end
    # ~3500 left
    @test 3200 < n_left < 3800

    @test_throws ArgumentError afuzzy_branch(NaN, () -> :a, () -> :b)
end

@testset "AnalogControl -- astochastic_branch dispatches by weighted coinflip" begin
    counts = Dict(:a => 0, :b => 0, :c => 0)
    branches = [(1.0, () -> :a), (3.0, () -> :b), (6.0, () -> :c)]
    for _ in 1:10000
        s = astochastic_branch(branches)
        counts[s] += 1
    end
    @test counts[:c] > counts[:b] > counts[:a]
    @test counts[:a] > 500
    @test_throws ArgumentError astochastic_branch(Tuple{Float64, Function}[])
end

@testset "AnalogControl -- aloop counts correctly and supports :abreak" begin
    seen = Int[]
    aloop(5) do i
        push!(seen, i)
    end
    @test seen == [1, 2, 3, 4, 5]

    seen2 = Int[]
    aloop(10) do i
        push!(seen2, i)
        if i == 3
            throw(:abreak)
        end
    end
    @test seen2 == [1, 2, 3]

    # negative count rejected
    @test_throws ArgumentError aloop(_ -> nothing, -1)
    # exceeding default cap rejected
    @test_throws ArgumentError aloop(_ -> nothing, 99_999_999)
end

@testset "AnalogControl -- awhile honors max_iterations" begin
    counter = Ref(0)
    @test_throws ErrorException awhile(() -> true, _ -> (counter[] += 1);
                                       max_iterations = 5)
    @test counter[] == 5
end

@testset "AnalogControl -- awhile with proper exit condition" begin
    state = Ref(0)
    awhile(() -> state[] < 10, _ -> (state[] += 1))
    @test state[] == 10
end

@testset "AnalogControl -- auntil_converged finds fixed point of contraction" begin
    # f(x) = x/2 → fixed point at 0
    final, iters = auntil_converged(x -> x / 2, 100.0; tol = 1e-3, stable_for = 3)
    @test abs(final) < 1e-1
    @test iters > 3
end

@testset "AnalogControl -- auntil_converged throws when not converging" begin
    # f(x) = 2x diverges
    @test_throws ErrorException auntil_converged(
        x -> 2x, 1.0; tol = 1e-6, max_iterations = 20)
end

@testset "AnalogControl -- auntil_converged validates inputs" begin
    @test_throws ArgumentError auntil_converged(identity, 1.0; tol = -1)
    @test_throws ArgumentError auntil_converged(identity, 1.0; tol = 0.0)
    @test_throws ArgumentError auntil_converged(identity, 1.0; stable_for = 0)
end

@testset "AnalogControl -- arecurse computes factorial" begin
    fact = arecurse(5) do recurse, n
        n <= 1 ? 1 : n * recurse(n - 1)
    end
    @test fact == 120
end

@testset "AnalogControl -- arecurse honors max_depth" begin
    @test_throws ErrorException arecurse(100; max_depth = 10) do recurse, n
        n <= 0 ? 0 : 1 + recurse(n - 1)
    end
end

@testset "AnalogControl -- afixed_point of cosine" begin
    # cos has a fixed point near 0.7390851332
    fp = afixed_point(cos, 1.0; tol = 1e-4, stable_for = 5)
    @test abs(fp - 0.7390851332) < 1e-2
end

@testset "AnalogControl -- aguard rethrow vs fallback" begin
    @test_throws ErrorException aguard(() -> error("boom"))
    @test aguard(() -> error("boom"); on_error = :fallback, fallback = -1) == -1
    @test_throws ArgumentError aguard(() -> 1; on_error = :ignore)
end

@testset "AnalogControl -- aretry succeeds after transient failures" begin
    counter = Ref(0)
    result = aretry(attempts = 5) do _
        counter[] += 1
        if counter[] < 3
            error("transient")
        end
        return :ok
    end
    @test result == :ok
    @test counter[] == 3
end

@testset "AnalogControl -- aretry rethrows the last error after exhausting" begin
    @test_throws ErrorException aretry(attempts = 2) do _
        error("permanent")
    end
    @test_throws ArgumentError aretry(_ -> 1; attempts = 0)
end

@testset "AnalogControl -- awith_timeout completes fast tasks" begin
    @test awith_timeout(() -> 42, 1.0) == 42
end

@testset "AnalogControl -- awith_timeout validates seconds" begin
    @test_throws ArgumentError awith_timeout(() -> 1, 0.0)
    @test_throws ArgumentError awith_timeout(() -> 1, -1)
    @test_throws ArgumentError awith_timeout(() -> 1, NaN)
end

println("✅ AnalogControl tests complete.")

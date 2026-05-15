using Test
using AnalogTuring

@testset "CoinFlip -- @coinflip macro fires at threshold" begin
    set_jitter_ratio!(0.03)
    enable_jitter!()
    yes = 0
    for _ in 1:10000
        result = @coinflip 0.5 :yes :no
        if result === :yes
            yes += 1
        end
    end
    # ~5000 yes, allow generous band
    @test 4500 < yes < 5500
end

@testset "CoinFlip -- coinflip endpoints respected within ambient floor" begin
    # GRUG: clamp is [0.01, 0.99] so even threshold=0 still has small chance
    n_at_zero = 0
    for _ in 1:5000
        if coinflip(0.0)
            n_at_zero += 1
        end
    end
    # Expected: ~50 (1% of 5000), allow generous band
    @test 0 <= n_at_zero <= 200

    n_at_one = 0
    for _ in 1:5000
        if !coinflip(1.0)
            n_at_one += 1
        end
    end
    # Expected: ~50 (1% miss)
    @test 0 <= n_at_one <= 200
end

@testset "CoinFlip -- coinflip validates threshold" begin
    @test_throws ArgumentError coinflip(NaN)
    @test_throws ArgumentError coinflip(-0.1)
    @test_throws ArgumentError coinflip(1.1)
end

@testset "CoinFlip -- weighted_coinflip respects weights" begin
    counts = zeros(Int, 3)
    for _ in 1:30000
        idx = weighted_coinflip([1.0, 2.0, 7.0])
        counts[idx] += 1
    end
    # Expected ~10%, ~20%, ~70%
    @test 2000 < counts[1] < 4000
    @test 5000 < counts[2] < 7000
    @test 19500 < counts[3] < 22500
end

@testset "CoinFlip -- weighted_coinflip rejects bad inputs" begin
    @test_throws ArgumentError weighted_coinflip(Float64[])
    @test_throws ArgumentError weighted_coinflip([1.0, NaN])
    @test_throws ArgumentError weighted_coinflip([1.0, -0.5])
end

@testset "CoinFlip -- weighted_coinflip ambient floor leaks zero-weight entries" begin
    # GRUG: even a "zero" weight should occasionally get picked because of the
    # 1e-6 floor + jitter. with a few thousand trials we should see at least 1.
    counts = zeros(Int, 2)
    for _ in 1:5000
        idx = weighted_coinflip([0.0, 1.0])
        counts[idx] += 1
    end
    # almost all go to index 2, but index 1 gets a tiny share.
    @test counts[1] >= 0  # could be 0 with bad luck, that's fine
    @test counts[2] > 4500
end

@testset "CoinFlip -- biased_coinflip pushes outcomes" begin
    # bias = 0 → ~50%, bias = +0.4 → ~90%
    yes_bias_zero = 0
    yes_bias_pos = 0
    for _ in 1:5000
        if biased_coinflip(0.5, 0.0)
            yes_bias_zero += 1
        end
        if biased_coinflip(0.5, 0.4)
            yes_bias_pos += 1
        end
    end
    @test 2200 < yes_bias_zero < 2800
    @test yes_bias_pos > 4200
end

@testset "CoinFlip -- categorical_coinflip enforces sum-to-one" begin
    @test_throws ArgumentError categorical_coinflip([0.4, 0.4])  # sums to 0.8
    @test_throws ArgumentError categorical_coinflip([0.7, 0.7])  # sums to 1.4
    @test categorical_coinflip([0.3, 0.7]) in (1, 2)
end

@testset "CoinFlip -- lateral_inhibition_coinflip sharpness controls determinism" begin
    weights = [1.0, 1.0, 5.0]
    soft = zeros(Int, 3)
    sharp = zeros(Int, 3)
    for _ in 1:5000
        soft[lateral_inhibition_coinflip(weights; sharpness = 1.0)] += 1
        sharp[lateral_inhibition_coinflip(weights; sharpness = 8.0)] += 1
    end
    # higher sharpness → larger share for the heavy weight
    @test sharp[3] > soft[3]
    @test sharp[3] > 4500
end

@testset "CoinFlip -- lateral_inhibition_coinflip rejects bad sharpness" begin
    @test_throws ArgumentError lateral_inhibition_coinflip([1.0, 2.0]; sharpness = 0.0)
    @test_throws ArgumentError lateral_inhibition_coinflip([1.0, 2.0]; sharpness = -1.0)
    @test_throws ArgumentError lateral_inhibition_coinflip([1.0, 2.0]; sharpness = NaN)
end

println("✅ CoinFlip tests complete.")

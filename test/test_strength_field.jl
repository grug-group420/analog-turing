using Test
using AnalogTuring

@testset "StrengthField -- StrengthBead clamps strength to [0, CAP]" begin
    b = StrengthBead("a"; strength = 100.0)  # clamps to STRENGTH_CAP
    @test b.strength == STRENGTH_CAP
    b2 = StrengthBead("b"; strength = -5.0)
    @test b2.strength == STRENGTH_FLOOR
    @test_throws ArgumentError StrengthBead("c"; strength = NaN)
end

@testset "StrengthField -- bump_strength! climbs toward cap" begin
    b = StrengthBead("a"; strength = 1.0)
    for _ in 1:50
        bump_strength!(b; delta = 0.5)
    end
    @test b.strength == STRENGTH_CAP   # saturates
end

@testset "StrengthField -- decay_strength! grave transition" begin
    b = StrengthBead("a"; strength = 0.05)
    decay_strength!(b; rate = 0.99)
    @test b.is_grave == true
    # graved bead won't bump
    bump_strength!(b; delta = 5.0)
    @test b.strength <= STRENGTH_FLOOR + 1e-3
end

@testset "StrengthField -- crystalized bead ignores bump and decay" begin
    b = StrengthBead("a"; strength = 5.0, crystalized = true)
    bump_strength!(b; delta = 100.0)
    @test b.strength == 5.0
    decay_strength!(b; rate = 1.0)
    @test b.strength == 5.0
end

@testset "StrengthField -- bump_strength! validates" begin
    b = StrengthBead("a"; strength = 5.0)
    @test_throws ArgumentError bump_strength!(b; delta = NaN)
end

@testset "StrengthField -- decay_strength! validates rate" begin
    b = StrengthBead("a"; strength = 5.0)
    @test_throws ArgumentError decay_strength!(b; rate = -0.1)
    @test_throws ArgumentError decay_strength!(b; rate = 1.5)
end

@testset "StrengthField -- Population register and lookup" begin
    pop = Population()
    register!(pop, "a"; strength = 3.0)
    register!(pop, "b"; strength = 8.0)
    @test alive_count(pop) == 2
    b = AnalogTuring.StrengthField.get_bead(pop, "a")
    @test b !== nothing && b.strength == 3.0
end

@testset "StrengthField -- fire! samples by strength" begin
    pop = Population()
    register!(pop, "weak"; strength = 0.5)
    register!(pop, "strong"; strength = 9.0)
    weak_fires = 0
    strong_fires = 0
    for _ in 1:300
        fired = fire!(pop)
        if "weak" in fired; weak_fires += 1; end
        if "strong" in fired; strong_fires += 1; end
    end
    @test strong_fires > weak_fires
end

@testset "StrengthField -- vote returns one of the fired ids" begin
    pop = Population()
    register!(pop, "a"; strength = 5.0)
    register!(pop, "b"; strength = 5.0)
    fired = fire!(pop)
    if !isempty(fired)
        winner = vote(pop, fired)
        @test winner in fired
    end
    @test vote(pop, String[]) === nothing
end

@testset "StrengthField -- winner_take_all picks strongest most often" begin
    pop = Population()
    register!(pop, "a"; strength = 1.0)
    register!(pop, "b"; strength = 9.0)
    counts = Dict("a" => 0, "b" => 0)
    for _ in 1:500
        w = winner_take_all(pop; sharpness = 4.0)
        if w !== nothing
            counts[w] += 1
        end
    end
    @test counts["b"] > counts["a"]
    @test counts["b"] > 400
end

@testset "StrengthField -- crystalized beads always fire" begin
    pop = Population()
    register!(pop, "x"; strength = 0.0, crystalized = true)
    fired = fire!(pop)
    @test "x" in fired
    fired2 = fire!(pop)
    @test "x" in fired2
end

@testset "StrengthField -- bulk_decay! and bulk_reinforce!" begin
    pop = Population()
    register!(pop, "a"; strength = 5.0)
    register!(pop, "b"; strength = 5.0)
    bulk_decay!(pop; rate = 0.5)
    @test AnalogTuring.StrengthField.get_bead(pop, "a").strength <= 2.6
    bulk_reinforce!(pop, ["a"]; delta = 1.0)
    @test AnalogTuring.StrengthField.get_bead(pop, "a").strength >= 3.0
end

@testset "StrengthField -- vote with sharpness > 1 favors loud" begin
    pop = Population()
    register!(pop, "a"; strength = 1.0)
    register!(pop, "b"; strength = 9.0)
    counts = Dict("a" => 0, "b" => 0)
    for _ in 1:500
        w = vote(pop, ["a", "b"]; sharpness = 6.0)
        if w !== nothing
            counts[w] += 1
        end
    end
    @test counts["b"] > 400
end

println("✅ StrengthField tests complete.")

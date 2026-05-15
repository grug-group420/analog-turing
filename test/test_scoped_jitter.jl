using Test
using AnalogTuring
using Random

# ============================================================================
# Scoped Jitter Control Tests
#
# GRUG: tests for new public API:
#   - with_jitter(ratio_or_bool) do ... end     (block-scoped override)
#   - @no_jitter expr                            (zero jitter for one expression)
#   - @with_jitter ratio expr                    (custom ratio for one expression)
#   - crystalize!(::AnalogAccumulator)           (per-instance freeze)
#   - crystalize!(::HopfieldCache)               (per-instance freeze)
#   - crystalize!(::AmbientField)                (per-instance freeze)
#   - crystalize!(::Population; cascade=true)    (population freeze + cascade)
# ============================================================================

@testset "Scoped Jitter Control" begin

    # ------------------------------------------------------------------
    # with_jitter block-scoped override
    # ------------------------------------------------------------------
    @testset "with_jitter(false): zeros jitter inside the block" begin
        # Force a high baseline so we can detect jitter clearly.
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            x = 1.0
            # Outside the block: jitter should perturb the value.
            outside_changed = false
            for _ in 1:50
                if jitter_value(x) != x
                    outside_changed = true
                    break
                end
            end
            @test outside_changed

            # Inside with_jitter(false): no perturbation, ever.
            with_jitter(false) do
                @test get_jitter_ratio() == 0.0
                @test !is_jitter_enabled()
                for _ in 1:200
                    @test jitter_value(x) == x
                end
            end

            # After the block: original ratio restored.
            @test get_jitter_ratio() == 0.05
            @test is_jitter_enabled()
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "with_jitter(0.001): uses smaller ratio inside the block" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            with_jitter(0.001) do
                @test get_jitter_ratio() ≈ 0.001
                @test is_jitter_enabled()
                # All samples should land within tight tolerance.
                x = 100.0
                for _ in 1:500
                    @test abs(jitter_value(x) - x) <= 0.001 * abs(x) + 1e-9
                end
            end
            @test get_jitter_ratio() == 0.05
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "with_jitter(true): uses current global ratio" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.02)
        try
            with_jitter(true) do
                @test get_jitter_ratio() ≈ 0.02
                @test is_jitter_enabled()
            end
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "with_jitter nesting restores to outer scope, not global" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            with_jitter(0.01) do
                @test get_jitter_ratio() ≈ 0.01
                with_jitter(0.0001) do
                    @test get_jitter_ratio() ≈ 0.0001
                end
                # Should restore to OUTER scope (0.01), not global (0.05).
                @test get_jitter_ratio() ≈ 0.01
            end
            # Should restore to global.
            @test get_jitter_ratio() == 0.05
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "with_jitter restores override even when block throws" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            @test_throws ErrorException with_jitter(false) do
                error("boom")
            end
            # Override must be cleared even though the block threw.
            @test get_jitter_ratio() == 0.05
            @test is_jitter_enabled()
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "with_jitter validates input ratio" begin
        @test_throws ArgumentError with_jitter(-0.1) do; nothing; end
        @test_throws ArgumentError with_jitter(NaN) do; nothing; end
        @test_throws ArgumentError with_jitter(Inf) do; nothing; end
        @test_throws ArgumentError with_jitter(JITTER_RATIO_MAX + 1.0) do; nothing; end
        @test_throws ArgumentError with_jitter("nope") do; nothing; end
    end

    @testset "with_jitter override is task-local (concurrent isolation)" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            results = Channel{Float64}(2)
            t1 = @async with_jitter(0.001) do
                sleep(0.05)
                put!(results, get_jitter_ratio())
            end
            t2 = @async with_jitter(0.02) do
                sleep(0.05)
                put!(results, get_jitter_ratio())
            end
            wait(t1); wait(t2)
            close(results)
            collected = sort(collect(results))
            @test collected ≈ [0.001, 0.02]
            # Main task untouched.
            @test get_jitter_ratio() == 0.05
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    # ------------------------------------------------------------------
    # @no_jitter / @with_jitter macros
    # ------------------------------------------------------------------
    @testset "@no_jitter zeros jitter for one expression" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            x = 42.0
            results = @no_jitter [jitter_value(x) for _ in 1:100]
            @test all(r -> r == x, results)
            @test get_jitter_ratio() == 0.05
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "@with_jitter ratio uses custom ratio for one expression" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            r_inside = @with_jitter 0.0005 get_jitter_ratio()
            @test r_inside ≈ 0.0005
            @test get_jitter_ratio() == 0.05
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    @testset "@no_jitter restores even when expression throws" begin
        enable_jitter!()
        prev_ratio = get_jitter_ratio()
        set_jitter_ratio!(0.05)
        try
            @test_throws ErrorException (@no_jitter error("boom"))
            @test get_jitter_ratio() == 0.05
        finally
            set_jitter_ratio!(prev_ratio)
        end
    end

    # ------------------------------------------------------------------
    # crystalize!(::AnalogAccumulator)
    # ------------------------------------------------------------------
    @testset "crystalize!(AnalogAccumulator) freezes value/decay" begin
        enable_jitter!()
        set_jitter_ratio!(0.05)
        acc = AnalogAccumulator()
        accumulate!(acc, 1.0)
        accumulate!(acc, 1.0)
        v_before = value(acc)

        @test !is_crystalized(acc)
        crystalize!(acc)
        @test is_crystalized(acc)

        # Value reads should be exact: many calls return identical value.
        readings = [value(acc) for _ in 1:200]
        @test all(r -> r == readings[1], readings)

        # decay! should be a no-op while crystalized.
        v_pre_decay = value(acc)
        decay!(acc)
        @test value(acc) == v_pre_decay

        # accumulate! should also be a no-op while crystalized.
        accumulate!(acc, 100.0)
        @test value(acc) == v_pre_decay

        # Uncrystalize restores normal behavior.
        uncrystalize!(acc)
        @test !is_crystalized(acc)
        accumulate!(acc, 1.0)
        @test value(acc) != v_pre_decay
    end

    # ------------------------------------------------------------------
    # crystalize!(::HopfieldCache)
    # ------------------------------------------------------------------
    @testset "crystalize!(HopfieldCache) makes recall exact and blocks decay" begin
        enable_jitter!()
        set_jitter_ratio!(0.05)
        cache = HopfieldCache(; capacity = 16)
        store!(cache, [1.0, 0.0, 0.0], 7.5)
        store!(cache, [0.0, 1.0, 0.0], 9.25)

        @test !is_crystalized(cache)
        crystalize!(cache)
        @test is_crystalized(cache)

        # Recall results should be byte-identical across many calls.
        results = Float64[]
        for _ in 1:200
            r = recall(cache, [1.0, 0.0, 0.0]; min_similarity = 0.0)
            @test r !== nothing
            push!(results, r[1])
        end
        @test all(r -> r == results[1], results)
        @test results[1] == 7.5  # exact, no jitter applied

        # decay_all! should be a no-op while crystalized.
        decay_all!(cache)
        r2 = recall(cache, [1.0, 0.0, 0.0]; min_similarity = 0.0)
        @test r2 !== nothing && r2[1] == 7.5

        # Uncrystalize: normal jitter resumes.
        uncrystalize!(cache)
        @test !is_crystalized(cache)
    end

    # ------------------------------------------------------------------
    # crystalize!(::AmbientField)
    # ------------------------------------------------------------------
    @testset "crystalize!(AmbientField) makes sample_field deterministic" begin
        enable_jitter!()
        set_jitter_ratio!(0.05)
        field = AmbientField(; baseline = 0.1, breadth = 0.5)

        @test !is_crystalized(field)
        crystalize!(field)
        @test is_crystalized(field)

        # All samples should equal the baseline, exactly.
        samples = sample_field(field; n = 1000)
        @test all(s -> s == 0.1, samples)

        uncrystalize!(field)
        @test !is_crystalized(field)
        # Now samples should vary at least once across many draws.
        samples2 = sample_field(field; n = 1000)
        @test any(s -> s != 0.1, samples2)
    end

    # ------------------------------------------------------------------
    # crystalize!(::Population)
    # ------------------------------------------------------------------
    @testset "crystalize!(Population; cascade=true) freezes population + beads" begin
        pop = Population()
        register!(pop, "a"; strength = 5.0)
        register!(pop, "b"; strength = 6.0)

        @test !is_crystalized(pop)
        crystalize!(pop)  # default cascade=true
        @test is_crystalized(pop)

        # Every bead should also be crystalized.
        @test is_crystalized(get_bead(pop, "a"))
        @test is_crystalized(get_bead(pop, "b"))

        # bulk_decay! / bulk_reinforce! should be no-ops.
        s_a_before = get_bead(pop, "a").strength
        bulk_decay!(pop; rate = 0.5)
        @test get_bead(pop, "a").strength == s_a_before
        bulk_reinforce!(pop, ["a", "b"]; delta = 0.5)
        @test get_bead(pop, "a").strength == s_a_before

        # Per-bead bump should also no-op (because the bead is crystalized).
        bump_strength!(get_bead(pop, "a"); delta = 1.0)
        @test get_bead(pop, "a").strength == s_a_before

        uncrystalize!(pop)  # default cascade=true
        @test !is_crystalized(pop)
        @test !is_crystalized(get_bead(pop, "a"))
        @test !is_crystalized(get_bead(pop, "b"))
    end

    @testset "crystalize!(Population; cascade=false) freezes only the population" begin
        pop = Population()
        register!(pop, "a"; strength = 5.0)
        register!(pop, "b"; strength = 6.0)

        crystalize!(pop; cascade = false)
        @test is_crystalized(pop)
        # Beads themselves NOT crystalized.
        @test !is_crystalized(get_bead(pop, "a"))
        @test !is_crystalized(get_bead(pop, "b"))

        # Bulk ops are still blocked by population flag.
        s_a_before = get_bead(pop, "a").strength
        bulk_decay!(pop; rate = 0.5)
        @test get_bead(pop, "a").strength == s_a_before

        # But individual bumps still work because the bead is not crystalized.
        bump_strength!(get_bead(pop, "a"); delta = 0.1)
        @test get_bead(pop, "a").strength != s_a_before

        uncrystalize!(pop; cascade = false)
        @test !is_crystalized(pop)
    end

    # ------------------------------------------------------------------
    # Integration: with_jitter composes with per-instance crystalize
    # ------------------------------------------------------------------
    @testset "with_jitter inside, instance crystalize outside still works" begin
        enable_jitter!()
        set_jitter_ratio!(0.05)
        acc = AnalogAccumulator()
        accumulate!(acc, 5.0)
        crystalize!(acc)
        v = value(acc)
        # Either freeze mechanism alone should suffice.
        with_jitter(0.05) do  # max jitter, but accumulator is crystalized
            for _ in 1:100
                @test value(acc) == v
            end
        end
        @no_jitter for _ in 1:50
            @test value(acc) == v
        end
        uncrystalize!(acc)
    end

    # ------------------------------------------------------------------
    # with_jitter affects fresh non-crystalized instances mid-operation
    # ------------------------------------------------------------------
    @testset "with_jitter(false) makes fresh accumulator reads exact" begin
        enable_jitter!()
        set_jitter_ratio!(0.05)
        acc = AnalogAccumulator()
        accumulate!(acc, 3.0)
        accumulate!(acc, 4.0)
        with_jitter(false) do
            v0 = value(acc)
            for _ in 1:200
                @test value(acc) == v0
            end
        end
    end

end

println("✅ Scoped Jitter Control tests complete.")

# GRUG: this module is the cave-thinking part. how rock decide what to do.
# branch (this-or-that). loop (do many times). recurse (rock call self).
# every choice has wiggle so deterministic-tie no starve quiet rock.
# Turing-complete: with branch + loop + state you can compute anything
# computable. analog flavor means every step also exposes graceful
# fall-throughs and bounded iteration counts to prevent infinite-shake.

module AnalogControl

using ..JitterCore: jitter_and_snap, get_jitter_ratio, is_jitter_enabled,
                    Crystalized, AnalogValue, is_crystalized,
                    CRYSTALIZE_SENTINEL
using ..CoinFlip: coinflip, weighted_coinflip, biased_coinflip
using ..AnalogPrimitives: aeq, alt, agt, afuzzy_eq, afuzzy_gt, _raw,
                          aselect

export abranch, afuzzy_branch, astochastic_branch
export aloop, awhile, auntil_converged
export arecurse, afixed_point
export aguard, aretry, awith_timeout
export MAX_ITERATIONS_DEFAULT, CONVERGENCE_TOL_DEFAULT

# GRUG: hard cap on loops so cave-brain not stuck shaking forever.
# every loop function take this as override-able kwarg.
const MAX_ITERATIONS_DEFAULT = 10_000
const CONVERGENCE_TOL_DEFAULT = 1e-6

# ============================================================================
# BRANCHING
# ============================================================================

"""
    abranch(cond_fn, true_fn, false_fn) -> result

GRUG: cond_fn give Bool. if true, do true_fn. else do false_fn.
this is plain branch but functions wrap so caller pass thunks not
already-evaluated. helps with lazy-cave-brain.
"""
function abranch(cond_fn::Function, true_fn::Function, false_fn::Function)
    cond = cond_fn()
    if !(cond isa Bool)
        throw(ArgumentError("AnalogControl.abranch: cond_fn must return Bool, got $(typeof(cond))"))
    end
    return cond ? true_fn() : false_fn()
end

"""
    afuzzy_branch(cond_score::Real, true_fn, false_fn) -> result

GRUG: cond_score is fuzzy in [0,1]. high score lean true_fn but
not certain. coinflip biased by score decides. this is the
analog soft-branch.
"""
function afuzzy_branch(cond_score::Real, true_fn::Function, false_fn::Function)
    if !isfinite(cond_score)
        throw(ArgumentError("AnalogControl.afuzzy_branch: non-finite cond_score $cond_score"))
    end
    p = clamp(Float64(cond_score), 0.0, 1.0)
    return coinflip(p) ? true_fn() : false_fn()
end

"""
    astochastic_branch(branches::Vector{<:Tuple{<:Real, <:Function}}) -> result

GRUG: many branch options each with weight. weighted coinflip pick which
one fire. this is the cave-vote-pool branch.
"""
function astochastic_branch(branches::AbstractVector{<:Tuple{<:Real, <:Function}})
    if isempty(branches)
        throw(ArgumentError("AnalogControl.astochastic_branch: empty branch list"))
    end
    weights = [Float64(b[1]) for b in branches]
    fns = [b[2] for b in branches]
    idx = weighted_coinflip(weights)
    return fns[idx]()
end

# ============================================================================
# LOOPING
# ============================================================================

"""
    aloop(body_fn, n; max_iterations=MAX_ITERATIONS_DEFAULT) -> last_result

GRUG: do body_fn n times. body_fn called with current iteration number
(1-indexed). if n bigger than max_iterations, YELL. body can throw
an :abreak signal via throw(:abreak) to early-exit cleanly.
"""
function aloop(body_fn::Function, n::Integer;
               max_iterations::Integer = MAX_ITERATIONS_DEFAULT)
    if n < 0
        throw(ArgumentError("AnalogControl.aloop: negative count $n"))
    end
    if n > max_iterations
        throw(ArgumentError(
            "AnalogControl.aloop: count $n exceeds max_iterations $max_iterations -- " *
            "raise the cap explicitly if you really mean it"))
    end
    last = nothing
    for i in 1:n
        try
            last = body_fn(i)
        catch e
            if e === :abreak
                # GRUG: clean cave-break. no shame.
                break
            end
            rethrow()
        end
    end
    return last
end

"""
    awhile(cond_fn, body_fn; max_iterations=MAX_ITERATIONS_DEFAULT) -> last_result

GRUG: while cond_fn true, do body_fn. but every check shake the cond.
hard cap on iterations so we no shake forever. exceeding cap YELL.
"""
function awhile(cond_fn::Function, body_fn::Function;
                max_iterations::Integer = MAX_ITERATIONS_DEFAULT)
    last = nothing
    iter = 0
    while true
        iter += 1
        if iter > max_iterations
            throw(ErrorException(
                "AnalogControl.awhile: exceeded max_iterations $max_iterations -- " *
                "loop guard tripped, possible infinite jitter-loop"))
        end
        cond = cond_fn()
        if !(cond isa Bool)
            throw(ArgumentError(
                "AnalogControl.awhile: cond_fn must return Bool, got $(typeof(cond))"))
        end
        cond || break
        try
            last = body_fn(iter)
        catch e
            if e === :abreak
                break
            end
            rethrow()
        end
    end
    return last
end

"""
    auntil_converged(step_fn, initial; tol=CONVERGENCE_TOL_DEFAULT,
                     max_iterations=MAX_ITERATIONS_DEFAULT,
                     stable_for=3) -> (final_value, iterations)

GRUG: keep applying step_fn(prev) -> next until next-and-prev are
"close enough" for stable_for cycles in a row (stable_for prevents a
single jitter-fluke from terminating early). returns final value and
how many turns it took. throws if no convergence in max_iterations.
"""
function auntil_converged(step_fn::Function, initial::Real;
                          tol::Real = CONVERGENCE_TOL_DEFAULT,
                          max_iterations::Integer = MAX_ITERATIONS_DEFAULT,
                          stable_for::Integer = 3)
    if !isfinite(tol) || tol <= 0
        throw(ArgumentError("AnalogControl.auntil_converged: tol $tol must be positive finite"))
    end
    if stable_for < 1
        throw(ArgumentError("AnalogControl.auntil_converged: stable_for must be >= 1"))
    end
    prev = Float64(initial)
    stable_count = 0
    for iter in 1:max_iterations
        nextv = Float64(step_fn(prev))
        if !isfinite(nextv)
            throw(ErrorException(
                "AnalogControl.auntil_converged: step_fn returned non-finite at iter $iter"))
        end
        if abs(nextv - prev) <= tol
            stable_count += 1
            if stable_count >= stable_for
                return nextv, iter
            end
        else
            stable_count = 0
        end
        prev = nextv
    end
    throw(ErrorException(
        "AnalogControl.auntil_converged: did not converge within $max_iterations iterations " *
        "(tol=$tol, stable_for=$stable_for)"))
end

# ============================================================================
# RECURSION
# ============================================================================

"""
    arecurse(self_fn, args...; max_depth=64) -> result

GRUG: recursive function caller with depth-cap. self_fn is a function
that takes (recurse_callback, args...) and can call recurse_callback
to recurse. depth-cap prevent stack-blowout.
"""
function arecurse(self_fn::Function, args...; max_depth::Integer = 64)
    depth_ref = Ref{Int}(0)
    local recurse
    recurse = function (next_args...)
        depth_ref[] += 1
        if depth_ref[] > max_depth
            throw(ErrorException(
                "AnalogControl.arecurse: depth $(depth_ref[]) exceeds max_depth $max_depth"))
        end
        try
            return self_fn(recurse, next_args...)
        finally
            depth_ref[] -= 1
        end
    end
    return self_fn(recurse, args...)
end

"""
    afixed_point(f, x0; tol=CONVERGENCE_TOL_DEFAULT,
                 max_iterations=MAX_ITERATIONS_DEFAULT, stable_for=3) -> Real

GRUG: keep doing x = f(x) until x stop moving. analog fixed-point.
this is sister to auntil_converged but specifically for finding the
attractor of a map. returns just the final value (no iteration count).
"""
function afixed_point(f::Function, x0::Real;
                      tol::Real = CONVERGENCE_TOL_DEFAULT,
                      max_iterations::Integer = MAX_ITERATIONS_DEFAULT,
                      stable_for::Integer = 3)
    final, _ = auntil_converged(f, x0; tol = tol,
                                 max_iterations = max_iterations,
                                 stable_for = stable_for)
    return final
end

# ============================================================================
# GUARDED EXECUTION -- error-handling helpers (no silent fail)
# ============================================================================

"""
    aguard(body_fn; on_error=:rethrow, fallback=nothing,
           label="aguard") -> result

GRUG: run body_fn. if it throw, either rethrow (loud) or return fallback
AFTER warning loud. NEVER silent. on_error must be :rethrow or :fallback.
"""
function aguard(body_fn::Function; on_error::Symbol = :rethrow,
                fallback = nothing, label::String = "aguard")
    if on_error !== :rethrow && on_error !== :fallback
        throw(ArgumentError(
            "AnalogControl.aguard: on_error must be :rethrow or :fallback, got :$on_error"))
    end
    try
        return body_fn()
    catch e
        if on_error === :rethrow
            @warn "AnalogControl.$label: error caught, rethrowing" exception=(e, catch_backtrace())
            rethrow()
        else
            @warn "AnalogControl.$label: error caught, returning fallback" exception=(e, catch_backtrace()) fallback=fallback
            return fallback
        end
    end
end

"""
    aretry(body_fn; attempts=3, backoff_fn=identity) -> result

GRUG: try body_fn up to attempts times. each fail logged loud. if all
fail, throw the LAST error (so caller see real cause). backoff_fn lets
you sleep between attempts.
"""
function aretry(body_fn::Function; attempts::Integer = 3,
                backoff_fn::Function = (i) -> nothing)
    if attempts < 1
        throw(ArgumentError("AnalogControl.aretry: attempts must be >= 1"))
    end
    last_err = nothing
    for i in 1:attempts
        try
            return body_fn(i)
        catch e
            last_err = e
            @warn "AnalogControl.aretry: attempt $i/$attempts failed" exception=(e, catch_backtrace())
            if i < attempts
                backoff_fn(i)
            end
        end
    end
    @warn "AnalogControl.aretry: all $attempts attempts failed, rethrowing last error"
    throw(last_err)
end

"""
    awith_timeout(body_fn, seconds; label="awith_timeout") -> result

GRUG: run body_fn in a Task. if takes longer than seconds, YELL and
throw timeout error. body_fn cannot be interrupted from outside in
pure Julia, so we just wait and detect overrun.
"""
function awith_timeout(body_fn::Function, seconds::Real;
                       label::String = "awith_timeout")
    if !isfinite(seconds) || seconds <= 0
        throw(ArgumentError("AnalogControl.awith_timeout: seconds $seconds must be positive finite"))
    end
    t = Task(body_fn)
    schedule(t)
    deadline = time() + seconds
    while !istaskdone(t)
        if time() > deadline
            @warn "AnalogControl.$label: timeout exceeded ($seconds s) -- task still running, raising"
            throw(ErrorException(
                "AnalogControl.$label: body_fn exceeded timeout of $seconds seconds"))
        end
        sleep(0.001)
    end
    if istaskfailed(t)
        @warn "AnalogControl.$label: task failed inside timeout window"
        throw(t.exception)
    end
    return t.result
end

# ============================================================================
# ACADEMIC FOOTER
# ============================================================================
#
# AnalogControl — Turing-Complete Control Flow over Analog Substrate
# ===================================================================
#
# This module provides the control-flow primitives that, combined with the
# arithmetic of AnalogPrimitives and the state primitives of AnalogMemory,
# yield Turing completeness over the analog substrate. Specifically:
#
#   - Conditional branching: abranch (crisp), afuzzy_branch (Bernoulli-
#     gated), astochastic_branch (categorical-gated).
#   - Bounded iteration: aloop (counted), awhile (predicate-controlled),
#     auntil_converged (fixed-point with convergence detection).
#   - Recursion: arecurse with explicit depth cap; afixed_point as a
#     specialization for self-applied maps.
#
# Turing completeness requires unbounded computation in principle, but no
# physical realization is unbounded in practice. The MAX_ITERATIONS_DEFAULT
# cap (10,000) is a safety guarantee, not a fundamental limit — callers
# requiring more can pass a larger cap explicitly. The cap is enforced as
# a hard error (no silent truncation), preserving the no-silent-failures
# discipline.
#
# auntil_converged adopts a stable-for-N convergence rule rather than a
# single-iteration tolerance check. This is important under jitter: a
# single jitter realization may by chance bring two iterates within tol
# even when the underlying process has not actually settled. Requiring N
# consecutive within-tol steps reduces the false-positive rate to ~p^N
# where p is the per-step false-positive probability. Default N = 3
# yields ~p³ false positives, which is typically negligible for tol on
# the order of 10⁻⁶ in a jitter-3% regime.
#
# Branching primitives split between crisp and fuzzy regimes. Crisp
# branching (abranch) requires a Boolean predicate and behaves
# deterministically given its inputs. Fuzzy branching (afuzzy_branch)
# treats the score as a Bernoulli parameter and samples; the same input
# can take either path on different invocations. Stochastic branching
# (astochastic_branch) generalizes fuzzy branching to multiple weighted
# alternatives, implementing a categorical jump.
#
# arecurse implements user-mode recursion via a closure that increments
# a Ref-based depth counter and decrements it in a finally clause. This
# allows recursion at any depth up to max_depth without consuming Julia
# stack frames at the recursion-management layer (only at the user's
# self_fn body). The :abreak symbolic exception convention provides a
# clean early-exit path through any of the loop constructs without
# requiring callers to thread a Boolean exit flag through their state.
#
# Error-handling helpers (aguard, aretry, awith_timeout) preserve the
# no-silent-failure invariant: every caught exception is logged at
# @warn level with full backtrace, and either rethrown immediately or
# replaced with an explicit fallback only when the caller has opted in.
# awith_timeout uses Task-level scheduling rather than signals because
# Julia does not provide a portable signal-based interrupt for arbitrary
# user code; the timeout is detected reactively by polling istaskdone.

end # module AnalogControl

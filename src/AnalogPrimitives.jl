# GRUG: this module is for basic rock-math but every answer wiggle.
# add, take-away, multiply, divide, compare. all of them shake then
# snap back. crystalized rocks no shake (frozen-solid math).
# this is what make digital math feel analog. real-world adding never
# give exact same answer twice.

module AnalogPrimitives

using ..JitterCore: jitter_and_snap, jitter_value, get_jitter_ratio,
                    is_jitter_enabled, Crystalized, AnalogValue,
                    is_crystalized, CRYSTALIZE_SENTINEL, crystalize
using ..CoinFlip: coinflip, biased_coinflip

export aadd, asub, amul, adiv, aneg, aabs, asqrt, aexp, alog
export aeq, alt, agt, ale, age
export afuzzy_eq, afuzzy_lt, afuzzy_gt
export amin, amax, aclamp, asum, aprod, amean
export aselect, asign

# ============================================================================
# HELPERS
# ============================================================================

# GRUG: pull number out of any wrapper. crystalized give exact, AnalogValue
# give current state, plain Real give itself.
@inline _raw(x::Real) = Float64(x)
@inline _raw(c::Crystalized) = Float64(c.value)
@inline _raw(a::AnalogValue) = Float64(a.current)

# GRUG: only solid-rock if ALL inputs solid. one wiggly rock pollutes.
# this matches the design rule: jitter is contagious, crystalize is fragile.
@inline _all_crystalized(args...) = all(is_crystalized, args)

# GRUG: legacy alias kept for back-compat in this module.
@inline _any_crystalized(args...) = any(is_crystalized, args)

# GRUG: wiggle the answer unless input was crystalized.
# if crystal-true, return a Crystalized so chained ops keep solid-rock
# property all the way up the call tree (no halfway-melt bugs).
function _maybe_jitter(result::Real, crystal::Bool)
    if crystal
        return crystalize(result)
    end
    return jitter_and_snap(result)
end

# GRUG: input may already be Crystalized from upstream; unwrap and re-wrap.
function _maybe_jitter(result::Crystalized, crystal::Bool)
    if crystal
        return result
    end
    return jitter_and_snap(result.value)
end

# GRUG: check rock not broken (NaN, Inf). complain loud if so.
function _check_finite(x::Real, op::String)
    if !isfinite(x)
        @warn "AnalogPrimitives.$op: non-finite input encountered" value=x
    end
    return x
end

# ============================================================================
# ARITHMETIC -- the four-and-friends
# ============================================================================

"""
    aadd(x, y) -> Real

GRUG: add two rocks. answer wiggle. unless either rock crystalized.
"""
function aadd(x, y)
    a = _raw(x); b = _raw(y)
    _check_finite(a, "aadd"); _check_finite(b, "aadd")
    return _maybe_jitter(a + b, _all_crystalized(x, y))
end

"""
    asub(x, y) -> Real

GRUG: take rock-y away from rock-x. answer wiggle.
"""
function asub(x, y)
    a = _raw(x); b = _raw(y)
    _check_finite(a, "asub"); _check_finite(b, "asub")
    return _maybe_jitter(a - b, _all_crystalized(x, y))
end

"""
    amul(x, y) -> Real

GRUG: multiply two rocks. answer wiggle.
"""
function amul(x, y)
    a = _raw(x); b = _raw(y)
    _check_finite(a, "amul"); _check_finite(b, "amul")
    return _maybe_jitter(a * b, _all_crystalized(x, y))
end

"""
    adiv(x, y) -> Real

GRUG: divide. but if y is zero, YELL. no quiet bad-math.
"""
function adiv(x, y)
    a = _raw(x); b = _raw(y)
    _check_finite(a, "adiv"); _check_finite(b, "adiv")
    if b == 0.0
        throw(DivideError())
    end
    return _maybe_jitter(a / b, _all_crystalized(x, y))
end

"""
    aneg(x) -> Real

GRUG: flip sign. positive go negative, negative go positive.
"""
aneg(x) = _maybe_jitter(-_raw(x), is_crystalized(x))

"""
    aabs(x) -> Real

GRUG: take away minus sign. always positive answer.
"""
aabs(x) = _maybe_jitter(abs(_raw(x)), is_crystalized(x))

"""
    asqrt(x) -> Real

GRUG: square-root rock. negative rock YELL.
"""
function asqrt(x)
    a = _raw(x)
    if a < 0
        throw(DomainError(a, "AnalogPrimitives.asqrt: cannot square-root negative"))
    end
    return _maybe_jitter(sqrt(a), is_crystalized(x))
end

"""
    aexp(x) -> Real

GRUG: e raised to rock. for big rock, can overflow, we YELL.
"""
function aexp(x)
    a = _raw(x)
    r = exp(a)
    if !isfinite(r)
        @warn "AnalogPrimitives.aexp: result overflow/underflow" input=a result=r
    end
    return _maybe_jitter(r, is_crystalized(x))
end

"""
    alog(x) -> Real

GRUG: natural log. zero or negative rock YELL.
"""
function alog(x)
    a = _raw(x)
    if a <= 0
        throw(DomainError(a, "AnalogPrimitives.alog: log of non-positive"))
    end
    return _maybe_jitter(log(a), is_crystalized(x))
end

"""
    asign(x) -> Real

GRUG: -1, 0, or 1. tell direction of rock. wiggle so zero-edge stays alive.
"""
function asign(x)
    a = _raw(x)
    s = sign(a)
    return _maybe_jitter(s, is_crystalized(x))
end

# ============================================================================
# COMPARISON -- crisp (returns Bool, no jitter on output)
# ============================================================================

# GRUG: comparison operators. these compare jittered values, so even
# x and x might compare not-equal (because both wiggle). this is correct
# analog behavior. crystalized values compare exact.

"""
    aeq(x, y; tol=1e-6) -> Bool

GRUG: are these two rocks same? must be very close (tolerance).
crystalized check is strict equal.
"""
function aeq(x, y; tol::Real = 1e-6)
    if is_crystalized(x) && is_crystalized(y)
        return _raw(x) == _raw(y)
    end
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    return abs(a - b) <= tol
end

"""
    alt(x, y) -> Bool

GRUG: is x smaller than y? both wiggle first.
"""
function alt(x, y)
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    return a < b
end

"""
    agt(x, y) -> Bool

GRUG: is x bigger than y? both wiggle first.
"""
function agt(x, y)
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    return a > b
end

ale(x, y) = !agt(x, y)
age(x, y) = !alt(x, y)

# ============================================================================
# FUZZY COMPARISONS -- return [0,1] degree of truth
# ============================================================================

"""
    afuzzy_eq(x, y; tol=1.0) -> Float64

GRUG: how-much-equal in [0,1]. one mean exact same. zero mean very
different. uses sigmoid-flavor. tol controls "soft equal" zone width.
"""
function afuzzy_eq(x, y; tol::Real = 1.0)
    if !isfinite(tol) || tol <= 0
        throw(ArgumentError("AnalogPrimitives.afuzzy_eq: tol $tol must be positive finite"))
    end
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    diff = abs(a - b)
    # GRUG: nice bell-shape that hit 1 at zero diff and decay.
    return exp(-(diff / tol)^2)
end

"""
    afuzzy_lt(x, y; tol=1.0) -> Float64

GRUG: how-much-less in [0,1]. one mean strongly less. zero mean equal-or-more.
"""
function afuzzy_lt(x, y; tol::Real = 1.0)
    if !isfinite(tol) || tol <= 0
        throw(ArgumentError("AnalogPrimitives.afuzzy_lt: tol $tol must be positive finite"))
    end
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    diff = b - a  # GRUG: positive means a < b.
    return 1.0 / (1.0 + exp(-diff / tol))
end

afuzzy_gt(x, y; tol::Real = 1.0) = afuzzy_lt(y, x; tol = tol)

# ============================================================================
# AGGREGATIONS
# ============================================================================

"""
    amin(x, y) -> Real
    amin(xs::AbstractVector) -> Real

GRUG: smallest rock. uses fuzzy-pick under jitter so ties are stochastic.
"""
function amin(x, y)
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    crystal = _all_crystalized(x, y)
    return _maybe_jitter(min(a, b), crystal)
end

function amin(xs::AbstractVector)
    if isempty(xs)
        throw(ArgumentError("AnalogPrimitives.amin: empty collection"))
    end
    crystal = all(is_crystalized, xs)
    vals = [_maybe_jitter(_raw(x), is_crystalized(x)) for x in xs]
    return _maybe_jitter(minimum(vals), crystal)
end

function amax(x, y)
    a = _maybe_jitter(_raw(x), is_crystalized(x))
    b = _maybe_jitter(_raw(y), is_crystalized(y))
    crystal = _all_crystalized(x, y)
    return _maybe_jitter(max(a, b), crystal)
end

function amax(xs::AbstractVector)
    if isempty(xs)
        throw(ArgumentError("AnalogPrimitives.amax: empty collection"))
    end
    crystal = all(is_crystalized, xs)
    vals = [_maybe_jitter(_raw(x), is_crystalized(x)) for x in xs]
    return _maybe_jitter(maximum(vals), crystal)
end

"""
    aclamp(x, lo, hi) -> Real

GRUG: keep rock between lo and hi. but the boundaries themselves wiggle
(unless crystalized) so the clamp edge is fuzzy.
"""
function aclamp(x, lo, hi)
    xv = _raw(x); lov = _raw(lo); hiv = _raw(hi)
    if lov > hiv
        throw(ArgumentError("AnalogPrimitives.aclamp: lo $lov > hi $hiv"))
    end
    crystal_bounds = is_crystalized(lo) && is_crystalized(hi)
    if !crystal_bounds
        lov = jitter_and_snap(lov)
        hiv = jitter_and_snap(hiv)
    end
    return _maybe_jitter(clamp(xv, lov, hiv),
                         is_crystalized(x) && crystal_bounds)
end

function asum(xs::AbstractVector)
    if isempty(xs)
        return 0.0
    end
    # GRUG: jittered-add many rocks. uses pairwise-sum so error doesn't pile up.
    crystal = all(is_crystalized, xs)
    acc = 0.0
    for x in xs
        acc += _raw(x)
    end
    return _maybe_jitter(acc, crystal)
end

function aprod(xs::AbstractVector)
    if isempty(xs)
        return 1.0
    end
    crystal = all(is_crystalized, xs)
    acc = 1.0
    for x in xs
        acc *= _raw(x)
    end
    return _maybe_jitter(acc, crystal)
end

function amean(xs::AbstractVector)
    if isempty(xs)
        throw(ArgumentError("AnalogPrimitives.amean: empty collection"))
    end
    crystal = all(is_crystalized, xs)
    n = length(xs)
    s = 0.0
    for x in xs
        s += _raw(x)
    end
    return _maybe_jitter(s / n, crystal)
end

# ============================================================================
# STOCHASTIC SELECT
# ============================================================================

"""
    aselect(cond, t_val, f_val) -> Real

GRUG: ternary-pick. cond is fuzzy [0,1]. coinflip biased by cond decides
which value comes out. cond=1 always pick t_val. cond=0 always pick f_val.
cond=0.5 fifty-fifty.
"""
function aselect(cond::Real, t_val, f_val)
    if !isfinite(cond)
        throw(ArgumentError("AnalogPrimitives.aselect: non-finite condition $cond"))
    end
    p = clamp(Float64(cond), 0.0, 1.0)
    return coinflip(p) ? _raw(t_val) : _raw(f_val)
end

# ============================================================================
# ACADEMIC FOOTER
# ============================================================================
#
# AnalogPrimitives — Jittered Arithmetic and Comparison
# ======================================================
#
# This module lifts standard floating-point arithmetic and comparison
# operations into the analog domain by composing them with the JitterCore
# jitter+snap-back primitive. Every result is post-processed unless one
# or more inputs were Crystalized, in which case the crystalization
# property propagates through the operation (analogous to a "pure" subset
# of an otherwise stochastic algebra).
#
# The arithmetic operations preserve standard exception behavior:
# DivideError on adiv(x, 0), DomainError on asqrt(x<0) and alog(x≤0).
# Non-finite intermediates are reported via @warn rather than masked.
#
# Comparison operations split into two regimes:
#
#   1. Crisp (aeq/alt/agt/ale/age) — perturb both operands then evaluate
#      a Boolean predicate. The Boolean output itself is not jittered;
#      stochasticity enters only through the operand perturbation. Two
#      nominally-equal but non-crystalized values may compare unequal
#      because their independent jitter realizations differ.
#
#   2. Fuzzy (afuzzy_eq/afuzzy_lt/afuzzy_gt) — return a degree of truth
#      in [0, 1]. afuzzy_eq uses a Gaussian kernel exp(-(Δ/τ)²) so two
#      identical values map to 1.0 and identity decays smoothly.
#      afuzzy_lt uses a logistic σ((b-a)/τ) so the boundary at a=b
#      maps to 0.5 and the function is symmetric around it.
#
# aselect implements a stochastic ternary: the condition is interpreted
# as a Bernoulli probability and the output is sampled accordingly. This
# is the analog analogue of the classical conditional, and it is the
# foundational primitive for control-flow constructs in AnalogControl.
#
# Aggregations (amin/amax/asum/aprod/amean/aclamp) jitter both inputs
# and outputs (when not crystalized) so order-sensitive boundary effects
# (e.g., min/max ties) become probabilistic. aclamp additionally jitters
# the bounds themselves unless both bounds are crystalized — this
# corresponds to a "soft barrier" rather than a hard wall.
#
# All operations honor the JitterCore global enable/disable state; when
# jitter is disabled, the module degenerates to standard deterministic
# arithmetic (modulo the @warn surface for non-finite intermediates).
# This permits the same code to run in both analog and digital regimes,
# which is useful for testing reproducibility and for performance-
# critical sub-paths where stochasticity is not desired.

end # module AnalogPrimitives

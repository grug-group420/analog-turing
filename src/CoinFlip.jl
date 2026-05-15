# GRUG: this module is the cave-coin. you flip rock, get yes or no.
# but rock not fair like normal coin. rock can be heavy on one side
# (bias). also rock itself wiggle (jitter the threshold) so two coins
# never give exact same answer in same moment. cave brain need this
# because deterministic ties starve weaker rocks of voice.

module CoinFlip

using Random
using ..JitterCore: jitter_value, get_jitter_ratio, is_jitter_enabled,
                    Crystalized, AnalogValue, CRYSTALIZE_SENTINEL

export @coinflip, coinflip, weighted_coinflip, biased_coinflip
export categorical_coinflip, lateral_inhibition_coinflip

# ============================================================================
# THE @coinflip MACRO -- canonical stochastic gate
# ============================================================================

"""
    @coinflip threshold expr_true [expr_false]

GRUG: roll dice. if dice number less than threshold (which itself wiggle),
do first thing. else do second thing (or nothing if no second thing given).
threshold is fraction zero-to-one. zero = never, one = always.
"""
macro coinflip(threshold, expr_true, expr_false=nothing)
    if expr_false === nothing
        return quote
            local _t = $(esc(threshold))
            local _t_jittered = $CoinFlip.jitter_threshold(_t)
            if rand() < _t_jittered
                $(esc(expr_true))
            else
                nothing
            end
        end
    else
        return quote
            local _t = $(esc(threshold))
            local _t_jittered = $CoinFlip.jitter_threshold(_t)
            if rand() < _t_jittered
                $(esc(expr_true))
            else
                $(esc(expr_false))
            end
        end
    end
end

# GRUG: jitter the threshold but keep it inside [0.01, 0.99] so we never
# end up at impossible-zero or always-one (which would defeat coinflip).
# this is borrowed straight from grugbot's jitter_coin_threshold.
function jitter_threshold(p::Real; rho::Real = 0.01)
    if !isfinite(p)
        throw(ArgumentError("CoinFlip.jitter_threshold: threshold $p must be finite"))
    end
    if p < 0 || p > 1
        throw(ArgumentError("CoinFlip.jitter_threshold: threshold $p must be in [0,1]"))
    end
    if !is_jitter_enabled()
        return clamp(p, 0.01, 0.99)
    end
    shake = (rand() * 2 - 1) * rho
    return clamp(p + shake, 0.01, 0.99)
end

jitter_threshold(c::Crystalized) = clamp(c.value, 0.01, 0.99)

# ============================================================================
# COINFLIP FUNCTIONS
# ============================================================================

"""
    coinflip(threshold::Real)::Bool

GRUG: simple yes-or-no. true if dice less than wiggly threshold.
"""
function coinflip(threshold::Real)::Bool
    return rand() < jitter_threshold(threshold)
end

coinflip(c::Crystalized) = coinflip(c.value)

"""
    weighted_coinflip(weights::Vector)::Int

GRUG: many rocks, each with weight. pick one rock with probability
proportional to weight. heavier rock = more likely picked. but EVERY
rock has tiny chance even if very light (this is the ambient field).
"""
function weighted_coinflip(weights::AbstractVector{<:Real})
    if isempty(weights)
        throw(ArgumentError("CoinFlip.weighted_coinflip: empty weight vector"))
    end
    n = length(weights)
    # GRUG: check rocks one by one. no NaN allowed.
    for (i, w) in enumerate(weights)
        if !isfinite(w)
            throw(ArgumentError("CoinFlip.weighted_coinflip: non-finite weight at index $i: $w"))
        end
        if w < 0
            throw(ArgumentError("CoinFlip.weighted_coinflip: negative weight at index $i: $w"))
        end
    end
    # GRUG: jitter every weight so ties broken stochastic.
    jittered = [is_jitter_enabled() ? jitter_value(Float64(w)) : Float64(w) for w in weights]
    # GRUG: ambient field -- minimum baseline so no rock is fully muted.
    floor_w = 1e-6
    jittered = [max(w, floor_w) for w in jittered]
    total = sum(jittered)
    if total <= 0
        # GRUG: if everyone zero-or-less after floor, just uniform. should not happen.
        @warn "CoinFlip.weighted_coinflip: all weights collapsed to zero, falling back to uniform"
        return rand(1:n)
    end
    r = rand() * total
    acc = 0.0
    for i in 1:n
        acc += jittered[i]
        if r <= acc
            return i
        end
    end
    # GRUG: numerical floor catch. last rock wins by default.
    return n
end

"""
    biased_coinflip(p_true::Real, bias::Real)::Bool

GRUG: coin with bias added on top. bias positive = more likely true.
bias negative = more likely false. used when one outcome should be
favored but other still possible.
"""
function biased_coinflip(p_true::Real, bias::Real)::Bool
    if !isfinite(p_true) || !isfinite(bias)
        throw(ArgumentError("CoinFlip.biased_coinflip: non-finite input p=$p_true bias=$bias"))
    end
    effective = clamp(p_true + bias, 0.01, 0.99)
    return rand() < jitter_threshold(effective)
end

"""
    categorical_coinflip(probs::Vector{<:Real})::Int

GRUG: probs MUST sum to one (or close). pick category by index.
this is the strict version of weighted_coinflip for true probability
distributions. throws if probs do not sum to ~1.
"""
function categorical_coinflip(probs::AbstractVector{<:Real}; tol::Real = 1e-3)
    if isempty(probs)
        throw(ArgumentError("CoinFlip.categorical_coinflip: empty probability vector"))
    end
    s = 0.0
    for (i, p) in enumerate(probs)
        if !isfinite(p) || p < 0
            throw(ArgumentError("CoinFlip.categorical_coinflip: bad probability at index $i: $p"))
        end
        s += p
    end
    if abs(s - 1.0) > tol
        throw(ArgumentError("CoinFlip.categorical_coinflip: probs sum to $s, expected ~1.0 (tol=$tol)"))
    end
    return weighted_coinflip(probs)
end

"""
    lateral_inhibition_coinflip(weights::Vector{<:Real}; sharpness::Real=2.0)::Int

GRUG: winner-take-all but with little leak. raise weights to power, then
weighted-pick. high sharpness = more deterministic (winner almost always).
low sharpness = more democratic. this is lobe-inhibition cave-style.
"""
function lateral_inhibition_coinflip(weights::AbstractVector{<:Real}; sharpness::Real = 2.0)
    if isempty(weights)
        throw(ArgumentError("CoinFlip.lateral_inhibition_coinflip: empty weights"))
    end
    if !isfinite(sharpness) || sharpness <= 0
        throw(ArgumentError("CoinFlip.lateral_inhibition_coinflip: sharpness $sharpness must be positive finite"))
    end
    sharpened = [max(Float64(w), 0.0)^sharpness for w in weights]
    return weighted_coinflip(sharpened)
end

# ============================================================================
# ACADEMIC FOOTER
# ============================================================================
#
# CoinFlip — Stochastic Gating Primitives
# ========================================
#
# This module provides the discrete-event stochastic primitives that drive
# decision points in an analog-Turing system. Each primitive composes the
# uniform random source with the JitterCore perturbation to ensure that
# repeated invocations under identical nominal parameters produce a
# distribution rather than a deterministic outcome.
#
# The threshold-jitter mechanism (jitter_threshold) clamps the perturbed
# probability into [0.01, 0.99] for two reasons:
#
#   1. Hard endpoints (0.0 or 1.0) collapse the gate into a deterministic
#      decision, defeating the stochastic-gate semantics.
#   2. The clamping preserves a minimum exploration probability — the
#      "ambient field" guarantee — so even strongly-biased gates retain
#      a small chance of the minority outcome. This corresponds to
#      lateral inhibition with floor in winner-take-all networks.
#
# weighted_coinflip implements proportional selection with a JITTER-then-
# FLOOR composition: weights are perturbed first (so ties become
# probabilistic), then floored at a small positive constant (so zero-weight
# entries retain non-zero selection probability). This is the
# strength-biased selection rule from competitive-learning literature with
# an explicit ambient-field floor.
#
# categorical_coinflip is the strict variant: it requires probs to be a
# valid probability distribution (sum ≈ 1) and surfaces violations as
# ArgumentError. weighted_coinflip is the relaxed variant: weights need
# only be non-negative.
#
# lateral_inhibition_coinflip exponentiates weights before normalization,
# implementing soft winner-take-all. As sharpness → ∞ the rule converges
# to argmax; as sharpness → 0 it converges to uniform. Sharpness =1
# recovers weighted_coinflip semantics. This corresponds to the
# temperature-controlled softmax → hardmax spectrum.
#
# All gates use rand() from Julia's task-local default RNG. Callers
# requiring reproducibility can seed the RNG externally (Random.seed!).
# Thread-safety: the gates are stateless apart from the global RNG and
# the JitterCore configuration lock, both of which are safe for
# concurrent reads.

end # module CoinFlip

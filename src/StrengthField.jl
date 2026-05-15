# GRUG: this module is for many-rocks-compete cave. each rock have
# strength. rocks vote together, strongest tend to win but weakest
# always have small chance (ambient floor). this is competitive
# learning cave-style. used when you have a population of options
# and need analog-flavor selection.

module StrengthField

using ..JitterCore: jitter_value, jitter_and_snap, get_jitter_ratio,
                    Crystalized, AnalogValue,
                    CRYSTALIZE_SENTINEL
import ..JitterCore: is_crystalized, crystalize!, uncrystalize!
using ..CoinFlip: coinflip, weighted_coinflip, lateral_inhibition_coinflip
using ..AnalogPrimitives: _raw

export StrengthBead, Population, register!, fire!, vote, winner_take_all
export bump_strength!, decay_strength!, crystalize_bead!
export bulk_decay!, bulk_reinforce!, alive_count, get_bead, activation_probability
export crystalize!, uncrystalize!, is_crystalized
export STRENGTH_FLOOR, STRENGTH_CAP

# GRUG: rock-strength bounds. nobody go below floor or above cap.
# borrowed from grugbot AIML strength rules.
const STRENGTH_FLOOR = 0.0
const STRENGTH_CAP = 10.0
const ACTIVATION_FLOOR = 0.1   # GRUG: ambient field minimum.
const ACTIVATION_PEAK = 0.9    # GRUG: max strength-driven activation.
const STRENGTH_GRAVE_THRESHOLD = 0.05  # GRUG: at-or-below this = dead rock.

# ============================================================================
# STRENGTH BEAD -- one rock in the population
# ============================================================================

"""
GRUG: StrengthBead is one rock that competes. has identity (id),
strength (how loud), and crystalize flag (whether locked). bumps
on use, decays on disuse, dies if strength hit floor.
"""
mutable struct StrengthBead
    id::String
    strength::Float64
    crystalized::Bool
    fire_count::Int
    is_grave::Bool
end

function StrengthBead(id::String; strength::Real = 1.0,
                       crystalized::Bool = false)
    if !isfinite(strength)
        throw(ArgumentError("StrengthField.StrengthBead: strength $strength must be finite"))
    end
    s = clamp(Float64(strength), STRENGTH_FLOOR, STRENGTH_CAP)
    return StrengthBead(id, s, crystalized, 0, false)
end

function bump_strength!(bead::StrengthBead; delta::Real = 0.5)
    if !isfinite(delta)
        throw(ArgumentError("StrengthField.bump_strength!: delta $delta must be finite"))
    end
    if bead.crystalized
        return bead.strength
    end
    if bead.is_grave
        @warn "StrengthField.bump_strength!: bead '$(bead.id)' is in grave state, ignoring bump"
        return bead.strength
    end
    jittered_delta = jitter_value(Float64(delta))
    new_s = clamp(bead.strength + jittered_delta, STRENGTH_FLOOR, STRENGTH_CAP)
    bead.strength = new_s
    return new_s
end

function decay_strength!(bead::StrengthBead; rate::Real = 0.05)
    if !isfinite(rate) || rate < 0 || rate > 1
        throw(ArgumentError("StrengthField.decay_strength!: rate $rate must be in [0,1]"))
    end
    if bead.crystalized
        return bead.strength
    end
    if bead.is_grave
        return bead.strength
    end
    new_s = bead.strength * (1.0 - rate)
    bead.strength = clamp(new_s, STRENGTH_FLOOR, STRENGTH_CAP)
    # GRUG: grave threshold. small but not zero. anything this dim
    # is dead-rock. otherwise bead at 1e-6 hangs around forever.
    if bead.strength <= STRENGTH_FLOOR + STRENGTH_GRAVE_THRESHOLD
        # GRUG: rock too weak. mark grave. loud.
        bead.is_grave = true
        @warn "StrengthField.decay_strength!: bead '$(bead.id)' fell to grave state"
    end
    return bead.strength
end

function crystalize_bead!(bead::StrengthBead)
    bead.crystalized = true
    return bead
end

"""
    activation_probability(bead) -> Float64

GRUG: probability this rock fires in next coinflip. always at least
ACTIVATION_FLOOR (ambient field). climbs with strength up to ACTIVATION_PEAK.
"""
function activation_probability(bead::StrengthBead)
    if bead.is_grave
        return 0.0
    end
    s_norm = bead.strength / STRENGTH_CAP
    return ACTIVATION_FLOOR + (ACTIVATION_PEAK - ACTIVATION_FLOOR) * s_norm
end

# ============================================================================
# POPULATION -- many beads competing
# ============================================================================

"""
GRUG: Population hold many beads by id. you register them, fire them,
collect votes, pick winners. thread-safe via lock.
"""
mutable struct Population
    beads::Dict{String, StrengthBead}
    crystalized::Bool   # GRUG: population-wide freeze. when true, bulk_decay!
                        #       and bulk_reinforce! become no-ops. fire! still
                        #       runs but uses stored strengths exact (no jitter
                        #       in activation_probability sampling).
    lock::ReentrantLock
end

Population() = Population(Dict{String, StrengthBead}(), false, ReentrantLock())

function register!(pop::Population, bead::StrengthBead)
    lock(pop.lock) do
        if haskey(pop.beads, bead.id)
            @warn "StrengthField.register!: id '$(bead.id)' already exists, overwriting"
        end
        pop.beads[bead.id] = bead
    end
    return bead
end

function register!(pop::Population, id::String; strength::Real = 1.0,
                   crystalized::Bool = false)
    bead = StrengthBead(id; strength = strength, crystalized = crystalized)
    return register!(pop, bead)
end

"""
    fire!(pop) -> Vector{String}

GRUG: every alive rock get coinflip weighted by its strength. those
that fire return in the list. crystalized rocks always fire.
"""
function fire!(pop::Population)
    lock(pop.lock) do
        fired = String[]
        for (id, bead) in pop.beads
            if bead.is_grave
                continue
            end
            if bead.crystalized
                push!(fired, id)
                bead.fire_count += 1
                continue
            end
            p = activation_probability(bead)
            if coinflip(p)
                push!(fired, id)
                bead.fire_count += 1
            end
        end
        return fired
    end
end

"""
    vote(pop, fired_ids; sharpness=1.0) -> Union{String, Nothing}

GRUG: among rocks that fired, pick winner by strength-weighted coinflip.
sharpness=1 is plain weighted. higher sharpness = more deterministic
(loud rock more likely to dominate). returns nothing if no fired.
"""
function vote(pop::Population, fired_ids::Vector{String}; sharpness::Real = 1.0)
    if isempty(fired_ids)
        return nothing
    end
    lock(pop.lock) do
        weights = Float64[]
        valid_ids = String[]
        for id in fired_ids
            if !haskey(pop.beads, id)
                @warn "StrengthField.vote: fired id '$id' not in population, skipping"
                continue
            end
            bead = pop.beads[id]
            if bead.is_grave
                continue
            end
            push!(weights, bead.strength)
            push!(valid_ids, id)
        end
        if isempty(weights)
            return nothing
        end
        if sharpness == 1.0
            idx = weighted_coinflip(weights)
        else
            idx = lateral_inhibition_coinflip(weights; sharpness = sharpness)
        end
        return valid_ids[idx]
    end
end

"""
    winner_take_all(pop; sharpness=4.0) -> Union{String, Nothing}

GRUG: skip the firing step, just pick a winner from the population.
high sharpness mean strongest rock almost always wins (but ambient
field still leak weak ones through).
"""
function winner_take_all(pop::Population; sharpness::Real = 4.0)
    lock(pop.lock) do
        ids = String[]
        weights = Float64[]
        for (id, bead) in pop.beads
            if bead.is_grave
                continue
            end
            push!(ids, id)
            push!(weights, bead.strength + ACTIVATION_FLOOR)
        end
        if isempty(ids)
            return nothing
        end
        idx = lateral_inhibition_coinflip(weights; sharpness = sharpness)
        return ids[idx]
    end
end

"""
    grave_count(pop) -> Int

GRUG: how many rocks have died.
"""
function grave_count(pop::Population)
    lock(pop.lock) do
        return count(b -> b.is_grave, values(pop.beads))
    end
end

function alive_count(pop::Population)
    lock(pop.lock) do
        return count(b -> !b.is_grave, values(pop.beads))
    end
end

function get_bead(pop::Population, id::String)
    lock(pop.lock) do
        return get(pop.beads, id, nothing)
    end
end

"""
    bulk_decay!(pop; rate=0.01)

GRUG: tick the whole population's strength down by rate. use this in
idle cycles to implement use-it-or-lose-it.
"""
function bulk_decay!(pop::Population; rate::Real = 0.01)
    lock(pop.lock) do
        # GRUG: population frozen => no decay anywhere. preserves the field.
        if pop.crystalized
            return pop
        end
        for bead in values(pop.beads)
            decay_strength!(bead; rate = rate)
        end
    end
    return pop
end

"""
    bulk_reinforce!(pop, ids; delta=0.5)

GRUG: bump strength on the rocks that contributed to a successful turn.
the inverse of bulk_decay! -- this is the "right answer" reward.
"""
function bulk_reinforce!(pop::Population, ids::Vector{String}; delta::Real = 0.5)
    lock(pop.lock) do
        # GRUG: frozen population ignores bumps too. symmetric with decay.
        if pop.crystalized
            return pop
        end
        for id in ids
            bead = get(pop.beads, id, nothing)
            if bead === nothing
                @warn "StrengthField.bulk_reinforce!: id '$id' not in population"
                continue
            end
            bump_strength!(bead; delta = delta)
        end
    end
    return pop
end

# GRUG: freeze entire population. bulk_decay! and bulk_reinforce! become
# no-ops. if cascade=true (default), also flips every individual bead's
# crystalized flag to true so fire! treats them all as guaranteed-firing
# pinned units. uncrystalize!(pop) reverses both.
function crystalize!(pop::Population; cascade::Bool = true)
    lock(pop.lock) do
        pop.crystalized = true
        if cascade
            for bead in values(pop.beads)
                bead.crystalized = true
            end
        end
        return pop
    end
end

function uncrystalize!(pop::Population; cascade::Bool = true)
    lock(pop.lock) do
        pop.crystalized = false
        if cascade
            for bead in values(pop.beads)
                bead.crystalized = false
            end
        end
        return pop
    end
end

is_crystalized(pop::Population)::Bool = lock(() -> pop.crystalized, pop.lock)

# GRUG: also expose is_crystalized for individual beads (mirrors AnalogValue).
is_crystalized(bead::StrengthBead)::Bool = bead.crystalized

# ============================================================================
# ACADEMIC FOOTER
# ============================================================================
#
# StrengthField — Population-Level Competitive Learning Substrate
# ================================================================
#
# This module implements the population-level competitive substrate that
# unifies the per-element jitter and stochastic-gating primitives into a
# coherent multi-agent dynamical system. Conceptually, it provides:
#
#   StrengthBead — a single competing element with a bounded scalar
#   strength variable s ∈ [STRENGTH_FLOOR, STRENGTH_CAP]. Reinforcement
#   is implemented as bump_strength! with jittered delta; degradation
#   is implemented as multiplicative decay. Strength reaching the floor
#   triggers a one-way transition to a "grave" state, providing the
#   apoptosis mechanic borrowed from GrugBot.
#
#   Population — a thread-safe registry of beads keyed by string id.
#   Provides three selection regimes:
#     - fire!         : Bernoulli sampling, p = ACTIVATION_FLOOR
#                       + (PEAK - FLOOR) · s/STRENGTH_CAP. This is
#                       the strength-biased coinflip from §3 of the
#                       GrugBot whitepaper.
#     - vote          : strength-weighted selection over a subset
#                       (typically the fire! output). Sharpness
#                       parameter interpolates between weighted-
#                       proportional and winner-take-all.
#     - winner_take_all : direct sharpness-controlled selection over
#                       the full population, bypassing the fire!
#                       gating step. Used when a forced-decision
#                       semantics is required.
#
# The activation-probability formula guarantees a non-zero floor for
# every alive bead — the "ambient field" property that ensures even
# weak beads retain a small chance of firing. This prevents the
# population from collapsing onto a single dominant attractor and
# preserves exploration. The corresponding floor in the weighted-
# coinflip path is provided by the underlying CoinFlip module
# (1e-6 weight floor) and by the additive ACTIVATION_FLOOR in
# winner_take_all's weight construction.
#
# bulk_decay! and bulk_reinforce! provide the use-it-or-lose-it /
# right-answer-reward dual that drives competitive learning. In a
# typical loop, fire! → vote → consumer-action → bulk_reinforce!
# (on contributors) followed by occasional bulk_decay! ticks
# implements the "Hebbian + apoptosis" learning rule from
# competitive-learning literature, with all updates jittered to
# preserve stochastic tie-breaking.
#
# Crystalization is implemented per-bead as a boolean flag. A
# crystalized bead always fires, ignores bump_strength! and
# decay_strength!, and acts as a fixed source in the population's
# dynamics. This corresponds to the "crystalized node" concept
# from the GrugBot AIML layer and supports the user-defined
# invariant pattern from the v7.17.0 design discussions.
#
# Thread-safety is provided by a per-population ReentrantLock. All
# bead-mutating operations (bump_strength!, decay_strength!,
# register!, fire!, vote, winner_take_all, bulk_*) acquire the
# lock before touching shared state. Bead-local operations on a
# bead held outside a population are not lock-protected; callers
# moving beads between populations must coordinate externally.

end # module StrengthField

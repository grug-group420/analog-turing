# GRUG: this module is for cave-memory. how analog system remember things.
# we store wiggly numbers but they snap-back to baseline. accumulator
# build up over many turns. hopfield-cave remember pattern by similar-rock
# match (associative). decay slowly forget. crystalize say "this memory
# locked, no forget, no jitter".
# this gives the STATE half of turing-completeness when paired with
# AnalogControl branch and loop.

module AnalogMemory

using ..JitterCore: jitter_and_snap, jitter_value, snap_back!, get_jitter_ratio,
                    Crystalized, AnalogValue, is_crystalized,
                    CRYSTALIZE_SENTINEL, crystalize
using ..CoinFlip: coinflip
using ..AnalogPrimitives: _raw

# GRUG: rename to avoid collision with Base.accumulate!.
# we extend it explicitly below so user can still write accumulate!(acc, x)
# without qualified name. reset! is not in Base (1.10), no import needed.
import Base: accumulate!

export AnalogRegister, set!, get_value, drift!, crystalize_register!, uncrystalize_register!
export AnalogAccumulator, accumulate!, value, reset!, decay!
export HopfieldCache, store!, recall, recall_top_k
export ambient_field, AmbientField, sample_field

# ============================================================================
# ANALOG REGISTER -- single-cell wiggly memory
# ============================================================================

"""
GRUG: AnalogRegister is one wiggly rock you can read and write. each
read jitter the value, but baseline stay close to what you wrote.
crystalized register stop wiggling.
"""
mutable struct AnalogRegister
    av::AnalogValue{Float64}
    label::String
    write_count::Int
    read_count::Int
    lock::ReentrantLock
end

function AnalogRegister(initial::Real; label::String = "anon")
    if !isfinite(initial)
        throw(ArgumentError("AnalogMemory.AnalogRegister: initial $initial must be finite"))
    end
    return AnalogRegister(AnalogValue(Float64(initial)), label, 0, 0,
                          ReentrantLock())
end

function set!(r::AnalogRegister, x::Real)
    if !isfinite(x)
        throw(ArgumentError("AnalogMemory.set!: cannot write non-finite value $x to register '$(r.label)'"))
    end
    lock(r.lock) do
        if r.av.crystalized
            @warn "AnalogMemory.set!: register '$(r.label)' is crystalized, write rejected"
            return r
        end
        r.av.baseline = Float64(x)
        r.av.current = Float64(x)
        r.write_count += 1
        return r
    end
end

function get_value(r::AnalogRegister)
    lock(r.lock) do
        r.read_count += 1
        if r.av.crystalized
            return r.av.current
        end
        # GRUG: read = jitter + snap. value naturally drift around baseline.
        return jitter_and_snap(r.av)
    end
end

function drift!(r::AnalogRegister; alpha::Real = 0.85,
                baseline_jitter::Real = 0.001)
    lock(r.lock) do
        if r.av.crystalized
            return r
        end
        snap_back!(r.av; alpha = alpha, baseline_jitter = baseline_jitter)
        return r
    end
end

function crystalize_register!(r::AnalogRegister)
    lock(r.lock) do
        r.av.crystalized = true
    end
    return r
end

function uncrystalize_register!(r::AnalogRegister)
    lock(r.lock) do
        r.av.crystalized = false
    end
    return r
end

# ============================================================================
# ANALOG ACCUMULATOR -- decaying running-sum with jitter
# ============================================================================

"""
GRUG: AnalogAccumulator pile up rocks over time but slowly forget old ones.
decay_rate=0 mean perfect memory, =1 mean total amnesia each tick.
jitter and snap-back happen on each accumulate so the running total
breathes.
"""
mutable struct AnalogAccumulator
    state::Float64
    decay_rate::Float64
    crystalized::Bool
    n_inputs::Int
    label::String
    lock::ReentrantLock
end

function AnalogAccumulator(; decay_rate::Real = 0.05,
                            initial::Real = 0.0,
                            label::String = "anon")
    if !isfinite(decay_rate) || decay_rate < 0 || decay_rate > 1
        throw(ArgumentError("AnalogMemory.AnalogAccumulator: decay_rate $decay_rate must be in [0,1]"))
    end
    if !isfinite(initial)
        throw(ArgumentError("AnalogMemory.AnalogAccumulator: initial $initial must be finite"))
    end
    return AnalogAccumulator(Float64(initial), Float64(decay_rate), false,
                              0, label, ReentrantLock())
end

function accumulate!(acc::AnalogAccumulator, x::Real)
    if !isfinite(x)
        throw(ArgumentError("AnalogMemory.accumulate!: non-finite input $x to accumulator '$(acc.label)'"))
    end
    lock(acc.lock) do
        if acc.crystalized
            return acc.state
        end
        # GRUG: forget a bit, then add new rock with wiggle.
        decayed = acc.state * (1.0 - acc.decay_rate)
        added = decayed + Float64(x)
        acc.state = jitter_and_snap(added)
        acc.n_inputs += 1
        return acc.state
    end
end

function value(acc::AnalogAccumulator)
    lock(acc.lock) do
        if acc.crystalized
            return acc.state
        end
        return jitter_and_snap(acc.state)
    end
end

function reset!(acc::AnalogAccumulator; to::Real = 0.0)
    if !isfinite(to)
        throw(ArgumentError("AnalogMemory.reset!: target $to must be finite"))
    end
    lock(acc.lock) do
        acc.state = Float64(to)
        acc.n_inputs = 0
        return acc
    end
end

function decay!(acc::AnalogAccumulator; rate::Real = -1.0)
    lock(acc.lock) do
        if acc.crystalized
            return acc.state
        end
        d = rate < 0 ? acc.decay_rate : Float64(rate)
        if !isfinite(d) || d < 0 || d > 1
            throw(ArgumentError("AnalogMemory.decay!: rate $d must be in [0,1]"))
        end
        acc.state *= (1.0 - d)
        return acc.state
    end
end

# ============================================================================
# HOPFIELD CACHE -- associative pattern memory
# ============================================================================

"""
GRUG: HopfieldCache remember patterns. you give it a key-pattern and a
value. later you query with similar-pattern, it give back closest stored
value. cosine-similarity for matching. each entry has strength that
decay slow over time. strong entries crystalize automatic past threshold.
"""
mutable struct HopfieldEntry
    key::Vector{Float64}
    value::Float64
    strength::Float64
    crystalized::Bool
    last_recalled::Float64  # GRUG: timestamp
end

mutable struct HopfieldCache
    entries::Vector{HopfieldEntry}
    capacity::Int
    crystalize_threshold::Float64
    decay_rate::Float64
    lock::ReentrantLock
end

function HopfieldCache(; capacity::Integer = 256,
                        crystalize_threshold::Real = 5.0,
                        decay_rate::Real = 0.001)
    if capacity < 1
        throw(ArgumentError("AnalogMemory.HopfieldCache: capacity must be >= 1"))
    end
    if !isfinite(crystalize_threshold) || crystalize_threshold <= 0
        throw(ArgumentError("AnalogMemory.HopfieldCache: crystalize_threshold $crystalize_threshold must be positive finite"))
    end
    if !isfinite(decay_rate) || decay_rate < 0 || decay_rate > 1
        throw(ArgumentError("AnalogMemory.HopfieldCache: decay_rate $decay_rate must be in [0,1]"))
    end
    return HopfieldCache(HopfieldEntry[], Int(capacity),
                          Float64(crystalize_threshold),
                          Float64(decay_rate),
                          ReentrantLock())
end

"""
    _key_near(a, b; cos_thresh=0.95, rel_l2_thresh=0.05) -> Bool

GRUG: rock-similar test. cosine alone is bad for short keys
(any two 1-D vectors point same way and look identical).
so we also check L2 distance is small relative to magnitude.
this means [1.0] and [2.0] are NOT merged even though cos=1.
"""
function _key_near(a::Vector{Float64}, b::Vector{Float64};
                   cos_thresh::Float64 = 0.95,
                   rel_l2_thresh::Float64 = 0.05)
    if length(a) != length(b)
        return false
    end
    # GRUG: tiny vector tolerance.
    eps_floor = 1e-9
    diff = sqrt(sum((a .- b).^2))
    mag  = max(sqrt(sum(a.^2)), sqrt(sum(b.^2)), eps_floor)
    if diff / mag > rel_l2_thresh
        return false
    end
    # GRUG: also direction must agree (helps high-D).
    if length(a) >= 2
        return _cosine(a, b) > cos_thresh
    else
        return true  # 1-D and L2-close is enough
    end
end

function _cosine(a::Vector{Float64}, b::Vector{Float64})
    if length(a) != length(b)
        throw(DimensionMismatch("AnalogMemory._cosine: length $(length(a)) vs $(length(b))"))
    end
    if isempty(a)
        return 0.0
    end
    na = sqrt(sum(x -> x*x, a))
    nb = sqrt(sum(x -> x*x, b))
    if na == 0 || nb == 0
        return 0.0
    end
    dot = 0.0
    for i in 1:length(a)
        dot += a[i] * b[i]
    end
    return dot / (na * nb)
end

function store!(cache::HopfieldCache, key::AbstractVector{<:Real},
                val::Real; initial_strength::Real = 1.0)
    if !isfinite(val)
        throw(ArgumentError("AnalogMemory.store!: non-finite value $val"))
    end
    if any(!isfinite, key)
        throw(ArgumentError("AnalogMemory.store!: key contains non-finite element"))
    end
    if !isfinite(initial_strength) || initial_strength <= 0
        throw(ArgumentError("AnalogMemory.store!: initial_strength $initial_strength must be positive finite"))
    end
    keyf = Float64.(collect(key))
    lock(cache.lock) do
        # GRUG: if very-similar key already there, bump it instead of new.
        for e in cache.entries
            if _key_near(e.key, keyf)
                # GRUG: same-ish pattern. bump strength, blend value.
                e.strength = jitter_and_snap(e.strength + Float64(initial_strength))
                e.value = jitter_and_snap(0.5 * e.value + 0.5 * Float64(val))
                if e.strength >= cache.crystalize_threshold && !e.crystalized
                    e.crystalized = true
                end
                e.last_recalled = time()
                return e
            end
        end
        # GRUG: new pattern. evict weakest if over capacity.
        if length(cache.entries) >= cache.capacity
            # GRUG: never evict crystalized.
            evict_idx = 0
            min_strength = Inf
            for (i, e) in enumerate(cache.entries)
                if !e.crystalized && e.strength < min_strength
                    min_strength = e.strength
                    evict_idx = i
                end
            end
            if evict_idx == 0
                @warn "AnalogMemory.store!: cache full of crystalized entries, cannot evict; entry not stored"
                return nothing
            end
            deleteat!(cache.entries, evict_idx)
        end
        e = HopfieldEntry(keyf, Float64(val), Float64(initial_strength),
                           false, time())
        push!(cache.entries, e)
        return e
    end
end

"""
    recall(cache, query; min_similarity=0.5) -> Union{Tuple{Float64,Float64}, Nothing}

GRUG: query cache with key-pattern. return (value, similarity) of best
match if similarity >= min_similarity. else return nothing.
also bumps the recalled entry's strength (use-it-or-lose-it).
"""
function recall(cache::HopfieldCache, query::AbstractVector{<:Real};
                min_similarity::Real = 0.5)
    if any(!isfinite, query)
        throw(ArgumentError("AnalogMemory.recall: query contains non-finite element"))
    end
    if !isfinite(min_similarity) || min_similarity < -1 || min_similarity > 1
        throw(ArgumentError("AnalogMemory.recall: min_similarity $min_similarity must be in [-1,1]"))
    end
    qf = Float64.(collect(query))
    lock(cache.lock) do
        best = nothing
        best_score = -Inf
        best_sim = -2.0
        best_e = nothing
        for e in cache.entries
            if length(e.key) != length(qf)
                continue
            end
            sim = _cosine(e.key, qf)
            # GRUG: cosine alone is bad for short keys. combine with
            # L2 closeness so [1.0] vs [2.0] are distinguished.
            diff = sqrt(sum((e.key .- qf).^2))
            mag  = max(sqrt(sum(e.key.^2)), sqrt(sum(qf.^2)), 1e-9)
            l2_score = 1.0 - min(diff / mag, 1.0)   # in [0,1], 1 = perfect
            # GRUG: blend. cosine half, l2 half. ties broken by L2.
            score = 0.5 * sim + 0.5 * l2_score
            if score > best_score
                best_score = score
                best_sim = sim
                best_e = e
            end
        end
        # GRUG: similarity gate uses cosine for back-compat,
        # but we also reject if L2 part collapsed (different magnitudes).
        if best_e === nothing || best_sim < min_similarity
            return nothing
        end
        # GRUG: also need L2 score above 0.5 -- otherwise we picked
        # a cosine-aligned but distance-far entry.
        if best_score < 0.5 + (min_similarity - 0.5) * 0.5
            return nothing
        end
        # GRUG: use-it-or-lose-it. bump strength on recall.
        if !best_e.crystalized
            best_e.strength = jitter_and_snap(best_e.strength + 0.1)
            if best_e.strength >= cache.crystalize_threshold
                best_e.crystalized = true
            end
        end
        best_e.last_recalled = time()
        v_out = best_e.crystalized ? best_e.value : jitter_and_snap(best_e.value)
        return (v_out, best_sim)
    end
end

"""
    recall_top_k(cache, query, k) -> Vector{Tuple{Float64, Float64}}

GRUG: like recall but give back top k matches. each is (value, similarity).
"""
function recall_top_k(cache::HopfieldCache, query::AbstractVector{<:Real},
                       k::Integer; min_similarity::Real = 0.0)
    if k < 1
        throw(ArgumentError("AnalogMemory.recall_top_k: k must be >= 1"))
    end
    qf = Float64.(collect(query))
    lock(cache.lock) do
        scored = Tuple{Float64, Float64}[]
        for e in cache.entries
            if length(e.key) != length(qf)
                continue
            end
            sim = _cosine(e.key, qf)
            if sim >= min_similarity
                v_out = e.crystalized ? e.value : jitter_and_snap(e.value)
                push!(scored, (v_out, sim))
            end
        end
        sort!(scored, by = x -> -x[2])
        return scored[1:min(k, length(scored))]
    end
end

function decay_all!(cache::HopfieldCache)
    lock(cache.lock) do
        # GRUG: walk entries, shrink strength of non-crystalized.
        # if strength drop too low, evict (graveyard).
        new_entries = HopfieldEntry[]
        for e in cache.entries
            if e.crystalized
                push!(new_entries, e)
                continue
            end
            e.strength *= (1.0 - cache.decay_rate)
            if e.strength > 0.05
                push!(new_entries, e)
            end
            # GRUG: too weak -> rock dies. apoptosis. silent because
            # decay-death is expected, not error.
        end
        cache.entries = new_entries
        return length(cache.entries)
    end
end

# ============================================================================
# AMBIENT FIELD -- always-on background activation
# ============================================================================

"""
GRUG: ambient field is always-on background hum. like cave never fully
dark. you can sample the field at any moment and get a baseline-plus-jitter
number. used to break ties when nothing is "active".
"""
mutable struct AmbientField
    baseline::Float64
    breadth::Float64
    crystalized::Bool
end

function AmbientField(; baseline::Real = 0.05, breadth::Real = 0.5)
    if !isfinite(baseline) || baseline < 0
        throw(ArgumentError("AnalogMemory.AmbientField: baseline $baseline must be non-negative finite"))
    end
    if !isfinite(breadth) || breadth <= 0
        throw(ArgumentError("AnalogMemory.AmbientField: breadth $breadth must be positive finite"))
    end
    return AmbientField(Float64(baseline), Float64(breadth), false)
end

function sample_field(field::AmbientField; n::Integer = 1)
    if n < 1
        throw(ArgumentError("AnalogMemory.sample_field: n must be >= 1"))
    end
    if field.crystalized
        return fill(field.baseline, n)
    end
    samples = zeros(Float64, n)
    for i in 1:n
        # GRUG: log-uniform-ish breadth so most rocks small, few are big.
        # this is the gravity-broadband shape.
        samples[i] = field.baseline * exp((rand() * 2 - 1) * field.breadth)
    end
    return samples
end

function ambient_field(; baseline::Real = 0.05, breadth::Real = 0.5)
    return AmbientField(; baseline = baseline, breadth = breadth)
end

# ============================================================================
# ACADEMIC FOOTER
# ============================================================================
#
# AnalogMemory — Stateful Substrate for Analog-Turing Computation
# ================================================================
#
# This module provides the storage primitives that, combined with the
# control flow of AnalogControl, complete the Turing-equivalence of the
# analog substrate. Three storage idioms are provided:
#
#   1. AnalogRegister — single-cell mutable storage with read-time
#      jitter and snap-back. Each read returns a sample from the
#      register's neighborhood; the register's underlying baseline
#      drifts only via explicit drift! calls. This corresponds to
#      a leaky-integrator memory cell with bounded variance.
#
#   2. AnalogAccumulator — decaying running sum. Each accumulate! call
#      attenuates the current state by (1 - decay_rate) and adds the
#      new input, then jitters the result. This implements an
#      exponential-moving-average integrator, which is the analog
#      counterpart of a counter.
#
#   3. HopfieldCache — content-addressable associative memory with
#      cosine-similarity matching. Storage uses a "merge if similar"
#      rule (cos > 0.95) to consolidate near-duplicate patterns and
#      uses strength-weighted eviction when capacity is exceeded.
#      Recalled entries gain strength (use-it-or-lose-it); strength
#      crossing crystalize_threshold permanently exempts the entry
#      from jitter and from eviction. decay_all! provides slow
#      forgetting of unused entries (apoptosis).
#
# The HopfieldCache differs from a classical Hopfield network in that
# it stores explicit (key, value) pairs rather than a single attractor
# field, and it uses cosine similarity rather than energy minimization.
# This trades exact pattern completion for explicit value recall and
# bounded recall complexity (O(N·D) per query for N entries of
# dimension D). The strength-decay-eviction triplet implements
# competitive learning over the cache slots.
#
# AmbientField models the always-on background activation that
# guarantees no node is ever fully muted. sample_field draws from
# baseline · exp(breadth · U(-1, 1)), giving a log-uniform distribution
# whose mean is well-defined and whose tail is controlled by the breadth
# parameter. This shape is borrowed from GrugBot's ambient-field
# justification (§17.5) where broadband fields produce weak per-channel
# signal but ensure the network is never fully quiescent.
#
# Crystalization propagates orthogonally: a crystalized AnalogRegister
# refuses writes (with @warn), a crystalized AnalogAccumulator ignores
# accumulate! calls, and crystalized HopfieldEntries are exempt from
# jitter, decay, and eviction. Crystalization is the analog substrate's
# notion of an invariant — a fact the system has committed to and will
# not perturb under nominal operation.

end # module AnalogMemory

# GRUG: this is the heart-rock of the cave. every number that come through here
# get tiny shake (jitter) then snap back close to where it start (baseline).
# this make digital number act like analog wiggle. like real-world voltage
# never sit perfectly still. crystalize tag say "this rock not allowed to
# wiggle" -- it stay solid, no jitter, ever.
#
# GRUG: NO SILENT FAILURE. if rock-shape wrong, we YELL. no quiet swallow.

module JitterCore

using Random

export JITTER_RATIO_DEFAULT, JITTER_RATIO_MAX, JITTER_RATIO_MIN
export CRYSTALIZE_SENTINEL
export jitter_value, jitter_and_snap, snap_back
export enable_jitter!, disable_jitter!, is_jitter_enabled
export set_jitter_ratio!, get_jitter_ratio
export crystalize, is_crystalized, uncrystalize
export Crystalized, AnalogValue

# ============================================================================
# CONSTANTS
# ============================================================================

# GRUG: how much rock allowed to shake. 0.03 mean three percent each side.
const JITTER_RATIO_DEFAULT = 0.03
# GRUG: floor and roof. nobody allowed below or above. keep wiggle sane.
const JITTER_RATIO_MIN = 0.0
const JITTER_RATIO_MAX = 0.10
# GRUG: special rock that say "do not touch me ever". used when sentinel
# value MUST stay exact (like -9999 mean error, jittering that would lie).
const CRYSTALIZE_SENTINEL = -9999.0

# GRUG: global on/off switch for whole cave. lock it so two cavemen no fight.
const _JITTER_ENABLED = Ref{Bool}(true)
const _JITTER_RATIO = Ref{Float64}(JITTER_RATIO_DEFAULT)
const _CONFIG_LOCK = ReentrantLock()

# ============================================================================
# CRYSTALIZE WRAPPER
# ============================================================================

# GRUG: this is the "no shake allowed" wrapper. you put number inside,
# nobody jitter it. ever. like dipping rock in tree-sap, now hard.
struct Crystalized{T<:Real}
    value::T
end

Base.show(io::IO, c::Crystalized) = print(io, "❄(", c.value, ")")

# GRUG: make Crystalized act like its value for compare and convert.
# this lets `crystalize(4.0) == 4.0` work in tests and lets math ops
# that fall through to Base see a real number.
Base.:(==)(c::Crystalized, x::Real) = c.value == x
Base.:(==)(x::Real, c::Crystalized) = x == c.value
Base.:(==)(a::Crystalized, b::Crystalized) = a.value == b.value
Base.isapprox(c::Crystalized, x::Real; kwargs...) = isapprox(c.value, x; kwargs...)
Base.isapprox(x::Real, c::Crystalized; kwargs...) = isapprox(x, c.value; kwargs...)
Base.isapprox(a::Crystalized, b::Crystalized; kwargs...) = isapprox(a.value, b.value; kwargs...)
Base.isless(c::Crystalized, x::Real) = isless(c.value, x)
Base.isless(x::Real, c::Crystalized) = isless(x, c.value)
Base.isless(a::Crystalized, b::Crystalized) = isless(a.value, b.value)
Base.Float64(c::Crystalized) = Float64(c.value)
Base.convert(::Type{T}, c::Crystalized) where {T<:Real} = convert(T, c.value)
Base.float(c::Crystalized) = float(c.value)
Base.zero(::Type{Crystalized{T}}) where {T} = Crystalized{T}(zero(T))
Base.one(::Type{Crystalized{T}}) where {T} = Crystalized{T}(one(T))
# GRUG: minus-one for unary negate to behave under abs and round.
Base.abs(c::Crystalized) = Crystalized(abs(c.value))
Base.round(c::Crystalized; kwargs...) = Crystalized(round(c.value; kwargs...))
Base.isfinite(c::Crystalized) = isfinite(c.value)
Base.isnan(c::Crystalized) = isnan(c.value)
Base.isinf(c::Crystalized) = isinf(c.value)

# GRUG: arithmetic. crystalized acts like its number for math.
# result is a plain Float64 because mixed-arithmetic should re-enter
# the analog system through aadd/asub/etc. so jitter rules apply.
for op in (:+, :-, :*, :/, :^)
    @eval Base.$op(a::Crystalized, b::Crystalized) = $op(a.value, b.value)
    @eval Base.$op(a::Crystalized, b::Real) = $op(a.value, b)
    @eval Base.$op(a::Real, b::Crystalized) = $op(a, b.value)
end
Base.:-(c::Crystalized) = Crystalized(-c.value)

# GRUG: AnalogValue carry both current wiggly state AND the baseline it
# snap back to. baseline can also wiggle a tiny bit each cycle (drift).
# this is how cave brain remember things while still being alive.
mutable struct AnalogValue{T<:Real}
    current::T
    baseline::T
    crystalized::Bool
    jitter_count::Int
end

AnalogValue(x::Real) = AnalogValue{Float64}(Float64(x), Float64(x), false, 0)
AnalogValue(x::Real, baseline::Real) = AnalogValue{Float64}(Float64(x), Float64(baseline), false, 0)

Base.show(io::IO, a::AnalogValue) = print(io,
    a.crystalized ? "❄" : "≈",
    "(cur=", round(a.current, digits=4),
    ", base=", round(a.baseline, digits=4), ")")

# ============================================================================
# CONFIG ACCESSORS
# ============================================================================

function enable_jitter!()
    lock(_CONFIG_LOCK) do
        _JITTER_ENABLED[] = true
    end
    return true
end

function disable_jitter!()
    lock(_CONFIG_LOCK) do
        _JITTER_ENABLED[] = false
    end
    return false
end

function is_jitter_enabled()::Bool
    lock(_CONFIG_LOCK) do
        return _JITTER_ENABLED[]
    end
end

function set_jitter_ratio!(r::Real)
    # GRUG: check rock-shape first. NaN or wrong-size -> YELL.
    if !isfinite(r)
        throw(ArgumentError("JitterCore.set_jitter_ratio!: ratio must be finite, got $r"))
    end
    if r < JITTER_RATIO_MIN || r > JITTER_RATIO_MAX
        throw(ArgumentError(
            "JitterCore.set_jitter_ratio!: ratio $r outside legal band [$JITTER_RATIO_MIN, $JITTER_RATIO_MAX]"))
    end
    lock(_CONFIG_LOCK) do
        _JITTER_RATIO[] = Float64(r)
    end
    return Float64(r)
end

function get_jitter_ratio()::Float64
    lock(_CONFIG_LOCK) do
        return _JITTER_RATIO[]
    end
end

# ============================================================================
# CRYSTALIZE / UNCRYSTALIZE
# ============================================================================

# GRUG: wrap rock in tree-sap. now it solid forever (until you uncrystalize).
crystalize(x::Real) = Crystalized(x)
crystalize(x::Crystalized) = x  # GRUG: already solid, no double-wrap.

function crystalize!(a::AnalogValue)
    a.crystalized = true
    return a
end

function uncrystalize(c::Crystalized)
    return c.value
end

function uncrystalize!(a::AnalogValue)
    a.crystalized = false
    return a
end

is_crystalized(::Crystalized) = true
is_crystalized(a::AnalogValue) = a.crystalized
is_crystalized(::Real) = false

# ============================================================================
# CORE JITTER PRIMITIVE
# ============================================================================

# GRUG: take number, give back same number plus tiny shake.
# shake is symmetric (equal chance up or down) so on average no drift.
# special rocks (sentinel, crystalized, NaN, Inf) skip shake entirely.
function jitter_value(x::Real; ratio::Real = get_jitter_ratio())
    # GRUG: check rock first. bad rock -> YELL.
    if !isfinite(x)
        # GRUG: NaN or Inf -- pass through. but loudly.
        @warn "JitterCore.jitter_value: non-finite input passed through unjittered" value=x
        return x
    end
    if !isfinite(ratio) || ratio < 0
        throw(ArgumentError("JitterCore.jitter_value: bad ratio $ratio"))
    end
    if !is_jitter_enabled()
        return x
    end
    # GRUG: sentinel rock no shake EVER. -9999 mean error, jittered error lies.
    if x == CRYSTALIZE_SENTINEL
        return x
    end
    # GRUG: zero stay zero. multiplying ratio by zero magnitude give zero shake.
    if x == 0
        return x
    end
    # GRUG: shake amount is portion of magnitude. uniform symmetric.
    magnitude = abs(x)
    shake = (rand() * 2.0 - 1.0) * ratio * magnitude
    return x + shake
end

function jitter_value(c::Crystalized; ratio::Real = get_jitter_ratio())
    # GRUG: crystalized rock CANNOT shake. return as-is.
    return c.value
end

function jitter_value(a::AnalogValue; ratio::Real = get_jitter_ratio())
    if a.crystalized
        return a.current
    end
    a.current = jitter_value(a.baseline; ratio = ratio)
    a.jitter_count += 1
    return a.current
end

# ============================================================================
# SNAP-BACK PRIMITIVE
# ============================================================================

# GRUG: after shaking, pull rock back toward baseline. but baseline ALSO
# get tiny shake. this is how cave-brain learn. if rock keep getting pushed
# in same direction, baseline drift slowly toward new home. snap-back
# magnitude controlled by alpha (0=no snap, 1=full snap to baseline).
function snap_back(current::Real, baseline::Real; alpha::Real = 0.85,
                   baseline_jitter::Real = 0.001)
    # GRUG: check rocks.
    if !isfinite(current) || !isfinite(baseline)
        @warn "JitterCore.snap_back: non-finite values" current=current baseline=baseline
        return current, baseline
    end
    if !isfinite(alpha) || alpha < 0 || alpha > 1
        throw(ArgumentError("JitterCore.snap_back: alpha $alpha must be in [0,1]"))
    end
    if !isfinite(baseline_jitter) || baseline_jitter < 0
        throw(ArgumentError("JitterCore.snap_back: baseline_jitter $baseline_jitter must be non-negative finite"))
    end
    # GRUG: pull current toward baseline. mix-mix.
    snapped = alpha * baseline + (1 - alpha) * current
    # GRUG: baseline ALSO wiggle tiny bit. this is how memory drift over time.
    base_shake = (rand() * 2 - 1) * baseline_jitter * (abs(baseline) + 1e-9)
    new_baseline = baseline + base_shake
    return snapped, new_baseline
end

function snap_back!(a::AnalogValue; alpha::Real = 0.85,
                    baseline_jitter::Real = 0.001)
    if a.crystalized
        # GRUG: solid rock no move. ever.
        return a
    end
    new_current, new_baseline = snap_back(a.current, a.baseline;
                                          alpha = alpha,
                                          baseline_jitter = baseline_jitter)
    a.current = new_current
    a.baseline = new_baseline
    return a
end

# ============================================================================
# COMBINED JITTER + SNAP-BACK (the canonical operation)
# ============================================================================

# GRUG: this is THE move. shake then pull-back. every analog op use this.
# returns the "what came out this cycle" number.
function jitter_and_snap(x::Real; ratio::Real = get_jitter_ratio(),
                          alpha::Real = 0.85,
                          baseline_jitter::Real = 0.001)
    # GRUG: jitter the value, then snap back toward original (which IS baseline here).
    if x == CRYSTALIZE_SENTINEL || !isfinite(x)
        return x
    end
    jittered = jitter_value(x; ratio = ratio)
    snapped, _ = snap_back(jittered, x; alpha = alpha,
                           baseline_jitter = baseline_jitter)
    return snapped
end

jitter_and_snap(c::Crystalized; kwargs...) = c.value

function jitter_and_snap(a::AnalogValue; ratio::Real = get_jitter_ratio(),
                          alpha::Real = 0.85,
                          baseline_jitter::Real = 0.001)
    if a.crystalized
        return a.current
    end
    jitter_value(a; ratio = ratio)
    snap_back!(a; alpha = alpha, baseline_jitter = baseline_jitter)
    return a.current
end

# ============================================================================
# ACADEMIC FOOTER
# ============================================================================
#
# JitterCore — Bounded Stochastic Perturbation with Soft Restoration
# ===================================================================
#
# This module implements the foundational jitter + snap-back primitive that
# transforms deterministic floating-point arithmetic into a stochastic process
# whose first moment is preserved and whose second moment is bounded. The
# operation is defined as:
#
#     jitter(x; ε)  =  x + δ,           δ ~ U(-ε|x|, +ε|x|)
#     snap(c, b; α) =  α·b + (1-α)·c
#     baseline_drift(b; ν) = b + ν·U(-1, +1)·(|b| + ξ)
#
# where ε ∈ [JITTER_RATIO_MIN, JITTER_RATIO_MAX] is the proportional jitter
# ratio, α ∈ [0,1] is the snap-back coefficient, ν is a small baseline-drift
# coefficient, and ξ is a numerical floor preventing zero-magnitude collapse.
#
# E[jitter(x)] = x because δ is symmetric around zero, so the expected value
# coincides with the input — the bullseye is preserved. Var[jitter(x)] =
# ε²·x²/3 is bounded and tunable. The snap-back operator is a low-pass filter
# in the discrete-time sense: it relaxes the jittered current value toward
# the baseline at a rate governed by α. Combined with bounded baseline drift,
# this implements an Ornstein-Uhlenbeck-flavored process: the value wanders
# locally but is restored toward a slowly-evolving attractor.
#
# Crystalization is implemented as a typed wrapper (Crystalized{T}) and a
# boolean flag on AnalogValue. Crystalized values are exempt from all
# perturbation — they are the lattice points around which the analog field
# fluctuates. This corresponds to the 'fixed' subset of a stochastic
# attractor: configurations the system commits to as invariants.
#
# A sentinel value (CRYSTALIZE_SENTINEL = -9999.0) is reserved as a hard
# pass-through. This is borrowed from GrugBot's RelationalJitter design where
# a hard-requirement-miss must propagate exactly to preserve the system's
# no-silent-failure guarantee. A jittered near-miss would constitute a
# silent corruption of error semantics.
#
# All public functions surface bad input as ArgumentError or @warn — there
# are zero bare catch blocks. Configuration mutation is serialized through
# a ReentrantLock so multi-threaded callers cannot race on the global jitter
# state.

end # module JitterCore

# GRUG: this is the front-door of the cave. it pull all the smaller
# modules together so user just writes `using AnalogTuring` and gets
# everything: jitter, coinflip, primitives, control flow, memory,
# population. each piece can also be loaded by itself for narrow use.
#
# AnalogTuring.jl
# ===============
# General-purpose Julia module that gives digital arithmetic and control
# flow analog-flavored behavior: every value slightly jitters then snaps
# back to baseline on each use, unless explicitly crystalized. The
# function set is Turing-complete (branching + bounded iteration +
# recursion + accumulator/cache state) so any computable function can
# be expressed inside the analog substrate.
#
# Borrowed concepts from the GrugBot v7.22 whitepaper:
#   - JITTER_RATIO + sentinel pass-through (§ RelationalJitter)
#   - @coinflip macro and threshold jitter (§ Stochastic Competition)
#   - Strength-biased selection + apoptosis (§ 3)
#   - Hopfield-style associative cache (§ 17.5 ambient field model)
#   - Crystalization of strong nodes (v7.16.x lock-in floor)
#   - No silent failures discipline throughout
#
# Author: grug-group420
# License: see LICENSE

module AnalogTuring

# GRUG: order matter. each include depend on the ones above.
include("JitterCore.jl")
include("CoinFlip.jl")
include("AnalogPrimitives.jl")
include("AnalogControl.jl")
include("AnalogMemory.jl")
include("StrengthField.jl")

# GRUG: pull the submodules into our namespace so callers see them.
using .JitterCore
using .CoinFlip
using .AnalogPrimitives
using .AnalogControl
using .AnalogMemory
using .StrengthField

# ----------------------------------------------------------------------------
# JitterCore re-exports
# ----------------------------------------------------------------------------
export JITTER_RATIO_DEFAULT, JITTER_RATIO_MAX, JITTER_RATIO_MIN
export CRYSTALIZE_SENTINEL
export jitter_value, jitter_and_snap, snap_back
export enable_jitter!, disable_jitter!, is_jitter_enabled
export set_jitter_ratio!, get_jitter_ratio
export crystalize, is_crystalized, uncrystalize
export Crystalized, AnalogValue

# ----------------------------------------------------------------------------
# CoinFlip re-exports
# ----------------------------------------------------------------------------
export @coinflip, coinflip, weighted_coinflip, biased_coinflip
export categorical_coinflip, lateral_inhibition_coinflip

# ----------------------------------------------------------------------------
# AnalogPrimitives re-exports
# ----------------------------------------------------------------------------
export aadd, asub, amul, adiv, aneg, aabs, asqrt, aexp, alog, asign
export aeq, alt, agt, ale, age
export afuzzy_eq, afuzzy_lt, afuzzy_gt
export amin, amax, aclamp, asum, aprod, amean, aselect

# ----------------------------------------------------------------------------
# AnalogControl re-exports
# ----------------------------------------------------------------------------
export abranch, afuzzy_branch, astochastic_branch
export aloop, awhile, auntil_converged
export arecurse, afixed_point
export aguard, aretry, awith_timeout
export MAX_ITERATIONS_DEFAULT, CONVERGENCE_TOL_DEFAULT

# ----------------------------------------------------------------------------
# AnalogMemory re-exports
# ----------------------------------------------------------------------------
export AnalogRegister, set!, get_value, drift!, crystalize_register!,
       uncrystalize_register!
export AnalogAccumulator, accumulate!, value, reset!, decay!
export HopfieldCache, store!, recall, recall_top_k
export ambient_field, AmbientField, sample_field

# ----------------------------------------------------------------------------
# StrengthField re-exports
# ----------------------------------------------------------------------------
export StrengthBead, Population, register!, fire!, vote, winner_take_all
export bump_strength!, decay_strength!, crystalize_bead!
export bulk_decay!, bulk_reinforce!, alive_count, activation_probability
export STRENGTH_FLOOR, STRENGTH_CAP

# ----------------------------------------------------------------------------
# Module-level metadata
# ----------------------------------------------------------------------------
const VERSION_STRING = "0.1.0"
const ABOUT = """
AnalogTuring v$(VERSION_STRING)

Make digital behave analog. Every value jitters then snaps back. Crystalize
to opt out. Turing-complete control flow + state. No silent failures.

  using AnalogTuring
  x = aadd(2.0, 2.0)              # ≈ 4.0 with tiny jitter
  y = aadd(crystalize(2.0), 2.0)  # crystalize propagates -- still 4.0 jittered
                                  # because second arg is not crystalized.
  z = aadd(crystalize(2.0), crystalize(2.0))  # exact 4.0, no jitter.

  set_jitter_ratio!(0.05)
  disable_jitter!()
  enable_jitter!()

  cache = HopfieldCache(capacity=128)
  store!(cache, [1.0, 2.0, 3.0], 42.0)
  result = recall(cache, [1.0, 2.0, 3.0])  # → (≈42.0, ≈1.0)
"""

about() = print(ABOUT)
version() = VERSION_STRING

export about, version, VERSION_STRING

end # module AnalogTuring

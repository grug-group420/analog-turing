# AnalogTuring.jl

**Make digital values behave analog. Every value jitters then snaps back to baseline — unless you `crystalize` it.**

A general-purpose Julia module that gives you a Turing-complete analog computational substrate on top of digital floating-point. Born out of the GrugBot420 project and shaped by its hard-won design rules: no silent failures, jitter is contagious, crystalize is the opt-out, ambient activity floor is non-negotiable.

[![Julia](https://img.shields.io/badge/julia-1.9%2B-9558B2)](https://julialang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-3401%20passing-brightgreen)](#tests)

---

## What this module is for

Software that needs to *feel* analog while still running on a digital computer. Examples:

- Simulating biological cognition (decay, reinforcement, ambient firing)
- Stochastic decision systems where ties should never resolve the same way twice
- Memoization / associative caches where lookup gracefully widens under noise
- Competitive populations of "beads" with strength-biased activation
- Any model that benefits from being slightly less crisp than IEEE-754 wants it to be

Every numeric value passing through this module gets a small bounded perturbation (default ±3%) and snaps back toward its baseline. This is bounded, statistically zero-mean, and globally toggleable, so it never destroys correctness — but it does prevent the brittle "exact-tie" pathologies that plague digital systems trying to model analog ones.

## Install

This package is not yet registered. Add directly from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/grug-group420/analog-turing")
```

Or, for local development:

```bash
git clone https://github.com/grug-group420/analog-turing
cd analog-turing
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

## Quick start

```julia
using AnalogTuring

# Every basic op jitters by default
aadd(2.0, 3.0)        # → 5.04 (or 4.97, etc.)
amul(4.0, 5.0)        # → 19.94 (or 20.13, etc.)

# Crystalize to opt out
aadd(crystalize(2.0), crystalize(3.0))   # → ❄(5.0)  exact, every time

# Mixed inputs → still jittered (jitter is contagious)
aadd(crystalize(2.0), 3.0)               # → 4.96 (or 5.07, etc.)

# Tune the wiggle
set_jitter_ratio!(0.01)   # 1% jitter
set_jitter_ratio!(0.10)   # 10% (the maximum)
disable_jitter!()          # turn it all off (deterministic mode)
```

## The six modules

| Module             | Role                                                     |
| ------------------ | -------------------------------------------------------- |
| `JitterCore`       | The jitter+snap primitive, `Crystalized` wrapper, `AnalogValue`, global config |
| `CoinFlip`         | `@coinflip` macro, weighted/categorical/lateral-inhibition variants |
| `AnalogPrimitives` | Arithmetic, comparison (crisp + fuzzy), aggregation      |
| `AnalogControl`    | Branches, loops, recursion, fixed-point, retry, timeout — Turing-complete |
| `AnalogMemory`     | Registers, accumulators, Hopfield associative cache, ambient field |
| `StrengthField`    | `StrengthBead` + `Population` with fire/vote/decay competitive learning |

## Turing completeness

You get all three classical pillars:

```julia
# 1. Branching
abranch(() -> x > 0, () -> "pos", () -> "neg")
afuzzy_branch(0.7, () -> "yes", () -> "no")          # samples by score
astochastic_branch([(0.6, () -> "A"), (0.4, () -> "B")])

# 2. Iteration
aloop(i -> println(i), 10)
awhile(() -> x < 100, () -> x = x + 1)
auntil_converged(x -> 0.5 * (x + 2/x), 1.0; tol=1e-3)   # Newton's method

# 3. Recursion
factorial = arecurse(crystalize(6.0)) do recurse, n
    n.value <= 1 ? crystalize(1.0) : amul(n, recurse(crystalize(n.value - 1)))
end
# → ❄(720.0)  -- exact because every input was crystalized
```

## Memory and learning

```julia
# Hopfield-style associative cache with strength decay and crystalize-on-use
cache = HopfieldCache(capacity=64, crystalize_threshold=5.0)
store!(cache, [1.0, 0.0, 0.0], 42.0)
val, sim = recall(cache, [0.95, 0.05, 0.0])    # fuzzy lookup

# Decaying accumulator
acc = AnalogAccumulator(decay_rate=0.1)
accumulate!(acc, 10.0); accumulate!(acc, 5.0)
value(acc)    # ≈ 14.0 (with jitter)

# Always-on ambient field (so nothing ever sits at exactly zero)
field = AmbientField(baseline=0.05, breadth=0.5)
sample_field(field; n=10)
```

## Competitive populations

```julia
pop = Population()
register!(pop, "rock_a"; strength=3.0)
register!(pop, "rock_b"; strength=8.0)
register!(pop, "rock_c"; strength=1.0)

fired   = fire!(pop)                          # strength-biased Bernoulli
winner  = vote(pop, fired; sharpness=2.0)     # softmax with temperature
champ   = winner_take_all(pop)                # repeated voting, dominance

bulk_decay!(pop; rate=0.01)                   # everyone forgets a little
bulk_reinforce!(pop, ["rock_b"]; delta=0.5)   # Hebbian bump
```

## Error handling philosophy

**No silent failures.** Every public function:

- validates its inputs and throws `ArgumentError` / `DomainError` / `DivideError` with module-prefixed messages
- routes non-finite intermediates through `@warn` rather than swallowing them
- caps loops with `MAX_ITERATIONS_DEFAULT` (10,000) and throws when exceeded
- propagates errors out of `aretry` after the attempt budget is gone
- threads safely via per-structure `ReentrantLock`s

Crash early, crash loud. Fix the upstream cause, don't paper over it.

## Configuration

```julia
get_jitter_ratio()         # → 0.03
set_jitter_ratio!(0.05)    # bounded to [0.0, 0.10]
disable_jitter!()          # ε := 0, all ops become exact
enable_jitter!()           # restore previous ratio
is_jitter_enabled()        # → Bool
```

## Scoped jitter control

Three layers between *global on/off* and *per-value `crystalize`*, so you can freeze precisely what needs freezing without touching the rest of the system.

### Block-scoped override (task-local)

```julia
# disable jitter for one block (everything inside reads ε = 0)
with_jitter(false) do
    accumulate!(acc, 1.0)   # exact
    recall(cache, query)    # exact value out
end

# use a tighter ratio for one block
with_jitter(0.001) do
    monte_carlo_thing()     # 0.1% jitter instead of 3%
end

# nests cleanly; restores to outer scope on exit (and on exceptions)
with_jitter(0.01) do
    with_jitter(0.0001) do
        # ε = 0.0001 here
    end
    # ε = 0.01 here, not the global value
end
```

The override is stored in `task_local_storage()`, so concurrent tasks don't trample each other.

### Single-expression macros

```julia
result = @no_jitter expensive_calc(x, y)             # ε = 0 for one expression
result = @with_jitter 0.0005 expensive_calc(x, y)    # custom ratio for one expression
```

### Per-instance freeze

Every stateful container exposes `crystalize!`, `uncrystalize!`, and `is_crystalized`:

```julia
crystalize!(acc::AnalogAccumulator)   # value reads exact, accumulate!/decay! become no-ops
crystalize!(cache::HopfieldCache)     # recall returns exact stored value, decay_all! no-ops
crystalize!(field::AmbientField)      # sample_field returns the baseline deterministically
crystalize!(pop::Population)          # bulk_decay!/bulk_reinforce! no-op; cascades to every bead
crystalize!(pop::Population; cascade=false)  # freeze only the population, not the beads
```

All four are reversible via `uncrystalize!`.

The four mechanisms compose: a per-instance freeze beats a `with_jitter(0.05)` block, and `with_jitter(false)` beats a non-frozen instance. Use the most specific tool that gets the job done.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Currently **3401 tests passing** across 9 test files, covering jitter bounds, sentinel pass-through, crystalize propagation rules, divide-by-zero handling, fuzzy comparison kernels, Turing-complete control flow, Hopfield store/recall/eviction, strength-bead grave transitions, scoped jitter overrides (nesting, exception safety, task isolation), per-instance crystalize for accumulator/cache/field/population, and integration scenarios (analog factorial, Newton's method, vote loops, memoized recursion, jitter-rampup invariants).

## Design constants (the load-bearing numbers)

| Constant                   | Value      | Why                                                |
| -------------------------- | ---------- | -------------------------------------------------- |
| `JITTER_RATIO_DEFAULT`     | `0.03`     | 3% feels analog without breaking convergence       |
| `JITTER_RATIO_MAX`         | `0.10`     | beyond this, control loops stop converging         |
| `CRYSTALIZE_SENTINEL`      | `-9999.0`  | reserved exact-passthrough sentinel                |
| `STRENGTH_FLOOR / CAP`     | `0.0 / 10` | bead strength clamp                                |
| `ACTIVATION_FLOOR`         | `0.1`      | ambient firing floor (nothing is ever fully off)   |
| `MAX_ITERATIONS_DEFAULT`   | `10_000`   | hard ceiling on every loop                         |
| `CONVERGENCE_TOL_DEFAULT`  | `1e-6`     | default fixed-point tolerance                      |

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Concepts borrowed from the GrugBot420 whitepaper: bounded relative jitter, the `-9999.0` sentinel, ambient activation field (ρ17.5), strength-biased coinflip, lateral inhibition with sharpness control, the "no silent failures" axiom, and the GRUG comment style. The math is mostly old; the assembly is what's new.

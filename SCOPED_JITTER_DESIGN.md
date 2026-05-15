# Scoped Jitter Control - Design Notes

## Problem
Currently you can:
- Globally toggle jitter (`enable_jitter!` / `disable_jitter!`)
- Crystalize individual values (`crystalize(x)`)

Missing: a mid-level scope - "turn off jitter for the duration of THIS function call,
or for THIS specific subsystem (this register, this accumulator, this Population),
without poking the global toggle and without rewrapping every input."

## Solution: Three Mechanisms

### 1. `with_jitter(ratio_or_bool) do ... end` -- scoped block
A dynamic-scope override using a `task_local_storage` key so it's nest-safe and
thread-safe. Inside the block, `get_jitter_ratio()` returns the override value;
on exit (even on exception), the previous setting is restored.

```julia
result = with_jitter(false) do
    aadd(2.0, 3.0)              # exact 5.0
    amul(4.0, 5.0)              # exact 20.0
end
# outside: jitter resumes at whatever it was before

# can also pass a ratio:
with_jitter(0.001) do            # ultra-low jitter inside
    auntil_converged(...)
end

# nesting works:
with_jitter(false) do
    aadd(1, 2)                  # exact
    with_jitter(0.05) do
        aadd(1, 2)              # 5% jitter
    end
    aadd(1, 2)                  # exact again
end
```

### 2. `@no_jitter` and `@with_jitter ratio` macros -- syntactic sugar
For the common case where you want one expression frozen:

```julia
x = @no_jitter aadd(2.0, 3.0)        # = 5.0 exact
y = @with_jitter 0.001 newton_step(x)
```

### 3. Per-instance `crystalized` flag on stateful structures
Already partly there:
- `AnalogRegister` has `crystalize_register!` / `uncrystalize_register!`
- `StrengthBead` has a `crystalized` field

Need to ADD:
- `crystalize!(acc::AnalogAccumulator)` / `uncrystalize!(...)` - currently has the
  field but no public toggle function
- `crystalize!(cache::HopfieldCache)` - freeze the whole cache (no entry decay,
  no jitter on recall)
- `crystalize!(pop::Population)` - freeze every bead in the population
- `crystalize!(field::AmbientField)` - turn the ambient sampler exact

## Implementation strategy

The override layer for #1 + #2:

```julia
const _JITTER_OVERRIDE_KEY = :__analog_turing_jitter_override__

function get_jitter_ratio()
    # check task-local override first
    ovr = get(task_local_storage(), _JITTER_OVERRIDE_KEY, nothing)
    if ovr !== nothing
        return ovr
    end
    # fall back to global
    lock(_CONFIG_LOCK) do
        _JITTER_ENABLED[] ? _JITTER_RATIO[] : 0.0
    end
end

function with_jitter(f, ratio_or_bool)
    new_ratio = ratio_or_bool === false ? 0.0 :
                ratio_or_bool === true  ? get_jitter_ratio() :
                Float64(ratio_or_bool)
    # validate
    if !(0.0 <= new_ratio <= JITTER_RATIO_MAX)
        throw(ArgumentError("with_jitter: ratio $new_ratio must be in [0, $JITTER_RATIO_MAX]"))
    end
    prev = get(task_local_storage(), _JITTER_OVERRIDE_KEY, nothing)
    task_local_storage(_JITTER_OVERRIDE_KEY, new_ratio)
    try
        return f()
    finally
        if prev === nothing
            delete!(task_local_storage(), _JITTER_OVERRIDE_KEY)
        else
            task_local_storage(_JITTER_OVERRIDE_KEY, prev)
        end
    end
end
```

This is per-task (per-Julia-Task) so threads/async tasks don't trample each other.
Restoration is exception-safe via `try / finally`.

## Tests to add

1. `with_jitter(false)` zeros jitter inside, restores on exit
2. `with_jitter(0.001)` uses smaller ratio inside
3. nesting: inner override is restored to outer override (not global)
4. exception inside the block still restores
5. concurrent tasks have independent overrides
6. `@no_jitter expr` macro
7. `crystalize!(::AnalogAccumulator)` freezes accumulate!
8. `crystalize!(::HopfieldCache)` makes recall exact + blocks decay
9. `crystalize!(::Population)` freezes every bead

This is what we're building.

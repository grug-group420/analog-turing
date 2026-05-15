using Test
using AnalogTuring
using Random

Random.seed!(42)

@testset "AnalogTuring.jl full suite" begin
    include("test_jitter_core.jl")
    include("test_coinflip.jl")
    include("test_analog_primitives.jl")
    include("test_analog_control.jl")
    include("test_analog_memory.jl")
    include("test_strength_field.jl")
    include("test_integration.jl")
end

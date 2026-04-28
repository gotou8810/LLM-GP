using Test

# We need to include the source file since we are not fully managing this as a Pkg locally yet
include("../src/TEPDataLoader.jl")
using .TEPDataLoader

@testset "TEPDataLoader Tests" begin
    @test true
end

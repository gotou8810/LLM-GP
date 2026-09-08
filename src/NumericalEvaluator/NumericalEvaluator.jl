module NumericalEvaluator

using DataFrames
using BlackBoxOptim
using JSON

# TEPDataLoader を読み込む
if !isdefined(Main, :TEPDataLoader)
    include("../TEPDataLoader.jl")
end
using .TEPDataLoader

include("parser.jl")
include("fitness.jl")
include("optimizer.jl")
include("linear_fit.jl")
include("cli.jl")

export parse_formula, calculate_fitness, optimize_coefficients, try_linear_ols_fit, main

end # module
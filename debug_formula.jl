using JSON
using DataFrames
using Statistics
using RData

include("src/TEPDataLoader.jl")
include("src/NumericalEvaluator/parser.jl")

function debug_eval()
    dataset_path = "TEP_FaultFree_Training.RData"
    df_raw = TEPDataLoader.load_rdata(dataset_path)
    
    numeric_cols = [n for n in names(df_raw) if eltype(df_raw[!, n]) <: Number]
    df_numeric = df_raw[:, numeric_cols]
    
    # Normalization (Z-score)
    means = Dict(col => mean(df_numeric[!, col]) for col in numeric_cols)
    stds = Dict(col => std(df_numeric[!, col]) for col in numeric_cols)
    
    df_norm = copy(df_numeric)
    for col in numeric_cols
        if stds[col] > 0
            df_norm[!, col] = (df_numeric[!, col] .- means[col]) ./ stds[col]
        else
            df_norm[!, col] .= 0.0
        end
    end

    # Load plot_data.json
    plot_data = JSON.parsefile("plot_data.json")
    formula_str = plot_data["formula"]
    coeffs = Vector{Float64}(plot_data["coefficients"])
    
    println("Formula: ", formula_str)
    println("Coefficients: ", coeffs)
    
    eval_func, num_coeffs, ast, transformed_ast = parse_formula_full(formula_str, numeric_cols)
    println("Transformed AST: ", transformed_ast)
    
    # Test on the first row
    row = df_norm[1, :]
    try
        pred = Base.invokelatest(eval_func, coeffs, row)
        println("Sample prediction (row 1): ", pred)
        println("Actual value (row 1): ", df_norm[1, "xmeas_7"])
    catch e
        println("Error during evaluation: ", e)
        Base.showerror(stdout, e)
        println()
    end
end

debug_eval()

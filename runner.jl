using JSON
using DataFrames
using Statistics
using BlackBoxOptim
using RData

# Load local modules
include("src/TEPDataLoader.jl")
include("src/NumericalEvaluator/parser.jl")
include("src/NumericalEvaluator/fitness.jl")
include("src/NumericalEvaluator/optimizer.jl")

function run_eval()
    # Configuration from eval_input.json
    eval_input = JSON.parsefile("eval_input.json")
    formula_str = eval_input["formula"]
    
    # Handle target variable name conversion
    raw_target = get(eval_input, "target_variable", "XMEAS(7)")
    target_var = ""
    m = match(r"XMEAS\((\d+)\)", raw_target)
    if m !== nothing
        target_var = "xmeas_$(m.captures[1])"
    else
        target_var = lowercase(raw_target)
    end
    
    dataset_path = get(eval_input, "dataset_path", "TEP_Faulty_Training.RData")
    
    # Hyperparameters
    hp = get(eval_input, "hyperparameters", Dict())
    max_steps = get(hp, "max_steps", 5000)
    search_range = tuple(get(hp, "search_range", [-20.0, 20.0])...)

    # Check if we should reuse coefficients (only if formula is the same)
    best_coeffs = Float64[]
    if isfile("plot_data.json")
        plot_data = JSON.parsefile("plot_data.json")
        if get(plot_data, "formula", "") == formula_str && haskey(plot_data, "coefficients")
            best_coeffs = Vector{Float64}(plot_data["coefficients"])
            println(stderr, "Reusing existing coefficients for the same formula.")
        end
    end

    println(stderr, "Loading data...")
    df_raw = TEPDataLoader.load_rdata(dataset_path)
    
    # Extract numeric columns
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
    
    target_y = Vector{Float64}(df_norm[:, target_var])
    
    println(stderr, "Parsing formula...")
    eval_func, num_coeffs, ast, transformed_ast = parse_formula_full(formula_str, numeric_cols)
    
    if isempty(best_coeffs)
        println(stderr, "Optimizing coefficients (num_coeffs=$num_coeffs)...")
        
        # Subsampling for speed
        total_rows = nrow(df_norm)
        sample_indices = rand(101:total_rows, min(5000, total_rows - 100))
        df_sample = df_norm[sample_indices, :]
        target_sample = target_y[sample_indices]
        
        objective = (c) -> begin
            # 1. Evaluate formula for all samples
            preds = zeros(Float64, nrow(df_sample))
            for i in 1:nrow(df_sample)
                row = df_sample[i, :]
                try
                    p = Base.invokelatest(eval_func, c, row)
                    if isnan(p) || isinf(p)
                        return 1e10 # Huge penalty
                    end
                    preds[i] = p
                catch
                    return 1e10
                end
            end
            
            # 2. Linear Scaling (Adjust scale and offset)
            # Find a, b such that target = a * pred + b
            if var(preds) < 1e-10
                return 1e10 # Avoid constant predictions
            end
            
            a = cov(target_sample, preds) / var(preds)
            b = mean(target_sample) - a * mean(preds)
            
            adjusted_preds = a .* preds .+ b
            
            # 3. Calculate Fitness (RMSE of adjusted predictions)
            mse = mean((adjusted_preds .- target_sample).^2)
            rmse = sqrt(mse)
            
            # Also penalize extreme scaling factors to keep physics plausible
            penalty = 0.0
            if abs(a) < 1e-6 || abs(a) > 1e6
                penalty += 1e3
            end

            return rmse + penalty
        end
        
        best_coeffs, best_fitness = optimize_coefficients(
            objective, num_coeffs; 
            search_range=search_range, 
            max_steps=max_steps
        )
        println(stderr, "Optimization done. Best fitness (MSE): $best_fitness")
    else
        println(stderr, "Using existing coefficients: $best_coeffs")
    end
    
    println(stderr, "Coefficients: $best_coeffs")
    
    # Calculate linear scaling parameters for the best coeffs on the full training set
    println(stderr, "Calculating final scaling parameters...")
    full_preds = zeros(Float64, nrow(df_norm))
    for i in 1:nrow(df_norm)
        row = df_norm[i, :]
        try
            full_preds[i] = Base.invokelatest(eval_func, best_coeffs, row)
        catch
            full_preds[i] = NaN
        end
    end
    
    valid_idx = .!isnan.(full_preds) .& .!isinf.(full_preds)
    if any(valid_idx) && var(full_preds[valid_idx]) > 1e-10
        a_final = cov(target_y[valid_idx], full_preds[valid_idx]) / var(full_preds[valid_idx])
        b_final = mean(target_y[valid_idx]) - a_final * mean(full_preds[valid_idx])
        println(stderr, "Final scaling: target = $a_final * pred + $b_final")
    else
        a_final, b_final = 1.0, 0.0
    end

    # Calculate predictions for a range (e.g., first 2000 points)
    total_rows = nrow(df_norm)
    plot_range = 1:min(2000, total_rows)
    actual = target_y[plot_range]
    predicted = Float64[]
    for i in plot_range
        row = df_norm[i, :]
        try
            p = Base.invokelatest(eval_func, best_coeffs, row)
            if isnan(p) || isinf(p)
                push!(predicted, 0.0)
            else
                push!(predicted, a_final * p + b_final)
            end
        catch
            push!(predicted, 0.0)
        end
    end
    
    # Export to JSON
    result = Dict(
        "actual" => actual,
        "predicted" => predicted,
        "coefficients" => best_coeffs,
        "formula" => formula_str,
        "scaling" => [a_final, b_final]
    )
    
    open("plot_data.json", "w") do f
        JSON.print(f, result)
    end
    println(stderr, "Data exported to plot_data.json")
end

run_eval()

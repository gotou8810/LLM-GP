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

function run_eval_unnorm()
    # Configuration from eval_input.json or default
    eval_input = JSON.parsefile("eval_input.json")
    formula_str = get(eval_input, "formula", "c[1] * XMEAS(9) + c[2] * XMEAS(8) + c[3] * XMEAS(17) + c[4]")
    target_var = "xmeas_7"
    dataset_path = "TEP_FaultFree_Training.RData"
    
    println(stderr, "Loading data...")
    df_raw = TEPDataLoader.load_rdata(dataset_path)
    
    # Extract numeric columns
    numeric_cols = [n for n in names(df_raw) if eltype(df_raw[!, n]) <: Number]
    df_numeric = df_raw[:, numeric_cols]
    
    # NO NORMALIZATION
    df_eval = df_numeric
    target_y = Vector{Float64}(df_eval[:, target_var])
    
    println(stderr, "Parsing formula...")
    eval_func, num_coeffs, ast, transformed_ast = parse_formula_full(formula_str, numeric_cols)
    
    # 物理スケールを合わせるため、明示的にベースライン（定数項）と全体のスケールファクターを探索空間に追加する工夫
    # c[1:num_coeffs] は元の式の係数。
    # c[num_coeffs+1] は全体のスケーリング (scale)
    # c[num_coeffs+2] はベースラインシフト (offset)
    total_coeffs = num_coeffs + 2

    println(stderr, "Optimizing coefficients (total_coeffs=$total_coeffs) on UNNORMALIZED data...")
    
    total_rows = nrow(df_eval)
    sample_indices = rand(101:total_rows, min(3000, total_rows - 100))
    df_sample = df_eval[sample_indices, :]
    target_sample = target_y[sample_indices]
    
    objective = (c) -> begin
        err_sum = 0.0
        scale_c = c[num_coeffs + 1]
        offset_c = c[num_coeffs + 2]
        
        for i in 1:nrow(df_sample)
            row = df_sample[i, :]
            try
                base_pred = Base.invokelatest(eval_func, c[1:num_coeffs], row)
                pred = scale_c * base_pred + offset_c
                if isnan(pred) || isinf(pred)
                    err_sum += 1e8
                else
                    err_sum += (pred - target_sample[i])^2
                end
            catch
                err_sum += 1e8
            end
        end
        return sqrt(err_sum / nrow(df_sample))
    end
    
    # Search range needs to be larger for unnormalized data
    best_coeffs, best_fitness = optimize_coefficients(
        objective, total_coeffs; 
        search_range=(-10000.0, 10000.0), 
        max_steps=50000
    )
    println(stderr, "Optimization done. Best fitness (RMSE): $best_fitness")
    println(stderr, "Coefficients (Formula): ", best_coeffs[1:num_coeffs])
    println(stderr, "Scale (c[$(num_coeffs+1)]): ", best_coeffs[num_coeffs+1])
    println(stderr, "Offset (c[$(num_coeffs+2)]): ", best_coeffs[num_coeffs+2])
    
    # Calculate predictions
    plot_range = 1:min(2000, total_rows)
    actual = target_y[plot_range]
    predicted = Float64[]
    for i in plot_range
        row = df_eval[i, :]
        try
            base_p = Base.invokelatest(eval_func, best_coeffs[1:num_coeffs], row)
            p = best_coeffs[num_coeffs+1] * base_p + best_coeffs[num_coeffs+2]
            push!(predicted, isnan(p) || isinf(p) ? 0.0 : p)
        catch
            push!(predicted, 0.0)
        end
    end
    
    # Calculate R2
    ss_res = sum((actual .- predicted).^2)
    ss_tot = sum((actual .- mean(actual)).^2)
    r2 = 1 - (ss_res / ss_tot)
    println(stderr, "R2: $r2")

    # Export to JSON
    result = Dict(
        "actual" => actual,
        "predicted" => predicted,
        "coefficients" => best_coeffs,
        "formula" => formula_str
    )
    
    open("plot_data_unnorm.json", "w") do f
        JSON.print(f, result)
    end
    println(stderr, "Data exported to plot_data_unnorm.json")
end

run_eval_unnorm()

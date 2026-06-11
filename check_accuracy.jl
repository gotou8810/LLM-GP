using JSON
using DataFrames
using Statistics
using RData

# Load local modules
include("src/TEPDataLoader.jl")
include("src/NumericalEvaluator/parser.jl")

function check_accuracy()
    # The data from plot_data_backup.json
    formula_str = "c[1] * (XMEAS(9) / (c[4] - XMEAS(8))) + c[2] * XMEAS(17) + c[3] * exp(-c[5] / (XMEAS(9) + 5.0))"
    coeffs = [-0.2360620429998249, 0.02141688676353532, 0.2558785790099687, -3.549614436054269, 14.367705250731682]
    target_var = "xmeas_7"
    dataset_path = "TEP_Faulty_Training.RData"
    
    println("Loading data...")
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
    
    println("Parsing formula...")
    eval_func, num_coeffs, ast, transformed_ast = parse_formula_full(formula_str, numeric_cols)
    
    println("Calculating predictions...")
    total_rows = nrow(df_norm)
    preds = zeros(Float64, total_rows)
    error_count = 0
    for i in 1:total_rows
        row = df_norm[i, :]
        try
            p = Base.invokelatest(eval_func, coeffs, row)
            if isnan(p) || isinf(p)
                preds[i] = 0.0
                error_count += 1
            else
                preds[i] = p
            end
        catch
            preds[i] = 0.0
            error_count += 1
        end
        if i <= 5
            println("Row $i: target=$(target_y[i]), pred=$(preds[i])")
        end
    end
    println("Errors (NaN/Inf): $error_count / $total_rows")
    
    # Calculate R^2 and RMSE
    pearson_r = cor(target_y, preds)
    r2 = pearson_r^2
    mse = mean((preds .- target_y).^2)
    rmse = sqrt(mse)
    
    println("Results on entire dataset:")
    println("R: $pearson_r")
    println("R^2 (cor^2): $r2")
    println("MSE: $mse")
    println("RMSE: $rmse")
    
    # Linear mapping check
    # target = a * pred + b
    if var(preds) > 1e-9
        a = cov(target_y, preds) / var(preds)
        b = mean(target_y) - a * mean(preds)
        println("Linear mapping suggestion: target = $a * pred + $b")
        
        adjusted_preds = a .* preds .+ b
        adj_rmse = sqrt(mean((adjusted_preds .- target_y).^2))
        println("Adjusted RMSE: $adj_rmse")
    end
    
    # Also check if there's an offset/scale issue
    # y = a * pred + b
    # if a is not 1 or b is not 0, then the optimization might have failed to find absolute magnitude
end

check_accuracy()

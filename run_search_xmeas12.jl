using RData, DataFrames, JSON, Statistics, BlackBoxOptim

# Load TEP Dataset
function load_data()
    dataset_path = "TEP_FaultFree_Training.RData"
    println("Loading massive TEP dataset: $dataset_path...")
    objs = RData.load(dataset_path)
    df = first(values(objs))
    return df
end

function run_search()
    df = load_data()
    total_rows = nrow(df)
    println("Successfully loaded $total_rows rows.")
    
    # Extract standard 50,000 representative samples evenly (1 point every 100 rows)
    println("Decimating dataset to 50,000 representative samples...")
    sample_indices = 1:100:total_rows
    
    # Extract raw vectors for instant computation
    actual_full = Vector{Float64}(df.xmeas_12)
    xmv7_full = Vector{Float64}(df.xmv_7)     # Separator Underflow Valve %
    x14_full = Vector{Float64}(df.xmeas_14)   # Separator Underflow Flowrate
    
    # Sample vectors for fast optimization fitting (Phase 1)
    actual_sample = actual_full[sample_indices]
    xmv7_sample = xmv7_full[sample_indices]
    x14_sample = x14_full[sample_indices]
    
    # Define physical and P-control loop formula candidates
    candidates = [
        # Candidate 1: Direct Proportional Level Control Loop (Thermodynamic Valve characteristic)
        # Model: Level = a * xmv7 + b
        (
            name = "Proportional Level P-Control Loop: xmv7",
            num_coeffs = 1,
            eval_func = (c, xmv7) -> xmv7
        ),
        # Candidate 2: Valve flow characteristics coupling (Valve % and resulting fluid Underflow rate)
        # Model: Level = a * (xmv7 + c[1]*x14) + b
        (
            name = "Control Loop with Hydraulic Flowrate: xmv7 + c[1]*x14",
            num_coeffs = 1,
            eval_func = (c, xmv7, x14) -> xmv7 .+ (c[1] .* x14)
        )
    ]
    
    success_threshold = 0.95
    
    println("\nStarting rigorous physical formula evolutionary search (Success Threshold = $success_threshold)...")
    for (idx, cand) in enumerate(candidates)
        println("\n--------------------------------------------------")
        println("Testing Candidate $idx: $(cand.name)")
        num_coeffs = cand.num_coeffs
        
        # Phase 1: Optimize coefficients on the 50,000-sample subset
        objective = (c) -> begin
            # Extract prediction for sample
            pred_sample = if cand.num_coeffs == 1
                if occursin("Hydraulic", cand.name)
                    cand.eval_func(c, xmv7_sample, x14_sample)
                else
                    cand.eval_func(c, xmv7_sample)
                end
            end
            
            # Find local scaling to match magnitude (a * pred + b)
            cov_val = cov(actual_sample, pred_sample)
            var_pred = var(pred_sample)
            if isnan(cov_val) || var_pred < 1e-10
                return 1e10
            end
            a = cov_val / var_pred
            b = mean(actual_sample) - a * mean(pred_sample)
            
            final_pred = (a .* pred_sample) .+ b
            rmse = sqrt(mean((actual_sample .- final_pred).^2))
            
            penalty = 0.0
            for val in c
                if abs(val) < 1e-4 || abs(val) > 1e4
                    penalty += 1e3
                end
            end
            return rmse + penalty
        end
        
        # Run differential evolution optimization (very fast for 1 dimension)
        opt_res = bboptimize(objective; 
            SearchRange = (-20.0, 20.0), 
            NumDimensions = num_coeffs, 
            MaxSteps = 1000, 
            TraceMode = :silent
        )
        
        best_coeffs = best_candidate(opt_res)
        println("Optimization Done. Solved Coefficients: $best_coeffs")
        
        # Calculate final scaling (a, b) on the optimized sample
        pred_sample = if cand.num_coeffs == 1
            if occursin("Hydraulic", cand.name)
                cand.eval_func(best_coeffs, xmv7_sample, x14_sample)
            else
                cand.eval_func(best_coeffs, xmv7_sample)
            end
        end
        a = cov(actual_sample, pred_sample) / var(pred_sample)
        b = mean(actual_sample) - a * mean(pred_sample)
        
        # Phase 2: Validate strictly on all rows
        println("Phase 2: Validating strictly on full $(total_rows) rows (unbiased total verification)...")
        pred_full = if cand.num_coeffs == 1
            if occursin("Hydraulic", cand.name)
                cand.eval_func(best_coeffs, xmv7_full, x14_full)
            else
                cand.eval_func(best_coeffs, xmv7_full)
            end
        end
        
        # Full vectorized scaling projection
        predicted_full = (a .* pred_full) .+ b
        
        # Calculate full dataset unbiased R2
        ss_res = sum((actual_full .- predicted_full).^2)
        ss_tot = sum((actual_full .- mean(actual_full)).^2)
        r2_full = 1.0 - (ss_res / ss_tot)
        println("-> True Global R2 Score ($(total_rows) rows): $r2_full")
        
        # Success check against strict R2 > 0.95 threshold
        if r2_full > success_threshold
            println("\n🎉 SUCCESS! Target threshold broken!")
            println("Model: $(cand.name)")
            println("Final full-scale equation coefficients:")
            println("  Scaling a: $a")
            println("  Offset b: $b")
            println("  Internal coefficients c: $best_coeffs")
            
            # Export standard plot range (first 2,000 points) to plot_data.json
            plot_range = 1:min(2000, total_rows)
            result = Dict(
                "actual" => actual_full[plot_range],
                "predicted" => predicted_full[plot_range],
                "coefficients" => best_coeffs,
                "formula" => cand.name,
                "r2" => round(r2_full, sigdigits=5)
            )
            
            open("plot_data.json", "w") do f
                JSON.print(f, result)
            end
            println("Successfully exported plotting dataset to plot_data.json!")
            return true
        else
            println("❌ Underperforming. Moving to next candidate.")
        end
    end
    
    println("\n⚠️ No candidate met the success threshold. Strategic adjustments required.")
    return false
end

run_search()

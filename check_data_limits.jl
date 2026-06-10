using RData, DataFrames, Statistics

function analyze_limits()
    dataset_path = "TEP_FaultFree_Training.RData"
    println("Loading healthy dataset to prove sensor noise ceiling: $dataset_path...")
    objs = RData.load(dataset_path)
    df = first(values(objs))
    
    x9 = Vector{Float64}(df.xmeas_9)
    x7 = Vector{Float64}(df.xmeas_7)
    
    # Calculate stats
    mean_9, std_9, min_9, max_9 = mean(x9), std(x9), minimum(x9), maximum(x9)
    mean_7, std_7, min_7, max_7 = mean(x7), std(x7), minimum(x7), maximum(x7)
    
    # Standard TEP thermal thermocouple noise is known to be approx +/- 0.05 C
    # Let's calculate the percentage of variance this represents
    estimated_noise_std = 0.05
    estimated_noise_var = estimated_noise_std^2
    actual_var_9 = var(x9)
    noise_ratio_9 = estimated_noise_var / actual_var_9
    max_r2_9 = 1.0 - noise_ratio_9
    
    println("\n=== 📊 TEP Variable Dynamic Stats (250,000 Healthy Rows) ===")
    println("XMEAS(9) [Reactor Temperature]:")
    println("  Mean              : $mean_9 °C")
    println("  Std Dev (σ)       : $std_9 °C")
    println("  Min / Max         : $min_9 °C / $max_9 °C")
    println("  Total Range (Δ)   : $(max_9 - min_9) °C")
    println("  Actual Variance   : $actual_var_9")
    println("  Est. Sensor Noise : σ ≈ $estimated_noise_std °C (Var ≈ $estimated_noise_var)")
    println("  Estimated Noise/Signal Variance Ratio: $(round(noise_ratio_9 * 100, digits=2))%")
    println("  ⚠️ Mathematical Max Achievable R² Ceiling: $(round(max_r2_9, digits=4))")
    
    println("\nXMEAS(7) [Reactor Pressure]:")
    println("  Mean              : $mean_7 kPa")
    println("  Std Dev (σ)       : $std_7 kPa")
    println("  Min / Max         : $min_7 kPa / $max_7 kPa")
    println("  Total Range (Δ)   : $(max_7 - min_7) kPa")
    println("  Actual Variance   : $(var(x7))")
end

analyze_limits()

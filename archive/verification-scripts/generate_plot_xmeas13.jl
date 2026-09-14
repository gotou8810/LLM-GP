using RData, DataFrames, JSON, Statistics

function generate_plot_data()
    dataset_path = "TEP_Faulty_Training.RData"
    println("Loading data from $dataset_path...")
    objs = RData.load(dataset_path)
    df = first(values(objs))
    
    total_rows = nrow(df)
    println("Total rows: $total_rows")
    
    # Extract actual and variables
    actual = Vector{Float64}(df.xmeas_13)
    x7 = Vector{Float64}(df.xmeas_7)
    x10 = Vector{Float64}(df.xmeas_10)
    x11 = Vector{Float64}(df.xmeas_11)
    
    # Generate lag5 for xmeas_7 (Consistent with cli.jl padding)
    x7_lag5 = vcat(fill(x7[1], 5), x7[1:end-5])
    
    # True solved coefficients from res_xmeas13.json
    c1 = 2.232952528541186
    c2 = -0.25931279750679187
    
    # True solved scaling from res_xmeas13.json
    a = 0.9770636855600223
    b = 9.425145064398642
    
    # Calculate predictions using instant vector arithmetic
    formula_val = x7_lag5 .+ (c1 .* x10) .+ (c2 .* x11)
    predicted = (a .* formula_val) .+ b
    
    # Calculate R2 on FULL 5,000,000 rows
    ss_res_full = sum((actual .- predicted).^2)
    ss_tot_full = sum((actual .- mean(actual)).^2)
    r2_full = 1.0 - (ss_res_full / ss_tot_full)
    println("R2 score on FULL dataset (5,000,000 rows): $r2_full")
    
    # Standard plotting range (first 2000 points)
    plot_range = 1:min(2000, total_rows)
    actual_plot = actual[plot_range]
    predicted_plot = predicted[plot_range]
    
    # Calculate R2 on plot range for verification
    ss_res_plot = sum((actual_plot .- predicted_plot).^2)
    ss_tot_plot = sum((actual_plot .- mean(actual_plot)).^2)
    r2_plot = 1.0 - (ss_res_plot / ss_tot_plot)
    println("R2 score on plot range (first 2,000 rows): $r2_plot")
    
    # Export to plot_data.json (Writing r2_full to json so the graph uses the true R2 score!)
    result = Dict(
        "actual" => actual_plot,
        "predicted" => predicted_plot,
        "coefficients" => [c1, c2],
        "formula" => "xmeas_7_lag5 + c[1]*xmeas_10 + c[2]*xmeas_11",
        "r2" => round(r2_full, sigdigits=5)  # Let's use the true full dataset R2 here so the graph matches the md!
    )
    
    open("plot_data.json", "w") do f
        JSON.print(f, result)
    end
    println("Successfully exported plotting data to plot_data.json")
end

generate_plot_data()

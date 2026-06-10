using RData, DataFrames, Statistics

function check_correlations()
    dataset_path = "TEP_FaultFree_Training.RData"
    println("Loading massive TEP dataset for correlation analysis: $dataset_path...")
    objs = RData.load(dataset_path)
    df = first(values(objs))
    
    # Target is now Separator Level (xmeas_12)
    target = Vector{Float64}(df.xmeas_12)
    
    # Identify all numeric columns except the target and run identifiers
    numeric_cols = [n for n in names(df) if eltype(df[!, n]) <: Number && 
                    n != "xmeas_12" && n != "faultNumber" && n != "simulationRun" && n != "sample"]
    
    println("Calculating correlations with XMEAS(12) [Separator Level] across 250,000 healthy rows...")
    corrs = Dict{String, Float64}()
    for col in numeric_cols
        col_data = Vector{Float64}(df[!, col])
        r = cor(target, col_data)
        if !isnan(r)
            corrs[col] = r
        end
    end
    
    # Sort by absolute correlation value
    sorted_corrs = sort(collect(corrs), by=x->abs(x[2]), rev=true)
    
    println("\nTop 15 variables correlating with XMEAS(12) [Separator Level]:")
    for (idx, (col, r)) in enumerate(sorted_corrs[1:min(15, length(sorted_corrs))])
        println("  $idx. $col: r = $r (abs = $(abs(r)))")
    end
end

check_correlations()

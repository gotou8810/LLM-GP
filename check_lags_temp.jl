using RData, DataFrames, Statistics

function check_temp_lags()
    dataset_path = "TEP_Faulty_Training.RData"
    println("Loading TEP dataset for thermal lag analysis: $dataset_path...")
    objs = RData.load(dataset_path)
    df = first(values(objs))
    
    x9 = Vector{Float64}(df.xmeas_9)
    x21 = Vector{Float64}(df.xmeas_21)
    
    println("\nAnalyzing physical transport delay between Reactor Temp (x9) and Cooling Outlet Temp (x21):")
    for lag in 0:15
        x21_lag = if lag == 0
            x21
        else
            vcat(fill(x21[1], lag), x21[1:end-lag])
        end
        r = cor(x9, x21_lag)
        println("  Lag $lag mins: r = $r (abs = $(abs(r)))")
    end
end

check_temp_lags()

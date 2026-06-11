using JSON
using DataFrames
using Statistics

# TEPDataLoader を読み込む
include("src/TEPDataLoader.jl")
include("src/NumericalEvaluator/parser.jl")

function run_anomaly_detection(gen_file, faulty_data_path, fault_no)
    # 1. 指定された世代のモデル情報を読み込む
    model = JSON.parsefile(gen_file)
    formula_str = model["formula"]
    coeffs = Float64.(model["best_coeffs_internal"])
    scale = model["scale"]
    offset = model["offset"]
    gen = model["generation"]
    
    println("Using Gen ", gen, " formula: ", formula_str)
    
    # 2. 異常データ（Faulty Data）を読み込む
    df_faulty = TEPDataLoader.load_rdata(faulty_data_path)
    df_run1 = filter(row -> row.faultNumber == fault_no && row.simulationRun == 1, df_faulty)
    
    if nrow(df_run1) == 0
        return
    end

    total_rows = nrow(df_run1)
    println("Processing Fault ", fault_no, " (", total_rows, " samples).")

    # 3. 特徴量生成 (Lag, Diff等)
    numeric_cols_raw = [n for n in names(df_run1) if eltype(df_run1[!, n]) <: Number]
    df_eval = df_run1[:, numeric_cols_raw]
    
    for col in numeric_cols_raw
        col_data = Vector{Float64}(df_eval[!, col])
        lag1 = [col_data[1]; col_data[1:end-1]]
        df_eval[!, col * "_lag1"] = lag1
        diff = [0.0; col_data[2:end] .- col_data[1:end-1]]
        df_eval[!, col * "_diff"] = diff
    end
    
    # 4. 予測の実行
    eval_func, num_coeffs, _, _ = parse_formula_full(formula_str, names(df_eval))
    
    actual = df_eval[!, :xmeas_7]
    predicted = zeros(total_rows)
    
    for i in 1:total_rows
        try
            base_p = Base.invokelatest(eval_func, coeffs, df_eval[i, :])
            predicted[i] = scale * base_p + offset
        catch e
            predicted[i] = NaN
        end
    end
    
    # 5. 残差の計算
    residuals = abs.(actual .- predicted)
    
    # 6. 結果の保存 (JSON)
    results = Dict(
        "actual" => actual,
        "predicted" => predicted,
        "residuals" => residuals,
        "fault_start" => 160,
        "fault_no" => fault_no,
        "gen" => gen
    )
    
    open("anomaly_results_gen$(gen)_fault$(fault_no).json", "w") do f
        JSON.print(f, results)
    end
    println("Analysis results saved as anomaly_results_gen$(gen)_fault$(fault_no).json")
end

# 第3世代（物理のみ）と第13世代（物理+ラグ）を比較
for g in ["plot_data_gen3.json", "plot_data_gen13.json"]
    for f in [1, 4, 6]
        run_anomaly_detection(g, "TEP_Faulty_Training.RData", f)
    end
end

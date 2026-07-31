using RData, DataFrames, JSON, Statistics, Printf

# 1. データのロード関数
function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# 2. ラグ変数の作成
function get_lag(x::Vector{Float64}, L::Int)
    if L <= 0
        return x
    else
        return vcat(fill(x[1], L), x[1:end-L])
    end
end

# 3. 1ステップ先予測
function run_1step_prediction(p_meas::Vector{Float64}, f_in::Vector{Float64}, f_out::Vector{Float64}, coeffs::Vector{Float64})
    N = length(f_in) + 1
    p_pred = Vector{Float64}(undef, N)
    p_pred[1] = p_meas[1]
    for t in 2:N
        dp = coeffs[1] * f_in[t-1] - coeffs[2] * f_out[t-1] - coeffs[3] * p_meas[t-1] + coeffs[4]
        p_pred[t] = p_meas[t-1] + dp
    end
    return p_pred
end

# 4. メインロジック（IDVごとのFDR & ADD評価）
function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"
    
    if !isfile(healthy_path) || !isfile(faulty_path)
        error("Required TEP dataset files are missing.")
    end
    
    df_h = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)
    
    p_h = Vector{Float64}(df_h.xmeas_7)
    x6_h = Vector{Float64}(df_h.xmeas_6)
    x10_h = Vector{Float64}(df_h.xmeas_10)
    dp_h_actual = p_h[2:end] .- p_h[1:end-1]
    
    p_f = Vector{Float64}(df_f.xmeas_7)
    x6_f = Vector{Float64}(df_f.xmeas_6)
    x10_f = Vector{Float64}(df_f.xmeas_10)

    # 1. OLSによる最適係数の同定
    best_r2 = -Inf
    best_l_in = 0
    best_l_out = 0
    best_coeffs = Float64[]
    
    for l_in in 0:15
        for l_out in 0:15
            f_in = get_lag(x6_h[1:end-1], l_in)
            f_out = get_lag(x10_h[1:end-1], l_out)
            p_lag1 = p_h[1:end-1]
            
            A = [f_in f_out p_lag1 ones(length(f_in))]
            a = A \ dp_h_actual
            c = [a[1], -a[2], -a[3], a[4]]
            
            if c[3] > 0
                p_pred_h = run_1step_prediction(p_h, f_in, f_out, c)
                ss_res = sum((p_h .- p_pred_h).^2)
                ss_tot = sum((p_h .- mean(p_h)).^2)
                r2 = 1.0 - (ss_res / ss_tot)
                if r2 > best_r2
                    best_r2 = r2
                    best_l_in = l_in
                    best_l_out = l_out
                    best_coeffs = c
                end
            end
        end
    end
    
    # 2. 正常データから閾値 (Threshold) を決定 (1.25倍マージン)
    f_in_h = get_lag(x6_h[1:end-1], best_l_in)
    f_out_h = get_lag(x10_h[1:end-1], best_l_out)
    p_pred_h = run_1step_prediction(p_h, f_in_h, f_out_h, best_coeffs)
    threshold = maximum(abs.(p_h .- p_pred_h)) * 1.25
    println("FDI検知閾値: ", round(threshold, digits=4), " kPa")
    
    # 3. 異常データ全域の予測残差を算出
    f_in_f = get_lag(x6_f[1:end-1], best_l_in)
    f_out_f = get_lag(x10_f[1:end-1], best_l_out)
    p_pred_f = run_1step_prediction(p_f, f_in_f, f_out_f, best_coeffs)
    residuals_f = abs.(p_f .- p_pred_f)
    
    df_f.residual = residuals_f
    
    # 4. (faultNumber, simulationRun) ごとにグループ化
    # 20 (faults) * 500 (runs) = 10,000 の独立した各故障シミュレーションランを解析
    grouped = groupby(df_f, [:faultNumber, :simulationRun])
    
    idv_totals = zeros(Int, 20)
    idv_detecteds = zeros(Int, 20)
    idv_delays = [Float64[] for _ in 1:20]
    
    for df_grp in grouped
        idv = df_grp.faultNumber[1]
        if !(1 <= idv <= 20)
            continue
        end
        
        idv_totals[idv] += 1
        
        # 故障発生したインデックス
        inject_idx = findfirst(x -> x > 0, df_grp.faultNumber)
        if inject_idx === nothing
            continue
        end
        
        # 故障発生以降で残差が閾値を超えた最初のステップ
        detect_idx_relative = findfirst(x -> x > threshold, df_grp.residual[inject_idx:end])
        if detect_idx_relative !== nothing
            detect_idx = inject_idx + detect_idx_relative - 1
            # 物理的な時間遅延
            delay = df_grp.sample[detect_idx] - df_grp.sample[inject_idx]
            idv_detecteds[idv] += 1
            push!(idv_delays[idv], Float64(delay))
        end
    end
    
    # 5. 結果の一覧出力
    println("\n==================================================================")
    println("📊 TEP各IDV故障ごとの検知性能 (FDR & ADD) 定量検証結果")
    println("==================================================================")
    println(" IDV番号 | 対象ラン数 | 検知ラン数 | 検知率 (FDR %) | 平均検知遅延時間 (ADD)")
    println("---------+------------+------------+----------------+---------------------")
    
    report_data = []
    
    for idv in 1:20
        total = idv_totals[idv]
        detected = idv_detecteds[idv]
        fdr = total > 0 ? (detected / total) * 100.0 : 0.0
        
        add_str = "N/A (未検知)"
        add_val = -1.0
        if !isempty(idv_delays[idv])
            add_val = mean(idv_delays[idv])
            add_str = @sprintf("%.4f 分", add_val)
        end
        
        println(@sprintf("  IDV(%2d) | %10d | %10d | %13.2f %% | %s", 
                         idv, total, detected, fdr, add_str))
                         
        push!(report_data, Dict(
            "idv" => idv,
            "total" => total,
            "detected" => detected,
            "fdr" => fdr,
            "add" => add_val
        ))
    end
    println("==================================================================")
    
    # JSONにエクスポート
    open("idv_fdr_add_results.json", "w") do f
        JSON.print(f, report_data)
    end
    println("FDRおよびADDの定量データを JSONファイル [idv_fdr_add_results.json] に書き出しました。")
end

main()

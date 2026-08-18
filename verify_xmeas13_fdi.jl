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

# 2. LLM-GPが発見した数式(Gen19)の特徴量を構築する
# Δxmeas_13 = c1*xmeas_11*xmeas_16/100 + c2*xmeas_16
#           - c3*xmeas_20*(1-xmv_5/100)^2*xmeas_16/100
#           + c4*(xmeas_31+xmeas_33+xmeas_35)*xmeas_16/100
#           - c5*xmeas_38*xmeas_16/100
#           + c6*xmeas_16*(xmv_5/100) + c7
function build_features(df::DataFrame)
    x11 = Vector{Float64}(df.xmeas_11)
    x16 = Vector{Float64}(df.xmeas_16)
    x20 = Vector{Float64}(df.xmeas_20)
    xv5 = Vector{Float64}(df.xmv_5)
    x31 = Vector{Float64}(df.xmeas_31)
    x33 = Vector{Float64}(df.xmeas_33)
    x35 = Vector{Float64}(df.xmeas_35)
    x38 = Vector{Float64}(df.xmeas_38)

    f1 = x11 .* x16 ./ 100.0
    f2 = x16
    f3 = x20 .* (1.0 .- xv5 ./ 100.0).^2 .* x16 ./ 100.0
    f4 = (x31 .+ x33 .+ x35) .* x16 ./ 100.0
    f5 = x38 .* x16 ./ 100.0
    f6 = x16 .* (xv5 ./ 100.0)

    return f1, f2, f3, f4, f5, f6
end

# 3. 1ステップ先予測: p_pred[t] = p_meas[t-1] + Δp_pred(X(t-1))
function run_1step_prediction(p_meas::Vector{Float64}, feats::NTuple{6,Vector{Float64}}, coeffs::Vector{Float64})
    N = length(feats[1]) + 1
    p_pred = Vector{Float64}(undef, N)
    p_pred[1] = p_meas[1]
    for t in 2:N
        dp = coeffs[1]*feats[1][t-1] + coeffs[2]*feats[2][t-1] + coeffs[3]*feats[3][t-1] +
             coeffs[4]*feats[4][t-1] + coeffs[5]*feats[5][t-1] + coeffs[6]*feats[6][t-1] + coeffs[7]
        p_pred[t] = p_meas[t-1] + dp
    end
    return p_pred
end

# 4. メインロジック（全データOLS係数同定 + IDVごとのFDR & ADD評価）
function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"

    if !isfile(healthy_path) || !isfile(faulty_path)
        error("Required TEP dataset files are missing.")
    end

    df_h = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)

    p_h = Vector{Float64}(df_h.xmeas_13)
    feats_h_full = build_features(df_h)
    dp_h_actual = p_h[2:end] .- p_h[1:end-1]

    p_f = Vector{Float64}(df_f.xmeas_13)
    feats_f_full = build_features(df_f)

    # X(t-1) の特徴量 (最終行は次のΔyが存在しないため除外)
    feats_h = ntuple(i -> feats_h_full[i][1:end-1], 6)

    # 1. OLSによる係数同定 (正常データ全域)
    A = hcat(feats_h..., ones(length(feats_h[1])))
    coeffs = A \ dp_h_actual
    println("同定された係数 (c1..c7): ", coeffs)

    # 2. 正常データでの1ステップ予測とR^2
    p_pred_h = run_1step_prediction(p_h, feats_h, coeffs)
    ss_res = sum((p_h .- p_pred_h).^2)
    ss_tot = sum((p_h .- mean(p_h)).^2)
    r2 = 1.0 - (ss_res / ss_tot)
    println("正常データ R^2: ", round(r2, digits=4))

    # 3. 正常データから閾値 (Threshold) を決定 (1.25倍マージン)
    threshold = maximum(abs.(p_h .- p_pred_h)) * 1.25
    println("FDI検知閾値: ", round(threshold, digits=4), " kPa")

    # 4. 異常データ全域の予測残差を算出
    feats_f = ntuple(i -> feats_f_full[i][1:end-1], 6)
    p_pred_f = run_1step_prediction(p_f, feats_f, coeffs)
    residuals_f = abs.(p_f .- p_pred_f)

    df_f.residual = residuals_f

    # 5. (faultNumber, simulationRun) ごとにグループ化
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

        inject_idx = findfirst(x -> x > 0, df_grp.faultNumber)
        if inject_idx === nothing
            continue
        end

        detect_idx_relative = findfirst(x -> x > threshold, df_grp.residual[inject_idx:end])
        if detect_idx_relative !== nothing
            detect_idx = inject_idx + detect_idx_relative - 1
            delay = df_grp.sample[detect_idx] - df_grp.sample[inject_idx]
            idv_detecteds[idv] += 1
            push!(idv_delays[idv], Float64(delay))
        end
    end

    # 6. 結果の一覧出力
    println("\n==================================================================")
    println("📊 XMEAS(13) 各IDV故障ごとの検知性能 (FDR & ADD) 定量検証結果")
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
    output = Dict(
        "coefficients" => coeffs,
        "r2_normal" => r2,
        "threshold" => threshold,
        "idv_results" => report_data
    )
    open("xmeas13_fdi_results.json", "w") do f
        JSON.print(f, output)
    end
    println("結果を xmeas13_fdi_results.json に書き出しました。")
end

main()

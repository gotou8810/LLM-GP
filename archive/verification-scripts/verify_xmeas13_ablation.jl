using RData, DataFrames, JSON, Statistics, Printf

# フェーズ0(c): XMEAS(13)モデルの xmeas_16 (ストリッパー圧力、分離器の直接下流ユニットの
# 状態量) アブレーション検証。
#
# 現行モデル (verify_xmeas13_fdi.jl, R^2=0.9346) は、切片項 c7 を除く6特徴量項の
# 「全て」が xmeas_16 を乗数として含んでいる:
#   f1 = x11*x16/100, f2 = x16, f3 = x20*(1-xv5/100)^2*x16/100,
#   f4 = (x31+x33+x35)*x16/100, f5 = x38*x16/100, f6 = x16*(xv5/100)
# これは xmeas_7<->xmeas_13 で過去に確認された「相関の罠」(下流ユニットの状態量が
# 異常時に連動して変化し、モデルの予測値が実測値に追従してしまい異常を隠蔽する)と
# 同型のリスクがある。
#
# 本スクリプトは、xmeas_16の乗数構造を全て取り除いた「アブレーションモデル」を
# 同じ変数群(xmeas_11, xmeas_20, xmv_5, xmeas_31/33/35, xmeas_38)から再構築し、
# (1) 正常データでの構造的フィット力(R^2)、(2) 異常データでのIDVごとのFDR/ADD、
# (3) 各IDVでxmeas_16自体がどれだけ動くか、の3点を現行モデルと比較する。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# 現行モデル(ベースライン): 全項が xmeas_16 でスケーリングされている
function build_features_baseline(df::DataFrame)
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

    return (f1, f2, f3, f4, f5, f6)
end

# アブレーションモデル: 同じ変数群から xmeas_16 の乗数を全て取り除く
# (f2 = x16 単体の項は、x16を除くと他に変数が残らないため項ごと消滅する)
function build_features_ablated(df::DataFrame)
    x11 = Vector{Float64}(df.xmeas_11)
    x20 = Vector{Float64}(df.xmeas_20)
    xv5 = Vector{Float64}(df.xmv_5)
    x31 = Vector{Float64}(df.xmeas_31)
    x33 = Vector{Float64}(df.xmeas_33)
    x35 = Vector{Float64}(df.xmeas_35)
    x38 = Vector{Float64}(df.xmeas_38)

    g1 = x11
    g2 = x20 .* (1.0 .- xv5 ./ 100.0).^2
    g3 = (x31 .+ x33 .+ x35)
    g4 = x38
    g5 = xv5 ./ 100.0

    return (g1, g2, g3, g4, g5)
end

# 1ステップ先予測: p_pred[t] = p_meas[t-1] + Δp_pred(X(t-1)) (任意の項数に対応する一般化版)
function run_1step_prediction(p_meas::Vector{Float64}, feats::Tuple, coeffs::Vector{Float64})
    nfeat = length(feats)
    N = length(feats[1]) + 1
    p_pred = Vector{Float64}(undef, N)
    p_pred[1] = p_meas[1]
    for t in 2:N
        dp = coeffs[end]
        for i in 1:nfeat
            dp += coeffs[i] * feats[i][t-1]
        end
        p_pred[t] = p_meas[t-1] + dp
    end
    return p_pred
end

# 1モデル分の OLS係数同定 + 正常R^2 + 異常データFDR/ADD評価をまとめて実行する
function evaluate_model(label::String, df_h::DataFrame, df_f::DataFrame,
                         feats_h_full::Tuple, feats_f_full::Tuple)
    p_h = Vector{Float64}(df_h.xmeas_13)
    dp_h_actual = p_h[2:end] .- p_h[1:end-1]
    p_f = Vector{Float64}(df_f.xmeas_13)

    nfeat = length(feats_h_full)
    feats_h = ntuple(i -> feats_h_full[i][1:end-1], nfeat)

    A = hcat(feats_h..., ones(length(feats_h[1])))
    coeffs = A \ dp_h_actual

    p_pred_h = run_1step_prediction(p_h, feats_h, coeffs)
    ss_res = sum((p_h .- p_pred_h) .^ 2)
    ss_tot = sum((p_h .- mean(p_h)) .^ 2)
    r2 = 1.0 - (ss_res / ss_tot)

    threshold = maximum(abs.(p_h .- p_pred_h)) * 1.25

    feats_f = ntuple(i -> feats_f_full[i][1:end-1], nfeat)
    p_pred_f = run_1step_prediction(p_f, feats_f, coeffs)
    residuals_f = abs.(p_f .- p_pred_f)

    df_f_local = copy(df_f)
    df_f_local.residual = residuals_f
    grouped = groupby(df_f_local, [:faultNumber, :simulationRun])

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

    println("\n--- モデル: $label (項数=$nfeat, 係数=$(length(coeffs))) ---")
    println("係数: ", coeffs)
    println("正常データ R^2: ", round(r2, digits=4))
    println("FDI検知閾値: ", round(threshold, digits=4), " kPa")

    report_data = []
    for idv in 1:20
        total = idv_totals[idv]
        detected = idv_detecteds[idv]
        fdr = total > 0 ? (detected / total) * 100.0 : 0.0
        add_val = isempty(idv_delays[idv]) ? -1.0 : mean(idv_delays[idv])
        push!(report_data, Dict(
            "idv" => idv, "total" => total, "detected" => detected,
            "fdr" => fdr, "add" => add_val
        ))
    end

    return Dict(
        "label" => label,
        "coefficients" => coeffs,
        "r2_normal" => r2,
        "threshold" => threshold,
        "idv_results" => report_data,
    )
end

# 各IDVで xmeas_16 自体が正常時と比べどれだけ動くかを直接計測する
# (「xmeas_16が異常に連動して動く」という相関の罠の仮説そのものを裏付けるための補助指標)
function evaluate_xmeas16_fault_sensitivity(df_h::DataFrame, df_f::DataFrame)
    x16_h = Vector{Float64}(df_h.xmeas_16)
    normal_std = std(x16_h)

    df_f_local = copy(df_f)
    grouped = groupby(df_f_local, [:faultNumber, :simulationRun])

    idv_deviation = [Float64[] for _ in 1:20]
    for df_grp in grouped
        idv = df_grp.faultNumber[1]
        if !(1 <= idv <= 20)
            continue
        end
        inject_idx = findfirst(x -> x > 0, df_grp.faultNumber)
        if inject_idx === nothing
            continue
        end
        x16_fault = Vector{Float64}(df_grp.xmeas_16[inject_idx:end])
        push!(idv_deviation[idv], mean(abs.(x16_fault .- mean(x16_fault[1:1]))))
    end

    println("\n--- xmeas_16 の異常時変動 (正常時std=$(round(normal_std, digits=4)) との比較) ---")
    println(" IDV番号 | 故障後平均|Δxmeas_16| | 正常std比")
    results = []
    for idv in 1:20
        if isempty(idv_deviation[idv])
            continue
        end
        mean_dev = mean(idv_deviation[idv])
        ratio = normal_std > 0 ? mean_dev / normal_std : NaN
        println(@sprintf("  IDV(%2d) | %20.4f | %8.2fx", idv, mean_dev, ratio))
        push!(results, Dict("idv" => idv, "mean_abs_dev" => mean_dev, "ratio_to_normal_std" => ratio))
    end
    return results
end

function print_comparison_table(baseline::Dict, ablated::Dict)
    println("\n==================================================================")
    println("📊 XMEAS(13) ベースライン vs xmeas_16アブレーション 比較 (FDR %)")
    println("==================================================================")
    println(" IDV番号 | ベースラインFDR | アブレーションFDR | 差分")
    println("---------+-----------------+--------------------+--------")
    for idv in 1:20
        b = baseline["idv_results"][idv]["fdr"]
        a = ablated["idv_results"][idv]["fdr"]
        println(@sprintf("  IDV(%2d) | %13.2f %% | %16.2f %% | %+7.2f", idv, b, a, a - b))
    end
    println("==================================================================")
    println(@sprintf("正常データR^2:  ベースライン=%.4f  アブレーション=%.4f  (差分=%+.4f)",
                      baseline["r2_normal"], ablated["r2_normal"],
                      ablated["r2_normal"] - baseline["r2_normal"]))
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"

    if !isfile(healthy_path) || !isfile(faulty_path)
        error("Required TEP dataset files are missing.")
    end

    df_h = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)

    feats_h_baseline = build_features_baseline(df_h)
    feats_f_baseline = build_features_baseline(df_f)
    feats_h_ablated = build_features_ablated(df_h)
    feats_f_ablated = build_features_ablated(df_f)

    baseline = evaluate_model("ベースライン (xmeas_16あり)", df_h, df_f, feats_h_baseline, feats_f_baseline)
    ablated = evaluate_model("アブレーション (xmeas_16除去)", df_h, df_f, feats_h_ablated, feats_f_ablated)

    print_comparison_table(baseline, ablated)

    x16_sensitivity = evaluate_xmeas16_fault_sensitivity(df_h, df_f)

    output = Dict(
        "baseline" => baseline,
        "ablated" => ablated,
        "xmeas16_fault_sensitivity" => x16_sensitivity,
    )
    open("xmeas13_ablation_results.json", "w") do f
        JSON.print(f, output)
    end
    println("\n結果を xmeas13_ablation_results.json に書き出しました。")
end

main()

using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(13) Gen16式(LLM-GP盲検探索で発見)の厳密検証
#   Δxmeas_13 = c1*xmeas_11 - c2*xmeas_20 + c3*(xmeas_31+xmeas_33+xmeas_35) + c4
#
# 従来の評価手法の2つの欠陥を修正する:
#   (1) 250,000行/5,000,000行を1本の連続系列として扱っていたため、
#       シミュレーションラン境界(500サンプルごと)で無関係な前ランの最終値から
#       予測を継続してしまっていた -> ラン単位でリセットして予測する
#   (2) FAR(誤報率)を閾値設定に使ったのと同じ正常データで測っていたため、
#       定義上ほぼ0%になり無意味だった -> 正常データをFIT/HOLDOUTに分割し、
#       HOLDOUT(係数同定にも閾値設定にも一切使っていない)でFARを測る
#
# あわせて、teprob.fで確認した「分離器の3系統目の流出(xmeas_14, 液相アンダーフロー)」
# を追加した拡張版も同時に評価し、Gen16式と比較する。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# Gen16の3項(+切片)を構築
function build_features_gen16(df::DataFrame)
    x11 = Vector{Float64}(df.xmeas_11)
    x20 = Vector{Float64}(df.xmeas_20)
    x31 = Vector{Float64}(df.xmeas_31)
    x33 = Vector{Float64}(df.xmeas_33)
    x35 = Vector{Float64}(df.xmeas_35)
    comp = x31 .+ x33 .+ x35
    return (x11, x20, comp)
end

# Gen16 + xmeas_14(液相アンダーフロー、teprob.fで確認した3系統目の流出)
function build_features_extended(df::DataFrame)
    base = build_features_gen16(df)
    x14 = Vector{Float64}(df.xmeas_14)
    return (base..., x14)
end

# 1ランぶんの1ステップ先予測(そのラン内で完結、他ランへは波及させない)
function predict_one_run(p_meas::Vector{Float64}, feats::Tuple, coeffs::Vector{Float64})
    nfeat = length(feats)
    N = length(p_meas)
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

# ラン境界を尊重して、run_id列でグループ化しながら予測・残差を計算する
function predict_grouped(df::DataFrame, feats_full::Tuple, coeffs::Vector{Float64}, run_col::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    n = nrow(df_sorted)
    p_pred_all = Vector{Float64}(undef, n)
    p_meas_all = Vector{Float64}(df_sorted.xmeas_13)

    grouped = groupby(df_sorted, run_col)
    row_offset = 0
    for g in grouped
        m = nrow(g)
        idx = (row_offset+1):(row_offset+m)
        p_meas_g = Vector{Float64}(g.xmeas_13)
        feats_g = ntuple(i -> Vector{Float64}(feats_full[i][idx]), length(feats_full))
        p_pred_all[idx] = predict_one_run(p_meas_g, feats_g, coeffs)
        row_offset += m
    end
    return df_sorted, p_meas_all, p_pred_all
end

# X(t-1)特徴量とΔy(t)=y(t)-y(t-1)のペアをラン内で構築(最終行を除外)してOLS係数同定
function fit_ols_grouped(df::DataFrame, feats_full::Tuple, run_col::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    nfeat = length(feats_full)

    all_dy = Float64[]
    feat_cols = [Float64[] for _ in 1:nfeat]

    row_offset = 0
    for g in grouped
        m = nrow(g)
        p = Vector{Float64}(g.xmeas_13)
        dy = p[2:end] .- p[1:end-1]
        append!(all_dy, dy)
        idx = (row_offset+1):(row_offset+m-1)  # X(t-1)側(最終行は次のΔyがないため除外)
        for i in 1:nfeat
            append!(feat_cols[i], feats_full[i][idx])
        end
        row_offset += m
    end

    A = hcat(feat_cols..., ones(length(all_dy)))
    coeffs = A \ all_dy
    return coeffs
end

function compute_r2(p_meas::Vector{Float64}, p_pred::Vector{Float64})
    ss_res = sum((p_meas .- p_pred) .^ 2)
    ss_tot = sum((p_meas .- mean(p_meas)) .^ 2)
    return 1.0 - ss_res / ss_tot
end

# ラン単位の混同行列: 正常ホールドアウトラン(FP/TN) + 異常ラン(TP/FN)
function evaluate_full(label::String, feats_builder, df_fit::DataFrame, df_holdout::DataFrame, df_faulty::DataFrame)
    println("\n" * "="^70)
    println("モデル: $label")
    println("="^70)

    feats_fit_full = feats_builder(df_fit)
    coeffs = fit_ols_grouped(df_fit, feats_fit_full, :simulationRun)
    println("係数: ", coeffs)

    _, p_meas_fit, p_pred_fit = predict_grouped(df_fit, feats_fit_full, coeffs, :simulationRun)
    r2_fit = compute_r2(p_meas_fit, p_pred_fit)
    resid_fit = abs.(p_meas_fit .- p_pred_fit)
    threshold = maximum(resid_fit) * 1.25
    println(@sprintf("FIT正常データ R^2: %.4f", r2_fit))
    println(@sprintf("FDI検知閾値(FITデータの最大残差x1.25): %.4f kPa", threshold))

    # --- HOLDOUT正常データでのFAR(閾値設定に一切使っていない独立データ) ---
    feats_holdout_full = feats_builder(df_holdout)
    df_holdout_sorted, p_meas_ho, p_pred_ho = predict_grouped(df_holdout, feats_holdout_full, coeffs, :simulationRun)
    r2_holdout = compute_r2(p_meas_ho, p_pred_ho)
    resid_ho = abs.(p_meas_ho .- p_pred_ho)
    df_holdout_sorted.residual = resid_ho
    ho_grouped = groupby(df_holdout_sorted, :simulationRun)
    n_holdout_runs = length(ho_grouped)
    fp_runs = 0
    for g in ho_grouped
        if any(g.residual .> threshold)
            fp_runs += 1
        end
    end
    far = fp_runs / n_holdout_runs * 100.0
    println(@sprintf("HOLDOUT正常データ R^2: %.4f (out-of-sample)", r2_holdout))
    println(@sprintf("FAR(誤報率、独立ホールドアウト%d run中): %.2f%% (%d/%d runs)", n_holdout_runs, far, fp_runs, n_holdout_runs))

    # --- 異常データでのFDR/ADD(ラン単位、ラン境界を尊重) ---
    feats_faulty_full = feats_builder(df_faulty)
    df_faulty_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])
    n = nrow(df_faulty_sorted)
    p_meas_all = Vector{Float64}(df_faulty_sorted.xmeas_13)
    p_pred_all = Vector{Float64}(undef, n)

    grouped_f = groupby(df_faulty_sorted, [:faultNumber, :simulationRun])
    row_offset = 0
    idv_totals = zeros(Int, 20)
    idv_detecteds = zeros(Int, 20)
    idv_delays = [Float64[] for _ in 1:20]
    tp_runs = 0
    fn_runs = 0

    for g in grouped_f
        m = nrow(g)
        idx = (row_offset+1):(row_offset+m)
        p_meas_g = Vector{Float64}(g.xmeas_13)
        feats_g = ntuple(i -> Vector{Float64}(feats_faulty_full[i][idx]), length(feats_faulty_full))
        p_pred_g = predict_one_run(p_meas_g, feats_g, coeffs)
        p_pred_all[idx] = p_pred_g
        resid_g = abs.(p_meas_g .- p_pred_g)

        idv = g.faultNumber[1]
        if 1 <= idv <= 20
            idv_totals[idv] += 1
            inject_idx = findfirst(x -> x > 0, g.faultNumber)
            if inject_idx !== nothing
                detect_rel = findfirst(x -> x > threshold, resid_g[inject_idx:end])
                if detect_rel !== nothing
                    detect_idx = inject_idx + detect_rel - 1
                    delay = g.sample[detect_idx] - g.sample[inject_idx]
                    idv_detecteds[idv] += 1
                    push!(idv_delays[idv], Float64(delay))
                    tp_runs += 1
                else
                    fn_runs += 1
                end
            end
        end
        row_offset += m
    end
    r2_faulty_all = compute_r2(p_meas_all, p_pred_all)

    println("\n--- IDVごとのFDR/ADD ---")
    report_data = []
    for idv in 1:20
        total = idv_totals[idv]
        detected = idv_detecteds[idv]
        fdr = total > 0 ? (detected / total) * 100.0 : 0.0
        add_val = isempty(idv_delays[idv]) ? -1.0 : mean(idv_delays[idv])
        println(@sprintf("  IDV(%2d) | FDR=%6.2f%% | ADD=%s", idv, fdr, add_val < 0 ? "N/A" : @sprintf("%.1f分", add_val)))
        push!(report_data, Dict("idv" => idv, "total" => total, "detected" => detected, "fdr" => fdr, "add" => add_val))
    end

    # --- ラン単位の混同行列・Precision/Recall/F1 ---
    tn_runs = n_holdout_runs - fp_runs
    precision = (tp_runs + fp_runs) > 0 ? tp_runs / (tp_runs + fp_runs) : 0.0
    recall = (tp_runs + fn_runs) > 0 ? tp_runs / (tp_runs + fn_runs) : 0.0
    f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0

    println("\n--- ラン単位 混同行列(全20 IDV合算 vs ホールドアウト正常) ---")
    println(@sprintf("TP=%d  FN=%d  FP=%d  TN=%d", tp_runs, fn_runs, fp_runs, tn_runs))
    println(@sprintf("Precision=%.4f  Recall=%.4f  F1=%.4f  FAR=%.2f%%", precision, recall, f1, far))

    return Dict(
        "label" => label, "coefficients" => coeffs,
        "r2_fit" => r2_fit, "r2_holdout" => r2_holdout, "r2_faulty_all" => r2_faulty_all,
        "threshold" => threshold, "far_pct" => far,
        "confusion" => Dict("tp" => tp_runs, "fn" => fn_runs, "fp" => fp_runs, "tn" => tn_runs),
        "precision" => precision, "recall" => recall, "f1" => f1,
        "idv_results" => report_data,
    )
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"
    if !isfile(healthy_path) || !isfile(faulty_path)
        error("Required TEP dataset files are missing.")
    end

    df_h_all = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)

    # 正常500ランを FIT(1-400) / HOLDOUT(401-500) に分割(係数同定・閾値設定にHOLDOUTは一切使わない)
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)
    println("FIT runs: ", length(unique(df_fit.simulationRun)), " / HOLDOUT runs: ", length(unique(df_holdout.simulationRun)))

    result_gen16 = evaluate_full("Gen16式 (xmeas_11, xmeas_20, purge組成和)", build_features_gen16, df_fit, df_holdout, df_f)
    result_extended = evaluate_full("Gen16式 + xmeas_14(液相アンダーフロー追加)", build_features_extended, df_fit, df_holdout, df_f)

    # --- アブレーション(各項削除、Gen16式に対して実施) ---
    println("\n" * "="^70)
    println("Gen16式のアブレーション検証(各項を1つずつ削除)")
    println("="^70)

    ablation_results = Dict()
    build_no_x11(df) = (Vector{Float64}(df.xmeas_20), Vector{Float64}(df.xmeas_31) .+ Vector{Float64}(df.xmeas_33) .+ Vector{Float64}(df.xmeas_35))
    build_no_x20(df) = (Vector{Float64}(df.xmeas_11), Vector{Float64}(df.xmeas_31) .+ Vector{Float64}(df.xmeas_33) .+ Vector{Float64}(df.xmeas_35))
    build_no_comp(df) = (Vector{Float64}(df.xmeas_11), Vector{Float64}(df.xmeas_20))

    for (name, builder) in [("削除:xmeas_11", build_no_x11), ("削除:xmeas_20", build_no_x20), ("削除:組成和", build_no_comp)]
        r = evaluate_full("Gen16 $name", builder, df_fit, df_holdout, df_f)
        ablation_results[name] = Dict("r2_fit" => r["r2_fit"], "f1" => r["f1"], "recall" => r["recall"], "far_pct" => r["far_pct"])
    end

    output = Dict("gen16" => result_gen16, "extended_with_xmeas14" => result_extended, "ablation" => ablation_results)
    open("xmeas13_rigorous_results.json", "w") do f
        JSON.print(f, output)
    end
    println("\n結果を xmeas13_rigorous_results.json に書き出しました。")
end

main()

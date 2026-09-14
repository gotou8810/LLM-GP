using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(7) [反応器圧力] の再監査(旧verify_xmeas7_fdi.jlの手法上の弱点を修正した上での再検証)
#
# 旧verify_xmeas7_fdi.jlの問題点:
#   1. ラン境界を無視した差分計算(simulationRunでソート・グループ化していない)
#   2. ラグ(0-15)を256通り総当たりし、そのままの正常データ全体でR^2最大のものを選択
#      (ホールドアウト分割なし=探索と評価が同一データ)
#   3. CCF非対称性検定(閉ループ交絡の検出)が導入される前の時代のモデルであり、
#      未検証のまま「完成」として扱われていた
#
# 本スクリプトは、既知の構造(x6, x10_lag1, x7_lag1)をラン境界を尊重したfit/holdout分割で
# 再フィットし、あわせてxmeas_6(CCF比率5.95で閉ループ交絡の疑いが濃い)を除いた
# アブレーションモデルと比較する(XMEAS13のxmeas_16アブレーションと同じ手順)。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# features: (column_symbol, extra_shift) のリスト。extra_shift=0は"t-1"(予測アンカーと同じ時点)、
# extra_shift=1は"t-2"を意味する。self-damping項(xmeas_7自身)もextra_shift=0で"t-1"の値を使う
# (これは予測アンカー値そのものであり、自己参照ではなく物理的な自己減衰項として明示的に許容される)。
function fit_ols_grouped(df::DataFrame, run_col::Symbol, target::Symbol, features::Vector{Tuple{Symbol,Int}})
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    max_shift = maximum(s for (_, s) in features)
    min_t = 2 + max_shift
    all_dy = Float64[]
    feat_cols = [Float64[] for _ in features]
    for g in grouped
        y = Vector{Float64}(g[!, target])
        m = length(y)
        if m < min_t
            continue
        end
        cols = [Vector{Float64}(g[!, c]) for (c, _) in features]
        for t in min_t:m
            push!(all_dy, y[t] - y[t-1])
            for (i, (_, s)) in enumerate(features)
                push!(feat_cols[i], cols[i][t-1-s])
            end
        end
    end
    A = hcat(feat_cols..., ones(length(all_dy)))
    coeffs = A \ all_dy
    return coeffs
end

function predict_grouped(df::DataFrame, coeffs::Vector{Float64}, run_col::Symbol, target::Symbol, features::Vector{Tuple{Symbol,Int}})
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    max_shift = maximum(s for (_, s) in features)
    min_t = 2 + max_shift
    p_meas_all = Float64[]
    p_pred_all = Float64[]
    valid_all = Bool[]
    for g in grouped
        y = Vector{Float64}(g[!, target])
        m = length(y)
        cols = [Vector{Float64}(g[!, c]) for (c, _) in features]
        p_pred = copy(y)
        valid = falses(m)
        for t in min_t:m
            dp = coeffs[end]
            for (i, (_, s)) in enumerate(features)
                dp += coeffs[i] * cols[i][t-1-s]
            end
            p_pred[t] = y[t-1] + dp
            valid[t] = true
        end
        append!(p_meas_all, y)
        append!(p_pred_all, p_pred)
        append!(valid_all, valid)
    end
    return df_sorted, p_meas_all, p_pred_all, valid_all
end

function predict_faulty_run(g::SubDataFrame, coeffs::Vector{Float64}, target::Symbol, features::Vector{Tuple{Symbol,Int}}, min_t::Int)
    y = Vector{Float64}(g[!, target])
    m = length(y)
    cols = [Vector{Float64}(g[!, c]) for (c, _) in features]
    p_pred = copy(y)
    resid = zeros(Float64, m)
    for t in min_t:m
        dp = coeffs[end]
        for (i, (_, s)) in enumerate(features)
            dp += coeffs[i] * cols[i][t-1-s]
        end
        p_pred[t] = y[t-1] + dp
        resid[t] = abs(y[t] - p_pred[t])
    end
    return resid
end

function compute_r2(p_meas::Vector{Float64}, p_pred::Vector{Float64})
    ss_res = sum((p_meas .- p_pred) .^ 2)
    ss_tot = sum((p_meas .- mean(p_meas)) .^ 2)
    return 1.0 - ss_res / ss_tot
end

function evaluate_full(label::String, target::Symbol, features::Vector{Tuple{Symbol,Int}},
                        df_fit::DataFrame, df_holdout::DataFrame, df_faulty::DataFrame)
    println("\n" * "="^70)
    println("モデル: $label")
    println("="^70)
    println("特徴量: ", features)

    coeffs = fit_ols_grouped(df_fit, :simulationRun, target, features)
    println("係数(最後が切片): ", coeffs)

    max_shift = maximum(s for (_, s) in features)
    min_t = 2 + max_shift

    _, p_meas_fit, p_pred_fit, valid_fit = predict_grouped(df_fit, coeffs, :simulationRun, target, features)
    r2_fit = compute_r2(p_meas_fit[valid_fit], p_pred_fit[valid_fit])
    resid_fit = abs.(p_meas_fit .- p_pred_fit)
    threshold = maximum(resid_fit[valid_fit]) * 1.25
    println(@sprintf("FIT正常データ R^2: %.4f", r2_fit))
    println(@sprintf("FDI検知閾値: %.4f", threshold))

    df_holdout_sorted, p_meas_ho, p_pred_ho, valid_ho = predict_grouped(df_holdout, coeffs, :simulationRun, target, features)
    r2_holdout = compute_r2(p_meas_ho[valid_ho], p_pred_ho[valid_ho])
    resid_ho = abs.(p_meas_ho .- p_pred_ho)
    df_holdout_sorted.residual = resid_ho
    df_holdout_sorted.valid_row = valid_ho
    ho_grouped = groupby(df_holdout_sorted, :simulationRun)
    n_holdout_runs = length(ho_grouped)
    fp_runs = 0
    for g in ho_grouped
        if any(g.residual[g.valid_row] .> threshold)
            fp_runs += 1
        end
    end
    far = fp_runs / n_holdout_runs * 100.0
    println(@sprintf("HOLDOUT正常データ R^2 (out-of-sample): %.4f", r2_holdout))
    println(@sprintf("FAR: %.2f%% (%d/%d runs)", far, fp_runs, n_holdout_runs))

    df_faulty_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])
    grouped_f = groupby(df_faulty_sorted, [:faultNumber, :simulationRun])
    idv_totals = zeros(Int, 20)
    idv_detecteds = zeros(Int, 20)
    idv_delays = [Float64[] for _ in 1:20]
    tp_runs = 0
    fn_runs = 0

    for g in grouped_f
        fault_col = g.faultNumber
        m = nrow(g)
        resid = predict_faulty_run(g, coeffs, target, features, min_t)

        idv = fault_col[1]
        if 1 <= idv <= 20
            idv_totals[idv] += 1
            inject_idx = findfirst(v -> v > 0, fault_col)
            if inject_idx !== nothing
                search_start = max(inject_idx, min_t)
                detect_rel = findfirst(v -> v > threshold, resid[search_start:end])
                if detect_rel !== nothing
                    detect_idx = search_start + detect_rel - 1
                    delay = g.sample[detect_idx] - g.sample[inject_idx]
                    idv_detecteds[idv] += 1
                    push!(idv_delays[idv], Float64(delay))
                    tp_runs += 1
                else
                    fn_runs += 1
                end
            end
        end
    end

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

    tn_runs = n_holdout_runs - fp_runs
    precision = (tp_runs + fp_runs) > 0 ? tp_runs / (tp_runs + fp_runs) : 0.0
    recall = (tp_runs + fn_runs) > 0 ? tp_runs / (tp_runs + fn_runs) : 0.0
    f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0

    println("\n--- ラン単位 混同行列 ---")
    println(@sprintf("TP=%d  FN=%d  FP=%d  TN=%d", tp_runs, fn_runs, fp_runs, tn_runs))
    println(@sprintf("Precision=%.4f  Recall=%.4f  F1=%.4f  FAR=%.2f%%", precision, recall, f1, far))

    return Dict("label" => label, "coefficients" => coeffs, "r2_fit" => r2_fit, "r2_holdout" => r2_holdout,
                "threshold" => threshold, "far_pct" => far, "precision" => precision, "recall" => recall,
                "f1" => f1, "idv_results" => report_data)
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"
    if !isfile(healthy_path) || !isfile(faulty_path)
        error("Required TEP dataset files are missing.")
    end

    df_h_all = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)
    println("FIT runs: ", length(unique(df_fit.simulationRun)), " / HOLDOUT runs: ", length(unique(df_holdout.simulationRun)))

    # メインモデル: xmeas_6(t-1, 流入) + xmeas_10(t-2, 流出, "lag1") + xmeas_7(t-1, 自己減衰)
    main_features = [(:xmeas_6, 0), (:xmeas_10, 1), (:xmeas_7, 0)]
    result_main = evaluate_full("XMEAS(7) メイン式 (xmeas_6 + xmeas_10_lag1 + 自己減衰xmeas_7_lag1)",
                                 :xmeas_7, main_features, df_fit, df_holdout, df_f)

    # アブレーション: CCF比率5.95で閉ループ交絡の疑いが濃いxmeas_6を除去
    ablation_features = [(:xmeas_10, 1), (:xmeas_7, 0)]
    result_ablation = evaluate_full("XMEAS(7) アブレーション式 (xmeas_6を除去; xmeas_10_lag1 + 自己減衰xmeas_7_lag1)",
                                     :xmeas_7, ablation_features, df_fit, df_holdout, df_f)

    combined = Dict("main" => result_main, "ablation_no_xmeas6" => result_ablation)
    open("xmeas7_v2_rigorous_results.json", "w") do f
        JSON.print(f, combined)
    end
    println("\n結果を xmeas7_v2_rigorous_results.json に書き出しました。")
end

main()

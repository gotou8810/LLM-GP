using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(13) Method A v2式(修正済みOLSベースの符号検証パイプラインで発見)の厳密検証
#   Δxmeas_13 = c1*xmeas_6 - c2*xmeas_10 + c3
#   法則: 質量収支。xmeas_6=反応器フィード(流入, 正符号予言), xmeas_10=パージ流量(流出, 負符号予言)。
#   複数世代にわたり符号検証(OLSベース)に頑健に合格した、現時点で最も信頼できる候補。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

function build_features_methodA_v2(df::DataFrame)
    x6 = Vector{Float64}(df.xmeas_6)
    x10 = Vector{Float64}(df.xmeas_10)
    return (x6, x10)
end

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
        idx = (row_offset+1):(row_offset+m-1)
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
    println(@sprintf("FDI検知閾値: %.4f kPa", threshold))

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
    println(@sprintf("FAR: %.2f%% (%d/%d runs)", far, fp_runs, n_holdout_runs))

    feats_faulty_full = feats_builder(df_faulty)
    df_faulty_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])
    n = nrow(df_faulty_sorted)
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

    return Dict(
        "label" => label, "coefficients" => coeffs,
        "r2_fit" => r2_fit, "r2_holdout" => r2_holdout,
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
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)
    println("FIT runs: ", length(unique(df_fit.simulationRun)), " / HOLDOUT runs: ", length(unique(df_holdout.simulationRun)))

    result_main = evaluate_full("Method A v2式 (xmeas_6, xmeas_10; 質量収支, OLS符号検証済み)", build_features_methodA_v2, df_fit, df_holdout, df_f)

    println("\n" * "="^70)
    println("アブレーション検証")
    println("="^70)
    build_no_x6(df) = (Vector{Float64}(df.xmeas_10),)
    build_no_x10(df) = (Vector{Float64}(df.xmeas_6),)

    ablation_results = Dict()
    for (name, builder) in [("削除:xmeas_6", build_no_x6), ("削除:xmeas_10", build_no_x10)]
        r = evaluate_full("Method A v2 $name", builder, df_fit, df_holdout, df_f)
        ablation_results[name] = Dict("r2_fit" => r["r2_fit"], "f1" => r["f1"], "recall" => r["recall"], "far_pct" => r["far_pct"])
    end

    output = Dict("main" => result_main, "ablation" => ablation_results)
    open("xmeas13_methodA_v2_rigorous_results.json", "w") do f
        JSON.print(f, output)
    end
    println("\n結果を xmeas13_methodA_v2_rigorous_results.json に書き出しました。")
end

main()

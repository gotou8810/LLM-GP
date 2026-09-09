using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(9) [反応器温度] 再探索 v3(lag5/lag10ヒント追加後)の厳密検証
#   Δxmeas_9 = c1*(xmeas_6_lag3 * xmeas_23_lag3 * xmeas_26_lag3) + c2
#   法則: 反応速度論(Arrhenius)/消費則。反応器フィード量×成分A%×成分D%を、並行する
#   発熱反応(A+C+D→G, A+D+E→H)の同時反応物利用可能性の代理変数として扱う。
#   GPループはlag2〜lag8を掃引しlag3で最良(fitness=1.1564)に収束。ただしxmeas_23/26
#   は分析器(クロマトグラフ)サンプリングのmol%値であり、プロンプト自体が「分析周期による
#   離散サンプリング遅延アーチファクトに注意」と明記している変数群である点に留意。
#
#   GPループの命名規約: "_lag3"はGPループの差分予測フレーム(暗黙にt-1を指す)から
#   さらに3つ遡った値、すなわちΔy(t)=y(t)-y(t-1)を予測する際は各変数(t-4)を指す。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

const EXTRA_SHIFT = 3  # "_lag3" 分の追加遡り

function fit_ols_grouped(df::DataFrame, run_col::Symbol, target::Symbol, f1::Symbol, f2::Symbol, f3::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    all_dy = Float64[]
    all_feat = Float64[]  # xmeas_6_lag3 * xmeas_23_lag3 * xmeas_26_lag3 = f1(t-1-3)*f2(t-1-3)*f3(t-1-3)
    min_t = 2 + EXTRA_SHIFT  # y[t]-y[t-1]を予測するには t-1-EXTRA_SHIFT >= 1 が必要 -> t >= 2+EXTRA_SHIFT
    for g in grouped
        y = Vector{Float64}(g[!, target])
        a = Vector{Float64}(g[!, f1])
        b = Vector{Float64}(g[!, f2])
        c = Vector{Float64}(g[!, f3])
        m = length(y)
        if m < min_t
            continue
        end
        for t in min_t:m
            idx = t - 1 - EXTRA_SHIFT
            push!(all_dy, y[t] - y[t-1])
            push!(all_feat, a[idx] * b[idx] * c[idx])
        end
    end
    A = hcat(all_feat, ones(length(all_dy)))
    coeffs = A \ all_dy
    return coeffs
end

function predict_grouped(df::DataFrame, coeffs::Vector{Float64}, run_col::Symbol, target::Symbol, f1::Symbol, f2::Symbol, f3::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    p_meas_all = Float64[]
    p_pred_all = Float64[]
    valid_all = Bool[]
    min_t = 2 + EXTRA_SHIFT
    for g in grouped
        y = Vector{Float64}(g[!, target])
        a = Vector{Float64}(g[!, f1])
        b = Vector{Float64}(g[!, f2])
        c = Vector{Float64}(g[!, f3])
        m = length(y)
        p_pred = copy(y)
        valid = falses(m)
        for t in min_t:m
            idx = t - 1 - EXTRA_SHIFT
            dp = coeffs[1] * (a[idx] * b[idx] * c[idx]) + coeffs[2]
            p_pred[t] = y[t-1] + dp
            valid[t] = true
        end
        append!(p_meas_all, y)
        append!(p_pred_all, p_pred)
        append!(valid_all, valid)
    end
    return df_sorted, p_meas_all, p_pred_all, valid_all
end

function compute_r2(p_meas::Vector{Float64}, p_pred::Vector{Float64})
    ss_res = sum((p_meas .- p_pred) .^ 2)
    ss_tot = sum((p_meas .- mean(p_meas)) .^ 2)
    return 1.0 - ss_res / ss_tot
end

function evaluate_full(label::String, target::Symbol, f1::Symbol, f2::Symbol, f3::Symbol, df_fit::DataFrame, df_holdout::DataFrame, df_faulty::DataFrame)
    println("\n" * "="^70)
    println("モデル: $label")
    println("="^70)

    coeffs = fit_ols_grouped(df_fit, :simulationRun, target, f1, f2, f3)
    println("係数 [c1(triple product), c2(intercept)]: ", coeffs)

    _, p_meas_fit, p_pred_fit, valid_fit = predict_grouped(df_fit, coeffs, :simulationRun, target, f1, f2, f3)
    r2_fit = compute_r2(p_meas_fit[valid_fit], p_pred_fit[valid_fit])
    resid_fit = abs.(p_meas_fit .- p_pred_fit)
    threshold = maximum(resid_fit[valid_fit]) * 1.25
    println(@sprintf("FIT正常データ R^2 (立ち上がり分/ラン除く): %.4f", r2_fit))
    println(@sprintf("FDI検知閾値: %.4f", threshold))

    df_holdout_sorted, p_meas_ho, p_pred_ho, valid_ho = predict_grouped(df_holdout, coeffs, :simulationRun, target, f1, f2, f3)
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
    min_t = 2 + EXTRA_SHIFT
    idv_totals = zeros(Int, 20)
    idv_detecteds = zeros(Int, 20)
    idv_delays = [Float64[] for _ in 1:20]
    tp_runs = 0
    fn_runs = 0

    for g in grouped_f
        y = Vector{Float64}(g[!, target])
        a = Vector{Float64}(g[!, f1])
        b = Vector{Float64}(g[!, f2])
        c = Vector{Float64}(g[!, f3])
        m = length(y)
        fault_col = g.faultNumber
        p_pred = copy(y)
        resid = zeros(Float64, m)
        for t in min_t:m
            idx = t - 1 - EXTRA_SHIFT
            dp = coeffs[1] * (a[idx] * b[idx] * c[idx]) + coeffs[2]
            p_pred[t] = y[t-1] + dp
            resid[t] = abs(y[t] - p_pred[t])
        end

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
    f1_score = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0

    println("\n--- ラン単位 混同行列 ---")
    println(@sprintf("TP=%d  FN=%d  FP=%d  TN=%d", tp_runs, fn_runs, fp_runs, tn_runs))
    println(@sprintf("Precision=%.4f  Recall=%.4f  F1=%.4f  FAR=%.2f%%", precision, recall, f1_score, far))

    return Dict("label" => label, "coefficients" => coeffs, "r2_fit" => r2_fit, "r2_holdout" => r2_holdout,
                "threshold" => threshold, "far_pct" => far, "precision" => precision, "recall" => recall,
                "f1" => f1_score, "idv_results" => report_data)
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

    result = evaluate_full("XMEAS(9) v3式 (xmeas_6*xmeas_23*xmeas_26, 全項lag3; 反応速度論)",
                            :xmeas_9, :xmeas_6, :xmeas_23, :xmeas_26, df_fit, df_holdout, df_f)

    open("xmeas9_v3_rigorous_results.json", "w") do f
        JSON.print(f, result)
    end
    println("\n結果を xmeas9_v3_rigorous_results.json に書き出しました。")
end

main()

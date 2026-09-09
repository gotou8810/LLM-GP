using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(9) [反応器温度] 再探索 v2(ラグ変数対応後)の厳密検証
#   Δxmeas_9 = c1*xmeas_21_lag1 + c2*xmeas_9_lag1
#   法則: 一次熱緩和(Newton冷却則) + 自己減衰項。
#   xmeas_21(反応器冷却水出口温度)は反応器自身の冷却ジャケットに属する流束/ユーティリティ
#   変数であり、隣接ユニット(分離器・ストリッパー)の状態量ではないためトポロジー規則に反しない。
#   xmeas_9_lag1(ターゲット自身の1ラグ)は、質量/エネルギー収支則(法則1)が明示的に許容する
#   「自己減衰項」であり、GPループの自己参照ガード(contains_target_variable)は裸のxmeas_9のみ
#   を禁止し、ラグ付きの自己減衰項は意図的に通す設計になっている。
#
#   GPループの命名規約に注意: "_lag1"はGPループの差分予測フレーム(暗黙にt-1を指す)から
#   さらに1つ遡った値を意味する。すなわち Δy(t)=y(t)-y(t-1) を予測する際、
#   "xmeas_21_lag1"はxmeas_21(t-2)、"xmeas_9_lag1"はxmeas_9(t-2)を指す。
#   本スクリプトはこの規約をランごとに正しく再現する(t=1,2はこの規約では特徴量が
#   定義できないため、予測不能な立ち上がり2点として扱い残差評価から除外する)。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

function fit_ols_grouped(df::DataFrame, run_col::Symbol, target::Symbol, cw::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    all_dy = Float64[]
    all_f1 = Float64[]  # xmeas_21_lag1 = cw[t-2]
    all_f2 = Float64[]  # xmeas_9_lag1  = target[t-2]
    for g in grouped
        y = Vector{Float64}(g[!, target])
        x = Vector{Float64}(g[!, cw])
        m = length(y)
        if m < 3
            continue
        end
        for t in 3:m
            push!(all_dy, y[t] - y[t-1])
            push!(all_f1, x[t-2])
            push!(all_f2, y[t-2])
        end
    end
    A = hcat(all_f1, all_f2)
    coeffs = A \ all_dy
    return coeffs
end

function predict_grouped(df::DataFrame, coeffs::Vector{Float64}, run_col::Symbol, target::Symbol, cw::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    p_meas_all = Float64[]
    p_pred_all = Float64[]
    valid_all = Bool[]  # 立ち上がり2点(t=1,2)を除外するためのマスク
    for g in grouped
        y = Vector{Float64}(g[!, target])
        x = Vector{Float64}(g[!, cw])
        m = length(y)
        p_pred = copy(y)
        valid = falses(m)
        for t in 3:m
            dp = coeffs[1] * x[t-2] + coeffs[2] * y[t-2]
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

function evaluate_full(label::String, target::Symbol, cw::Symbol, df_fit::DataFrame, df_holdout::DataFrame, df_faulty::DataFrame)
    println("\n" * "="^70)
    println("モデル: $label")
    println("="^70)

    coeffs = fit_ols_grouped(df_fit, :simulationRun, target, cw)
    println("係数 [c1(xmeas_21_lag1), c2(xmeas_9_lag1)]: ", coeffs)

    _, p_meas_fit, p_pred_fit, valid_fit = predict_grouped(df_fit, coeffs, :simulationRun, target, cw)
    r2_fit = compute_r2(p_meas_fit[valid_fit], p_pred_fit[valid_fit])
    resid_fit = abs.(p_meas_fit .- p_pred_fit)
    threshold = maximum(resid_fit[valid_fit]) * 1.25
    println(@sprintf("FIT正常データ R^2 (立ち上がり2点/ラン除く): %.4f", r2_fit))
    println(@sprintf("FDI検知閾値: %.4f", threshold))

    df_holdout_sorted, p_meas_ho, p_pred_ho, valid_ho = predict_grouped(df_holdout, coeffs, :simulationRun, target, cw)
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
        y = Vector{Float64}(g[!, target])
        x = Vector{Float64}(g[!, cw])
        m = length(y)
        fault_col = g.faultNumber
        p_pred = copy(y)
        resid = zeros(Float64, m)
        for t in 3:m
            dp = coeffs[1] * x[t-2] + coeffs[2] * y[t-2]
            p_pred[t] = y[t-1] + dp
            resid[t] = abs(y[t] - p_pred[t])
        end

        idv = fault_col[1]
        if 1 <= idv <= 20
            idv_totals[idv] += 1
            inject_idx = findfirst(v -> v > 0, fault_col)
            if inject_idx !== nothing
                search_start = max(inject_idx, 3)
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

    result = evaluate_full("XMEAS(9) v2式 (xmeas_21_lag1 - 自己減衰xmeas_9_lag1; Newton冷却則)", :xmeas_9, :xmeas_21, df_fit, df_holdout, df_f)

    open("xmeas9_v2_rigorous_results.json", "w") do f
        JSON.print(f, result)
    end
    println("\n結果を xmeas9_v2_rigorous_results.json に書き出しました。")
end

main()

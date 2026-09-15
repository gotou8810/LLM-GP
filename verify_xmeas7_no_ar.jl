using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(7) [反応器圧力] 自己回帰項(自己減衰項)を除去した式の再検証。
#
# 発見の経緯: CLAUDE.mdのTEP Dynamic Modeling Guidelinesは「自身の過去値である
# 自己回帰項(XMEAS(7)_lag等)は使用を一切禁止する」と明記していたが、これまで
# 「完成」としていた式は自己減衰項 -0.023*xmeas_7_lag1 を使い続けていた
# (contains_target_variable()がラグ付き自己参照を検出できていなかったため)。
# 本スクリプトは、この禁止された項を完全に除去し、流出項(xmeas_10)と切片のみで
# 圧力変化がどこまで説明できるか、素朴予想(MASE、Hyndman & Koehler 2006の定義に
# 準拠しスケールはFITデータで固定)と比較して再検証する。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# メイン式(禁止項除去後): dp = c1*xmeas_10(t-2) + c2   (自己減衰項なし)
function fit_ols_no_ar(df::DataFrame, run_col::Symbol, target::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    all_dy = Float64[]; all_x10 = Float64[]
    for g in grouped
        y = Vector{Float64}(g[!, target]); x10 = Vector{Float64}(g[!, :xmeas_10])
        m = length(y)
        if m < 3; continue; end
        for t in 3:m
            push!(all_dy, y[t]-y[t-1]); push!(all_x10, x10[t-2])
        end
    end
    A = hcat(all_x10, ones(length(all_dy)))
    coeffs = A \ all_dy
    resid = all_dy .- A*coeffs
    ss_res = sum(resid.^2); ss_tot = sum((all_dy .- mean(all_dy)).^2)
    r2_diff = 1 - ss_res/ss_tot
    return coeffs, r2_diff
end

function predict_model(y::Vector{Float64}, x10::Vector{Float64}, coeffs::Vector{Float64})
    m = length(y)
    pred = copy(y)
    for t in 3:m
        dp = coeffs[1]*x10[t-2] + coeffs[2]
        pred[t] = y[t-1] + dp
    end
    return pred
end

function predict_naive(y::Vector{Float64})
    return vcat(y[1], y[1:end-1])
end

function mae_over_runs(df::DataFrame, run_col::Symbol, target::Symbol, coeffs::Vector{Float64})
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    model_errs = Float64[]; naive_errs = Float64[]
    for g in grouped
        y = Vector{Float64}(g[!, target]); x10 = Vector{Float64}(g[!, :xmeas_10])
        m = length(y)
        if m < 3; continue; end
        pred_m = predict_model(y, x10, coeffs)
        pred_n = predict_naive(y)
        append!(model_errs, abs.(y[3:end] .- pred_m[3:end]))
        append!(naive_errs, abs.(y[3:end] .- pred_n[3:end]))
    end
    return model_errs, naive_errs
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"
    df_h_all = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)

    coeffs, r2_diff = fit_ols_no_ar(df_fit, :simulationRun, :xmeas_7)
    println("係数 [xmeas_10(t-2), 切片](自己減衰項なし): ", coeffs)
    println("差分スケールR²(FIT): ", r2_diff)

    # MASE: 分母(素朴予想のスケール)はFITデータで1回だけ計算し固定する
    # (Hyndman & Koehler 2006の定義に準拠。以前の実装はFIT/HOLDOUTで別々に
    # 計算しており、これは厳密なMASEの定義から外れていた)
    model_errs_fit, naive_errs_fit = mae_over_runs(df_fit, :simulationRun, :xmeas_7, coeffs)
    naive_scale = mean(naive_errs_fit)  # FITで固定するスケール
    mae_model_fit = mean(model_errs_fit)
    mase_fit = mae_model_fit / naive_scale
    skill_fit = 1 - mase_fit

    model_errs_ho, naive_errs_ho = mae_over_runs(df_holdout, :simulationRun, :xmeas_7, coeffs)
    mae_model_ho = mean(model_errs_ho)
    mae_naive_ho_ownscale = mean(naive_errs_ho)  # 参考: holdout自身のスケール
    mase_ho = mae_model_ho / naive_scale  # 分母はFITのスケールで固定
    skill_ho = 1 - mase_ho

    println(@sprintf("\nFIT     : モデルMAE=%.4f  素朴スケール(FIT固定)=%.4f  MASE=%.4f  Skill=%.4f",
                      mae_model_fit, naive_scale, mase_fit, skill_fit))
    println(@sprintf("HOLDOUT : モデルMAE=%.4f  (参考:HOLDOUT自身の素朴MAE=%.4f)  MASE(FITスケール基準)=%.4f  Skill=%.4f",
                      mae_model_ho, mae_naive_ho_ownscale, mase_ho, skill_ho))

    # FDIしきい値・FDR評価
    resid_fit_model = abs.(vcat(model_errs_fit))
    threshold = maximum(model_errs_fit) * 1.25
    println(@sprintf("\nFDI検知しきい値: %.4f", threshold))

    df_ho_sorted = sort(df_holdout, [:simulationRun, :sample])
    ho_grouped = groupby(df_ho_sorted, :simulationRun)
    fp_runs = 0; n_ho = length(ho_grouped)
    for g in ho_grouped
        y = Vector{Float64}(g[!, :xmeas_7]); x10 = Vector{Float64}(g[!, :xmeas_10])
        pred = predict_model(y, x10, coeffs)
        resid = abs.(y .- pred)
        if any(resid[3:end] .> threshold)
            fp_runs += 1
        end
    end
    far = fp_runs / n_ho * 100.0
    println(@sprintf("FAR: %.2f%% (%d/%d runs)", far, fp_runs, n_ho))

    df_f_sorted = sort(df_f, [:faultNumber, :simulationRun, :sample])
    grouped_f = groupby(df_f_sorted, [:faultNumber, :simulationRun])
    idv_totals = zeros(Int, 20); idv_detecteds = zeros(Int, 20); idv_delays = [Float64[] for _ in 1:20]
    tp_runs = 0; fn_runs = 0

    for g in grouped_f
        y = Vector{Float64}(g[!, :xmeas_7]); x10 = Vector{Float64}(g[!, :xmeas_10])
        m = nrow(g)
        pred = predict_model(y, x10, coeffs)
        resid = zeros(Float64, m)
        resid[3:end] = abs.(y[3:end] .- pred[3:end])
        fault_col = g.faultNumber
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

    println("\n--- IDVごとのFDR ---")
    report_data = []
    for idv in 1:20
        total = idv_totals[idv]; detected = idv_detecteds[idv]
        fdr = total > 0 ? (detected / total) * 100.0 : 0.0
        add_val = isempty(idv_delays[idv]) ? -1.0 : mean(idv_delays[idv])
        println(@sprintf("  IDV(%2d) | FDR=%6.2f%% | ADD=%s", idv, fdr, add_val < 0 ? "N/A" : @sprintf("%.1f", add_val)))
        push!(report_data, Dict("idv" => idv, "total" => total, "detected" => detected, "fdr" => fdr, "add" => add_val))
    end

    tn_runs = n_ho - fp_runs
    precision = (tp_runs + fp_runs) > 0 ? tp_runs / (tp_runs + fp_runs) : 0.0
    recall = (tp_runs + fn_runs) > 0 ? tp_runs / (tp_runs + fn_runs) : 0.0
    f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0
    println(@sprintf("\nTP=%d FN=%d FP=%d TN=%d  Precision=%.4f Recall=%.4f F1=%.4f FAR=%.2f%%",
                      tp_runs, fn_runs, fp_runs, tn_runs, precision, recall, f1, far))

    result = Dict("coefficients" => coeffs, "r2_diff_fit" => r2_diff,
                  "mae_model_fit" => mae_model_fit, "naive_scale_fit" => naive_scale,
                  "mase_fit" => mase_fit, "skill_fit" => skill_fit,
                  "mae_model_holdout" => mae_model_ho, "mase_holdout" => mase_ho, "skill_holdout" => skill_ho,
                  "far_pct" => far, "f1" => f1, "precision" => precision, "recall" => recall,
                  "idv_results" => report_data)
    open("xmeas7_no_ar_results.json", "w") do f
        JSON.print(f, result)
    end
    println("\n結果を xmeas7_no_ar_results.json に書き出しました。")
end

main()

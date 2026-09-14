using RData, DataFrames, JSON, Statistics, Printf

# 【緊急検証】素朴なベースライン検出器(dp=0、つまり「一段階差分dyの絶対値がしきい値を
# 超えたら異常」というモデルフリーの検出)と、これまで「完成」とされてきた物理式の
# FDI性能(FDR/FAR/F1)を比較する。
#
# 発見の経緯: XMEAS(7)/(16)/(18)の各式について、絶対値レベルでのR^2(0.92〜0.99)は
# 単純な「変化なし」予測(dp=0)のR^2(0.9354等)とほぼ同じであり、差分スケールで見た
# 真のR^2は0.03〜0.0005ときわめて低いことが判明した。これが検出性能(FDR/FAR)にも
# 実質的な差をもたらしていないなら、物理式は素朴な閾値検出器と同等の価値しかない
# ことになる。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

function compute_r2(p_meas::Vector{Float64}, p_pred::Vector{Float64})
    ss_res = sum((p_meas .- p_pred) .^ 2)
    ss_tot = sum((p_meas .- mean(p_meas)) .^ 2)
    return 1.0 - ss_res / ss_tot
end

function evaluate_naive(target::Symbol, df_fit::DataFrame, df_holdout::DataFrame, df_faulty::DataFrame)
    println("\n" * "="^70)
    println("素朴ベースライン(dp=0、変化なし予測): $target")
    println("="^70)

    df_fit_sorted = sort(df_fit, [:simulationRun, :sample])
    grouped_fit = groupby(df_fit_sorted, :simulationRun)
    p_meas_fit = Float64[]; p_pred_fit = Float64[]
    for g in grouped_fit
        y = Vector{Float64}(g[!, target])
        append!(p_meas_fit, y)
        append!(p_pred_fit, vcat(y[1], y[1:end-1]))
    end
    r2_fit = compute_r2(p_meas_fit, p_pred_fit)
    resid_fit = abs.(p_meas_fit .- p_pred_fit)
    threshold = maximum(resid_fit) * 1.25
    println(@sprintf("FIT R^2(絶対値レベル): %.4f", r2_fit))
    println(@sprintf("しきい値: %.4f", threshold))

    df_ho_sorted = sort(df_holdout, [:simulationRun, :sample])
    grouped_ho = groupby(df_ho_sorted, :simulationRun)
    fp_runs = 0
    n_ho = length(grouped_ho)
    for g in grouped_ho
        y = Vector{Float64}(g[!, target])
        pred = vcat(y[1], y[1:end-1])
        resid = abs.(y .- pred)
        if any(resid .> threshold)
            fp_runs += 1
        end
    end
    far = fp_runs / n_ho * 100.0
    println(@sprintf("FAR: %.2f%% (%d/%d runs)", far, fp_runs, n_ho))

    df_f_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])
    grouped_f = groupby(df_f_sorted, [:faultNumber, :simulationRun])
    idv_totals = zeros(Int, 20)
    idv_detecteds = zeros(Int, 20)
    idv_delays = [Float64[] for _ in 1:20]
    tp_runs = 0; fn_runs = 0

    for g in grouped_f
        y = Vector{Float64}(g[!, target])
        pred = vcat(y[1], y[1:end-1])
        resid = abs.(y .- pred)
        fault_col = g.faultNumber
        idv = fault_col[1]
        if 1 <= idv <= 20
            idv_totals[idv] += 1
            inject_idx = findfirst(v -> v > 0, fault_col)
            if inject_idx !== nothing
                detect_rel = findfirst(v -> v > threshold, resid[inject_idx:end])
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
    end

    println("\n--- IDVごとのFDR ---")
    report_data = []
    for idv in 1:20
        total = idv_totals[idv]
        detected = idv_detecteds[idv]
        fdr = total > 0 ? (detected / total) * 100.0 : 0.0
        add_val = isempty(idv_delays[idv]) ? -1.0 : mean(idv_delays[idv])
        println(@sprintf("  IDV(%2d) | FDR=%6.2f%%", idv, fdr))
        push!(report_data, Dict("idv" => idv, "total" => total, "detected" => detected, "fdr" => fdr, "add" => add_val))
    end

    tn_runs = n_ho - fp_runs
    precision = (tp_runs + fp_runs) > 0 ? tp_runs / (tp_runs + fp_runs) : 0.0
    recall = (tp_runs + fn_runs) > 0 ? tp_runs / (tp_runs + fn_runs) : 0.0
    f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0
    println(@sprintf("\nTP=%d FN=%d FP=%d TN=%d  Precision=%.4f Recall=%.4f F1=%.4f FAR=%.2f%%",
                      tp_runs, fn_runs, fp_runs, tn_runs, precision, recall, f1, far))

    return Dict("target" => string(target), "r2_fit" => r2_fit, "far_pct" => far, "precision" => precision,
                "recall" => recall, "f1" => f1, "idv_results" => report_data)
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"
    df_h_all = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)

    results = Dict()
    for target in [:xmeas_7, :xmeas_16, :xmeas_18]
        results[string(target)] = evaluate_naive(target, df_fit, df_holdout, df_f)
    end

    open("naive_baseline_results.json", "w") do f
        JSON.print(f, results)
    end
    println("\n結果を naive_baseline_results.json に書き出しました。")
end

main()

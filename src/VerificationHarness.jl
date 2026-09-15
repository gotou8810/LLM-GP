module VerificationHarness

using RData, DataFrames, JSON, Statistics, Printf

export FeatureSpec, run_full_verification

# ============================================================================
# TEP変数モデリング方法論(.kiro/steering/variable-modeling-methodology.md)の
# 完成判定チェックリストのうち、#5(ラン境界を尊重したfit/holdout分割)、
# #6(持続性ベースライン比較/MASE)、#7(アブレーション)を、対象ごとに個別スクリプトを
# 書き直すことなく一括で実行する共通ハーネス。
#
# 2026-09-09〜15のセッションで、verify_xmeas7_*.jl / verify_xmeas9_*.jl /
# verify_xmeas16/18_*.jl と同じ処理を10個以上の個別スクリプトに書き分けてきた結果、
# MASEのスケール規約の誤り・VLE確認漏れ等、書き直すたびに異なる不整合が発生した。
# 以後は対象ごとに「特徴量リストを渡してこの関数を呼ぶだけ」にする。
#
# 注意: ターゲット自身の値を特徴量に使うこと(自己回帰項)はCLAUDE.mdで一切禁止
# されているため、このハーネス自体がfeaturesにtargetが含まれていないかを
# 実行前に検査し、含まれていればエラーで停止する(GPループのcontains_target_variable
# と同じ趣旨の、ハーネス側の機械的ガード)。
# ============================================================================

"""
1つの特徴量を表す。`column`はデータフレームの列名、`shift`は「予測フレーム(暗黙にt-1)
からさらに何ステップ遡るか」を表す追加シフト(cli.jlの`_lag<K>`と同じ規約: shift=0なら
t-1、shift=1なら"_lag1"相当のt-2)。
"""
struct FeatureSpec
    column::Symbol
    shift::Int
end

function load_dataset(path::String)::DataFrame
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    return df isa DataFrame ? df : DataFrame(df, :auto)
end

function assert_no_self_reference(target::Symbol, features::Vector{FeatureSpec})
    for f in features
        if f.column == target
            error("自己回帰項が検出されました: 特徴量に対象変数自身($(target))が含まれています。" *
                  "CLAUDE.mdのTEP Dynamic Modeling Guidelinesはこれを一切禁止しています。")
        end
    end
end

function predict_dp(feats_vals::Vector{Float64}, coeffs::Vector{Float64})::Float64
    dp = coeffs[end]
    for i in 1:length(feats_vals)
        dp += coeffs[i] * feats_vals[i]
    end
    return dp
end

function fit_ols(df::DataFrame, run_col::Symbol, target::Symbol, features::Vector{FeatureSpec})
    max_shift = isempty(features) ? 0 : maximum(f.shift for f in features)
    min_t = 2 + max_shift
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    all_dy = Float64[]
    feat_cols = [Float64[] for _ in features]
    for g in grouped
        y = Vector{Float64}(g[!, target])
        m = length(y)
        if m < min_t
            continue
        end
        cols = [Vector{Float64}(g[!, f.column]) for f in features]
        for t in min_t:m
            push!(all_dy, y[t] - y[t-1])
            for (i, f) in enumerate(features)
                push!(feat_cols[i], cols[i][t-1-f.shift])
            end
        end
    end
    A = isempty(features) ? ones(length(all_dy), 1) : hcat(feat_cols..., ones(length(all_dy)))
    coeffs = A \ all_dy
    return coeffs, min_t
end

function predict_and_residuals(df::DataFrame, coeffs::Vector{Float64}, run_col::Symbol, target::Symbol,
                                features::Vector{FeatureSpec}, min_t::Int)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    p_meas_all = Float64[]; model_resid_all = Float64[]; naive_resid_all = Float64[]
    for g in grouped
        y = Vector{Float64}(g[!, target])
        m = length(y)
        if m < min_t
            continue
        end
        cols = [Vector{Float64}(g[!, f.column]) for f in features]
        for t in min_t:m
            feats_vals = Float64[cols[i][t-1-f.shift] for (i, f) in enumerate(features)]
            dp = predict_dp(feats_vals, coeffs)
            pred = y[t-1] + dp
            push!(p_meas_all, y[t])
            push!(model_resid_all, abs(y[t] - pred))
            push!(naive_resid_all, abs(y[t] - y[t-1]))
        end
    end
    return p_meas_all, model_resid_all, naive_resid_all
end

function compute_r2_diff(df::DataFrame, coeffs::Vector{Float64}, run_col::Symbol, target::Symbol,
                          features::Vector{FeatureSpec}, min_t::Int)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    all_dy = Float64[]; all_pred_dy = Float64[]
    for g in grouped
        y = Vector{Float64}(g[!, target])
        m = length(y)
        if m < min_t
            continue
        end
        cols = [Vector{Float64}(g[!, f.column]) for f in features]
        for t in min_t:m
            feats_vals = Float64[cols[i][t-1-f.shift] for (i, f) in enumerate(features)]
            push!(all_dy, y[t] - y[t-1])
            push!(all_pred_dy, predict_dp(feats_vals, coeffs))
        end
    end
    ss_res = sum((all_dy .- all_pred_dy) .^ 2)
    ss_tot = sum((all_dy .- mean(all_dy)) .^ 2)
    return 1.0 - ss_res / ss_tot
end

"""
FAR・IDVごとのFDR/ADDを計算する。しきい値はFITデータの最大モデル残差×1.25。
"""
function evaluate_fdi(df_faulty::DataFrame, coeffs::Vector{Float64}, target::Symbol,
                       features::Vector{FeatureSpec}, min_t::Int, threshold::Float64)
    df_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])
    grouped = groupby(df_sorted, [:faultNumber, :simulationRun])
    idv_totals = zeros(Int, 20); idv_detecteds = zeros(Int, 20); idv_delays = [Float64[] for _ in 1:20]
    tp_runs = 0; fn_runs = 0

    for g in grouped
        y = Vector{Float64}(g[!, target])
        m = nrow(g)
        cols = [Vector{Float64}(g[!, f.column]) for f in features]
        fault_col = g.faultNumber
        resid = zeros(Float64, m)
        for t in min_t:m
            feats_vals = Float64[cols[i][t-1-f.shift] for (i, f) in enumerate(features)]
            pred = y[t-1] + predict_dp(feats_vals, coeffs)
            resid[t] = abs(y[t] - pred)
        end
        idv = fault_col[1]
        if 1 <= idv <= 20
            idv_totals[idv] += 1
            inject_idx = findfirst(v -> v > 0, fault_col)
            if inject_idx !== nothing
                search_start = max(inject_idx, min_t)
                detect_rel = search_start <= m ? findfirst(v -> v > threshold, resid[search_start:end]) : nothing
                if detect_rel !== nothing
                    detect_idx = search_start + detect_rel - 1
                    push!(idv_delays[idv], Float64(g.sample[detect_idx] - g.sample[inject_idx]))
                    idv_detecteds[idv] += 1
                    tp_runs += 1
                else
                    fn_runs += 1
                end
            end
        end
    end

    idv_results = []
    for idv in 1:20
        total = idv_totals[idv]; detected = idv_detecteds[idv]
        fdr = total > 0 ? detected / total * 100.0 : 0.0
        add_val = isempty(idv_delays[idv]) ? -1.0 : mean(idv_delays[idv])
        push!(idv_results, Dict("idv" => idv, "total" => total, "detected" => detected, "fdr" => fdr, "add" => add_val))
    end
    return idv_results, tp_runs, fn_runs
end

"""
    run_full_verification(; target, features, label, healthy_path, faulty_path, fit_run_max)

対象変数1つについて、完成判定チェックリスト#5〜#7を一括で実行し、結果をDict(JSON保存も)で返す。
呼び出し側は特徴量リスト(FeatureSpecの配列)を渡すだけでよい。
"""
function run_full_verification(;
    target::Symbol,
    features::Vector{FeatureSpec},
    label::String,
    healthy_path::String = "TEP_FaultFree_Training.RData",
    faulty_path::String = "TEP_Faulty_Training.RData",
    fit_run_max::Int = 400,
    output_path::Union{String,Nothing} = nothing
)
    assert_no_self_reference(target, features)

    df_h_all = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)
    df_fit = filter(row -> row.simulationRun <= fit_run_max, df_h_all)
    df_holdout = filter(row -> row.simulationRun > fit_run_max, df_h_all)

    coeffs, min_t = fit_ols(df_fit, :simulationRun, target, features)
    r2_diff_fit = compute_r2_diff(df_fit, coeffs, :simulationRun, target, features, min_t)

    _, model_resid_fit, naive_resid_fit = predict_and_residuals(df_fit, coeffs, :simulationRun, target, features, min_t)
    naive_scale = mean(naive_resid_fit)  # MASEの分母はFITで固定(Hyndman & Koehler 2006)
    mae_model_fit = mean(model_resid_fit)
    mase_fit = mae_model_fit / naive_scale
    threshold = maximum(model_resid_fit) * 1.25

    _, model_resid_ho, naive_resid_ho = predict_and_residuals(df_holdout, coeffs, :simulationRun, target, features, min_t)
    mae_model_ho = mean(model_resid_ho)
    mase_ho = mae_model_ho / naive_scale
    far = count(r -> r > threshold, model_resid_ho) / length(model_resid_ho) * 100.0
    # FAR はラン単位(1つでも閾値超えがあれば誤報)で計算する方がFDI評価としては標準的
    df_ho_sorted = sort(df_holdout, [:simulationRun, :sample])
    ho_grouped = groupby(df_ho_sorted, :simulationRun)
    fp_runs = 0
    idx = 1
    n_per_run_valid = length(model_resid_ho) ÷ length(ho_grouped)
    for g in ho_grouped
        m = nrow(g)
        n_valid = max(0, m - min_t + 1)
        if n_valid > 0 && any(model_resid_ho[idx:idx+n_valid-1] .> threshold)
            fp_runs += 1
        end
        idx += n_valid
    end
    far_run = fp_runs / length(ho_grouped) * 100.0

    idv_results, tp_runs, fn_runs = evaluate_fdi(df_f, coeffs, target, features, min_t, threshold)
    precision = (tp_runs + fp_runs) > 0 ? tp_runs / (tp_runs + fp_runs) : 0.0
    recall = (tp_runs + fn_runs) > 0 ? tp_runs / (tp_runs + fn_runs) : 0.0
    f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0.0

    # アブレーション: 各特徴量を1つ除いて再フィットし、Skillの変化を見る
    ablation = Dict{String,Any}()
    for i in 1:length(features)
        reduced = [features[j] for j in 1:length(features) if j != i]
        c2, mt2 = fit_ols(df_fit, :simulationRun, target, reduced)
        _, mr_fit2, nr_fit2 = predict_and_residuals(df_fit, c2, :simulationRun, target, reduced, mt2)
        skill2 = 1 - mean(mr_fit2) / mean(nr_fit2)
        ablation["除去:$(features[i].column)"] = Dict("skill_fit" => skill2, "n_features_remaining" => length(reduced))
    end

    println("\n" * "="^70)
    println("検証: $label (対象: $target)")
    println("="^70)
    println("特徴量: ", features)
    println("係数(最後が切片): ", coeffs)
    @printf("R²(差分スケール, FIT): %.4f\n", r2_diff_fit)
    @printf("MASE: FIT=%.4f HOLDOUT=%.4f  Skill: FIT=%.4f HOLDOUT=%.4f\n",
            mase_fit, mase_ho, 1-mase_fit, 1-mase_ho)
    @printf("FAR(ラン単位): %.2f%%\n", far_run)
    @printf("F1: %.4f  (TP=%d FN=%d FP=%d)\n", f1, tp_runs, fn_runs, fp_runs)
    println("\n--- IDVごとのFDR ---")
    for r in idv_results
        @printf("  IDV(%2d) | FDR=%6.2f%%\n", r["idv"], r["fdr"])
    end
    println("\n--- アブレーション(特徴量除去時のSkill) ---")
    for (k, v) in ablation
        println("  $k: ", v)
    end

    result = Dict(
        "label" => label, "target" => string(target),
        "coefficients" => coeffs, "r2_diff_fit" => r2_diff_fit,
        "naive_scale_fit" => naive_scale, "mae_model_fit" => mae_model_fit, "mase_fit" => mase_fit, "skill_fit" => 1-mase_fit,
        "mae_model_holdout" => mae_model_ho, "mase_holdout" => mase_ho, "skill_holdout" => 1-mase_ho,
        "threshold" => threshold, "far_run_pct" => far_run,
        "precision" => precision, "recall" => recall, "f1" => f1,
        "idv_results" => idv_results, "ablation" => ablation
    )
    if output_path !== nothing
        open(output_path, "w") do f
            JSON.print(f, result)
        end
        println("\n結果を $output_path に書き出しました。")
    end
    return result
end

end # module

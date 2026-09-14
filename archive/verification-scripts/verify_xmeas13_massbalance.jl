using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(13) [分離器圧力] の質量収支ファースト再導出 (Method A)
#
# XMEAS(7)反応器モデルと同じ方法論: dP/dt ∝ F_in - F_out を先に立て、
# 分離器の気相制御体積に実際に出入りするフラックス変数「だけ」を使う。
#   流入: XMEAS(6) (反応器フィード。反応器を経由して分離器に届くまでのむだ時間をラグで同定)
#   流出: XMEAS(5) (リサイクルガス流量), XMEAS(10) (パージ流量)
#   自己減衰項: -c*XMEAS(13)_lag1 (反応器モデルと同型のオリフィス流出特性)
#
# xmeas_16, xmeas_11, xmeas_20, 組成変数等は一切使わない
# (フェーズ0(a)のユニット状態量禁止ルールにも合致する、生粋のフラックスのみの構成)

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

function lagged(x::Vector{Float64}, lag::Int)
    n = length(x)
    if lag == 0
        return copy(x)
    end
    out = Vector{Float64}(undef, n)
    out[1:lag] .= x[1]
    out[lag+1:end] .= x[1:end-lag]
    return out
end

# 質量収支項を構築する。xmeas_6のラグは可変(むだ時間の同定対象)
function build_features(df::DataFrame, lag6::Int)
    x5 = Vector{Float64}(df.xmeas_5)
    x6 = Vector{Float64}(df.xmeas_6)
    x10 = Vector{Float64}(df.xmeas_10)
    x13 = Vector{Float64}(df.xmeas_13)

    f_in = lagged(x6, lag6)
    f_out_recycle = lagged(x5, 1)
    f_out_purge = lagged(x10, 1)
    f_selfdamp = lagged(x13, 1)

    return (f_in, f_out_recycle, f_out_purge, f_selfdamp)
end

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

function fit_and_r2(df_h::DataFrame, lag6::Int)
    p_h = Vector{Float64}(df_h.xmeas_13)
    dp_h_actual = p_h[2:end] .- p_h[1:end-1]
    feats_h_full = build_features(df_h, lag6)
    nfeat = length(feats_h_full)
    feats_h = ntuple(i -> feats_h_full[i][1:end-1], nfeat)

    A = hcat(feats_h..., ones(length(feats_h[1])))
    coeffs = A \ dp_h_actual

    p_pred_h = run_1step_prediction(p_h, feats_h, coeffs)
    ss_res = sum((p_h .- p_pred_h) .^ 2)
    ss_tot = sum((p_h .- mean(p_h)) .^ 2)
    r2 = 1.0 - (ss_res / ss_tot)
    return r2, coeffs
end

function evaluate_model(label::String, df_h::DataFrame, df_f::DataFrame, lag6::Int)
    p_h = Vector{Float64}(df_h.xmeas_13)
    dp_h_actual = p_h[2:end] .- p_h[1:end-1]
    p_f = Vector{Float64}(df_f.xmeas_13)

    feats_h_full = build_features(df_h, lag6)
    feats_f_full = build_features(df_f, lag6)
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

    println("\n--- モデル: $label (xmeas_6 lag=$lag6) ---")
    println("係数(F_in, F_out_recycle, F_out_purge, 自己減衰, 切片): ", coeffs)
    println("正常データ R^2: ", round(r2, digits=4))
    println("FDI検知閾値: ", round(threshold, digits=4), " kPa")

    report_data = []
    for idv in 1:20
        total = idv_totals[idv]
        detected = idv_detecteds[idv]
        fdr = total > 0 ? (detected / total) * 100.0 : 0.0
        add_val = isempty(idv_delays[idv]) ? -1.0 : mean(idv_delays[idv])
        println(@sprintf("  IDV(%2d) | FDR=%6.2f%% | ADD=%s", idv, fdr,
                          add_val < 0 ? "N/A" : @sprintf("%.1f分", add_val)))
        push!(report_data, Dict("idv" => idv, "total" => total, "detected" => detected, "fdr" => fdr, "add" => add_val))
    end

    return Dict("label" => label, "lag6" => lag6, "coefficients" => coeffs,
                "r2_normal" => r2, "threshold" => threshold, "idv_results" => report_data)
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"

    if !isfile(healthy_path) || !isfile(faulty_path)
        error("Required TEP dataset files are missing.")
    end

    df_h = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)

    # Step 1: xmeas_6のむだ時間(0〜8分)をグリッドサーチしてR^2最大のラグを同定
    println("\n=== Step 1: xmeas_6 むだ時間の同定 (正常データR^2グリッドサーチ) ===")
    best_lag = 0
    best_r2 = -Inf
    for lag6 in 0:8
        r2, _ = fit_and_r2(df_h, lag6)
        println(@sprintf("  lag=%d -> R^2=%.4f", lag6, r2))
        if r2 > best_r2
            best_r2 = r2
            best_lag = lag6
        end
    end
    println("最良ラグ: lag6=$best_lag (R^2=$(round(best_r2, digits=4)))")

    # Step 2: 最良ラグで全データ評価(正常R^2 + 異常データFDR/ADD)
    result = evaluate_model("質量収支モデル(F_in-F_out, xmeas_16不使用)", df_h, df_f, best_lag)

    output = Dict("lag_search" => Dict("best_lag6" => best_lag, "best_r2" => best_r2), "model" => result)
    open("xmeas13_massbalance_results.json", "w") do f
        JSON.print(f, output)
    end
    println("\n結果を xmeas13_massbalance_results.json に書き出しました。")
end

main()

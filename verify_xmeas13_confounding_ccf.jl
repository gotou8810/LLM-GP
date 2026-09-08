using RData, DataFrames, Statistics, Printf

# フェーズ0(b)ではなく、法則検証の第9層: 閉ループ制御による交絡の検出
#
# TEPは常に基本制御ループ(PI制御)が稼働した状態のデータである。単純な回帰係数は、
# 「開ループの物理法則」ではなく「制御器の応答パターン」を拾ってしまう可能性がある。
#
# 検定方法: 相互相関関数(CCF)の非対称性を見る。
# 候補変数X(原因のはず)とターゲットY=xmeas_13(結果のはず)について、
# ラグkを-15分から+15分まで振って corr(X(t-k), Y(t)) を計算する。
#
#   - 真に物理的な因果(Xが先行してYを動かす)なら、正のラグ(k>0, Xが過去)で
#     相関が強く立ち上がり、負のラグ(k<0, Xが未来=Yより後)では弱いはず(非対称)。
#   - Xが実は制御ループを介してYに"反応"しているだけ(交絡)なら、
#     負のラグ側にも同程度以上の相関が現れる(対称、または逆転)はず
#     — Yの変化を見てから制御器がXを動かす、という逆方向の情報の流れがあるため。
#
# これは形式的なGranger因果性検定の簡易版であり、交絡の有無を確定させるものではないが、
# 「本当に上流→下流の一方向の関係か」を独立した角度から診断する材料になる。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# ラン単位でCCFを計算し、全ランで平均する(ラン境界をまたいでシフトしない)
# xmeas_13自身の自己相関がラグ15分でも0.49と極めて高く(持続的な系列)、
# 生の水準(レベル)のままCCFを取ると、真の因果関係がなくてもほぼ何とでも
# 対称的な相関が出てしまうことが判明したため、差分系列(Δ)でCCFを取り直す
# (GPループ自体がΔyを使っているのと同じ理由: 持続性を除去して真の動的関係を見る)。
function cross_correlation_by_run(df::DataFrame, xcol::Symbol, ycol::Symbol, max_lag::Int; use_diff::Bool=true)
    df_sorted = sort(df, [:simulationRun, :sample])
    grouped = groupby(df_sorted, :simulationRun)

    lags = -max_lag:max_lag
    corr_sums = zeros(Float64, length(lags))
    corr_counts = zeros(Int, length(lags))

    for g in grouped
        x_raw = Vector{Float64}(g[!, xcol])
        y_raw = Vector{Float64}(g[!, ycol])
        if use_diff
            x = diff(x_raw)
            y = diff(y_raw)
        else
            x = x_raw
            y = y_raw
        end
        n = length(x)
        for (li, k) in enumerate(lags)
            # corr(X(t-k), Y(t)): k>0 は X が過去(先行)、k<0 は X が未来(Yに反応)
            if k >= 0
                xs = x[1:n-k]
                ys = y[1+k:n]
            else
                xs = x[1-k:n]
                ys = y[1:n+k]
            end
            if length(xs) > 10 && std(xs) > 1e-10 && std(ys) > 1e-10
                c = cor(xs, ys)
                if !isnan(c)
                    corr_sums[li] += c
                    corr_counts[li] += 1
                end
            end
        end
    end

    return lags, corr_sums ./ max.(corr_counts, 1)
end

function diagnose_asymmetry(lags, avg_corr)
    pos_idx = findall(k -> k > 0, lags)
    neg_idx = findall(k -> k < 0, lags)
    zero_idx = findfirst(k -> k == 0, lags)

    pos_peak = maximum(abs.(avg_corr[pos_idx]))
    neg_peak = maximum(abs.(avg_corr[neg_idx]))
    pos_peak_lag = lags[pos_idx[argmax(abs.(avg_corr[pos_idx]))]]
    neg_peak_lag = lags[neg_idx[argmax(abs.(avg_corr[neg_idx]))]]

    asymmetry_ratio = neg_peak / max(pos_peak, 1e-10)

    if asymmetry_ratio < 0.5
        verdict = "因果的(causal-like): 正のラグ側が明確に優勢。Xが先行してYに影響している構造と整合的"
    elseif asymmetry_ratio > 1.5
        verdict = "逆転(reversed): 負のラグ側が優勢。Yの変化にXが反応している(制御ループによる交絡)可能性が高い"
    else
        verdict = "対称的(symmetric): 正負のラグで相関の強さが同程度。交絡または双方向の関係が疑われる"
    end

    return (pos_peak=pos_peak, pos_peak_lag=pos_peak_lag, neg_peak=neg_peak, neg_peak_lag=neg_peak_lag,
            asymmetry_ratio=asymmetry_ratio, verdict=verdict)
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    if !isfile(healthy_path)
        error("Required TEP dataset file is missing.")
    end
    df = load_dataset(healthy_path)

    target = :xmeas_13
    candidates = [:xmeas_6, :xmeas_10, :xmeas_11, :xmv_5, :xmeas_20]
    max_lag = 15

    println("\n" * "="^78)
    println("閉ループ制御による交絡の検定: 相互相関関数(CCF)の非対称性(差分系列)")
    println("ターゲット: Δ$target / 最大ラグ: ±$(max_lag)")
    println("(注: 生の水準でのCCFはxmeas_13自身の自己相関がラグ15分で0.49と非常に高く、")
    println(" 持続性だけで対称的な相関が出てしまうことが判明したため、差分系列を使う)")
    println("="^78)

    results = Dict()
    for cand in candidates
        lags, avg_corr = cross_correlation_by_run(df, cand, target, max_lag; use_diff=true)
        diag = diagnose_asymmetry(lags, avg_corr)
        println("\n--- $cand ---")
        println(@sprintf("  正のラグ側ピーク: |corr|=%.4f (lag=%+d)  [Xが先行]", diag.pos_peak, diag.pos_peak_lag))
        println(@sprintf("  負のラグ側ピーク: |corr|=%.4f (lag=%+d)  [Xが追従/反応]", diag.neg_peak, diag.neg_peak_lag))
        println(@sprintf("  非対称性比(負/正): %.2f", diag.asymmetry_ratio))
        println("  判定: ", diag.verdict)
        results[cand] = diag
    end

    println("\n" * "="^78)
    println("まとめ")
    println("="^78)
    for cand in candidates
        d = results[cand]
        println(@sprintf("  %-12s asymmetry_ratio=%.2f -> %s", string(cand), d.asymmetry_ratio,
                          d.asymmetry_ratio < 0.5 ? "因果的" : (d.asymmetry_ratio > 1.5 ? "逆転(要注意)" : "対称的(要注意)")))
    end
end

main()

using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(7)の式(係数はverify_xmeas7_harness.jlで1ステップ用に既にフィット済みのものを
# 再利用)について、複数の予測ホライズン(h=1,3,5,10,20,30ステップ先)でSkill Scoreを
# 計算する。
#
# 目的: Skill Scoreはサンプリング間隔(Δt)に依存する相対指標であり、単一のホライズン
# (1ステップ)だけで「素朴予想を上回るか」を判定するのは、間隔の選び方に結果が
# 左右されるという弱点があった(2026-09-14の議論)。素朴予想はホライズンが伸びるほど
# 急速に弱くなるはずなので、本当に因果的な式であれば、ホライズンを伸ばすほど
# Skillが伸びていく(あるいは維持される)ことが期待される。逆に、Skillがホライズンを
# 伸ばすと消えてしまうなら、1ステップでの正のSkillはノイズ的な効果だった疑いが強まる。
#
# 手法: 1ステップ用に既にフィットされた係数(c1, c2)をそのまま使い、hステップ先の
# 変化 y(t)-y(t-h) を、各ステップの寄与 dp(s) = c1*x10(s-2) + c2 をh回足し合わせて
# 予測する(係数は再フィットしない — 1ステップの関係が本当に因果的なら、
# 単純に足し合わせるだけでhステップ先もある程度説明できるはず、という検定)。

const COEFFS = [21.99711695102674, -7.412602475211624]  # verify_xmeas7_harness.jlの結果

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    return df isa DataFrame ? df : DataFrame(df, :auto)
end

function dp_step(x10_val::Float64)
    return COEFFS[1] * x10_val + COEFFS[2]
end

function evaluate_horizon(df::DataFrame, run_col::Symbol, target::Symbol, h::Int)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    model_errs = Float64[]; naive_errs = Float64[]
    min_t = h + 2  # 各ステップの寄与にx10(s-2)が必要なため、最初のh+1ステップは不可

    for g in grouped
        y = Vector{Float64}(g[!, target])
        x10 = Vector{Float64}(g[!, :xmeas_10])
        m = length(y)
        if m < min_t
            continue
        end
        for t in min_t:m
            # hステップ分の寄与を積み上げる: dp(s) for s = t-h+1 .. t (各々 x10(s-2)を使う)
            cum_dp = 0.0
            for s in (t-h+1):t
                cum_dp += dp_step(x10[s-2])
            end
            pred = y[t-h] + cum_dp
            push!(model_errs, abs(y[t] - pred))
            push!(naive_errs, abs(y[t] - y[t-h]))
        end
    end
    return mean(model_errs), mean(naive_errs)
end

function main()
    df_h_all = load_dataset("TEP_FaultFree_Training.RData")
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)

    println("\n係数(1ステップ用、再利用): ", COEFFS)
    println("\n" * "="^70)
    println(@sprintf("%6s | %10s %10s %8s | %10s %10s %8s", "h", "modelMAE", "naiveMAE", "Skill", "modelMAE", "naiveMAE", "Skill"))
    println(@sprintf("%6s | %10s %10s %8s | %10s %10s %8s", "", "FIT", "FIT", "FIT", "HOLDOUT", "HOLDOUT", "HOLDOUT"))
    println("-"^70)

    results = []
    for h in [1, 3, 5, 10, 20, 30, 50]
        mm_fit, nm_fit = evaluate_horizon(df_fit, :simulationRun, :xmeas_7, h)
        mm_ho, nm_ho = evaluate_horizon(df_holdout, :simulationRun, :xmeas_7, h)
        skill_fit = 1 - mm_fit/nm_fit
        skill_ho = 1 - mm_ho/nm_ho
        println(@sprintf("%6d | %10.4f %10.4f %8.4f | %10.4f %10.4f %8.4f",
                          h, mm_fit, nm_fit, skill_fit, mm_ho, nm_ho, skill_ho))
        push!(results, Dict("h" => h, "model_mae_fit" => mm_fit, "naive_mae_fit" => nm_fit, "skill_fit" => skill_fit,
                             "model_mae_holdout" => mm_ho, "naive_mae_holdout" => nm_ho, "skill_holdout" => skill_ho))
    end

    open("xmeas7_multihorizon_results.json", "w") do f
        JSON.print(f, results)
    end
    println("\n結果を xmeas7_multihorizon_results.json に書き出しました。")
end

main()

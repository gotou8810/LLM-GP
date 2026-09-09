using RData, DataFrames, JSON, Statistics, Printf

# XMEAS(7)アブレーション式(xmeas_10_lag1 + 自己減衰xmeas_7_lag1)について、
# ①実測値・②式による予測値・③素朴予想(dp=0、直前の値をそのまま使う)を
# 同じ土台で比較し、可視化用のJSONを書き出す。
#
# 目的: Skill Score(相対指標)だけでは「実測値と式が絶対的にどれだけ一致しているか」
# を証明できないという指摘を受け、実単位でのMAE(平均絶対誤差)を①式 ②素朴予想の
# 両方について並記し、あわせて代表的な正常ラン・異常ランの時系列を可視化データとして
# 保存する。

function load_dataset(path::String)
    println("Loading dataset: $path ...")
    objs = RData.load(path)
    df = first(values(objs))
    if !(df isa DataFrame)
        df = DataFrame(df, :auto)
    end
    return df
end

# メイン式: dp = c1*xmeas_10(t-2) + c2*xmeas_7(t-1) + intercept
function fit_ols(df::DataFrame, run_col::Symbol, target::Symbol)
    df_sorted = sort(df, [run_col, :sample])
    grouped = groupby(df_sorted, run_col)
    all_dy = Float64[]; all_x10 = Float64[]; all_x7 = Float64[]
    for g in grouped
        y = Vector{Float64}(g[!, target]); x10 = Vector{Float64}(g[!, :xmeas_10])
        m = length(y)
        if m < 3; continue; end
        for t in 3:m
            push!(all_dy, y[t]-y[t-1]); push!(all_x10, x10[t-2]); push!(all_x7, y[t-1])
        end
    end
    A = hcat(all_x10, all_x7, ones(length(all_dy)))
    return A \ all_dy
end

function predict_model(y::Vector{Float64}, x10::Vector{Float64}, coeffs::Vector{Float64})
    m = length(y)
    pred = copy(y)
    for t in 3:m
        dp = coeffs[1]*x10[t-2] + coeffs[2]*y[t-1] + coeffs[3]
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
    return mean(model_errs), mean(naive_errs)
end

function main()
    healthy_path = "TEP_FaultFree_Training.RData"
    faulty_path = "TEP_Faulty_Training.RData"
    df_h_all = load_dataset(healthy_path)
    df_f = load_dataset(faulty_path)
    df_fit = filter(row -> row.simulationRun <= 400, df_h_all)
    df_holdout = filter(row -> row.simulationRun > 400, df_h_all)

    coeffs = fit_ols(df_fit, :simulationRun, :xmeas_7)
    println("係数 [xmeas_10(t-2), xmeas_7自己減衰(t-1), 切片]: ", coeffs)

    mae_model_fit, mae_naive_fit = mae_over_runs(df_fit, :simulationRun, :xmeas_7, coeffs)
    mae_model_ho, mae_naive_ho = mae_over_runs(df_holdout, :simulationRun, :xmeas_7, coeffs)
    skill_fit = 1 - mae_model_fit/mae_naive_fit
    skill_ho = 1 - mae_model_ho/mae_naive_ho

    println(@sprintf("FIT     : モデルMAE=%.4f kPa  素朴MAE=%.4f kPa  Skill=%.4f", mae_model_fit, mae_naive_fit, skill_fit))
    println(@sprintf("HOLDOUT : モデルMAE=%.4f kPa  素朴MAE=%.4f kPa  Skill=%.4f", mae_model_ho, mae_naive_ho, skill_ho))

    # 可視化用データ: 代表的な正常ラン(ホールドアウトの最初のラン)全区間
    df_ho_sorted = sort(df_holdout, [:simulationRun, :sample])
    normal_run = filter(row -> row.simulationRun == df_ho_sorted.simulationRun[1], df_ho_sorted)
    y_n = Vector{Float64}(normal_run.xmeas_7); x10_n = Vector{Float64}(normal_run.xmeas_10)
    pred_model_n = predict_model(y_n, x10_n, coeffs)
    pred_naive_n = predict_naive(y_n)

    # 可視化用データ: 代表的な異常ラン(IDV(1)、最初のシミュレーションラン)
    df_f_sorted = sort(df_f, [:faultNumber, :simulationRun, :sample])
    fault_run = filter(row -> row.faultNumber == 1 && row.simulationRun == 1, df_f_sorted)
    y_f = Vector{Float64}(fault_run.xmeas_7); x10_f = Vector{Float64}(fault_run.xmeas_10)
    pred_model_f = predict_model(y_f, x10_f, coeffs)
    pred_naive_f = predict_naive(y_f)
    fault_flag = Vector{Int}(fault_run.faultNumber)
    inject_idx = findfirst(v -> v > 0, fault_flag)

    result = Dict(
        "coefficients" => coeffs,
        "mae" => Dict(
            "fit" => Dict("model" => mae_model_fit, "naive" => mae_naive_fit, "skill" => skill_fit),
            "holdout" => Dict("model" => mae_model_ho, "naive" => mae_naive_ho, "skill" => skill_ho)
        ),
        "normal_run" => Dict(
            "run" => normal_run.simulationRun[1], "sample" => normal_run.sample,
            "actual" => y_n, "model" => pred_model_n, "naive" => pred_naive_n
        ),
        "fault_run" => Dict(
            "idv" => 1, "run" => 1, "sample" => fault_run.sample,
            "actual" => y_f, "model" => pred_model_f, "naive" => pred_naive_f,
            "inject_idx" => inject_idx
        )
    )
    open("xmeas7_comparison_viz.json", "w") do f
        JSON.print(f, result)
    end
    println("\n結果を xmeas7_comparison_viz.json に書き出しました。")
end

main()

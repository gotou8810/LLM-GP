# fitness.jl

using DataFrames
using Statistics

"""
ASTのノード数をカウントし、式の複雑さを評価します。
"""
function count_nodes(expr::Expr)::Int
    count = 1 # 自分自身
    for arg in expr.args
        if arg isa Expr
            count += count_nodes(arg)
        else
            count += 1
        end
    end
    return count
end

function count_nodes(x::Any)::Int
    return 1
end

"""
パース済み関数、係数、データ、実測値(y)を受け取り、総合適応度スコアを返す。
評価指標は平均絶対誤差(MAE、外れ値による最適化の不安定化を防ぐため error_cap で上限を設ける)とし、
ノード数に比例する複雑さペナルティを加算する。cli.jl の実行時目的関数と同一のロジック。
"""
function calculate_fitness(eval_func::Function, coeffs::Vector{Float64}, data_df::DataFrame, target_y::Vector{Float64}, formula_expr::Expr;
                            penalty_weight::Float64=0.001, error_cap::Float64=20.0,
                            on_error::Union{Function,Nothing}=nothing)::Float64
    n = nrow(data_df)
    if n == 0
        return Inf
    end

    errors = Float64[]
    for i in 1:n
        row = data_df[i, :]
        try
            pred = eval_func(coeffs, row)

            if isnan(pred) || isinf(pred)
                push!(errors, error_cap)
            else
                err = abs(pred - target_y[i])
                push!(errors, min(err, error_cap))
            end
        catch e
            if on_error !== nothing
                on_error(e)
            end
            push!(errors, error_cap)
        end
    end

    mae = mean(errors)
    complexity_penalty = count_nodes(formula_expr) * penalty_weight

    return mae + complexity_penalty
end
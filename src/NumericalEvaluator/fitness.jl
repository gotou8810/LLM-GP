# fitness.jl

using DataFrames

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
ペナルティ（制約違反、複雑さ）はここに合算される。
"""
function calculate_fitness(eval_func::Function, coeffs::Vector{Float64}, data_df::DataFrame, target_y::Vector{Float64}, formula_expr::Expr)::Float64
    n = nrow(data_df)
    if n == 0
        return Inf
    end
    
    # 予測値の計算
    squared_errors = 0.0
    for i in 1:n
        row = data_df[i, :]
        try
            pred = eval_func(coeffs, row)
            
            # NaN や Inf の場合は大きなペナルティを与える
            if isnan(pred) || isinf(pred)
                return Inf
            end
            
            squared_errors += (pred - target_y[i])^2
        catch e
            # 評価エラー（ゼロ除算など）の場合は最悪の適応度を返す
            return Inf
        end
    end
    
    rmse = sqrt(squared_errors / n)
    
    # ペナルティの計算（ここでは単純にノード数に比例するペナルティとする）
    # 例：ノード1つにつき 0.01 のペナルティを加算
    penalty_weight = 0.01
    complexity_penalty = count_nodes(formula_expr) * penalty_weight
    
    # 総合Fitness
    return rmse + complexity_penalty
end
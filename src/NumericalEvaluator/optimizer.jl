# optimizer.jl

using BlackBoxOptim

"""
目的関数(Fitness計算関数)、変数の数(係数の数)、探索範囲、ハイパーパラメータを受け取り、
最適化された係数と最小化されたFitness値を返す。
"""
function optimize_coefficients(objective_func::Function, num_coeffs::Int; search_range=(-10.0, 10.0), max_steps=1000)
    # 係数が0個（定数のみの式など）の場合は、最適化をスキップ
    if num_coeffs == 0
        return (Float64[], objective_func(Float64[]))
    end

    # BlackBoxOptim の設定
    # search_range が単一のタプルの場合は、全変数に同じ範囲を適用
    ranges = fill(search_range, num_coeffs)
    
    res = bboptimize(
        objective_func; 
        SearchRange = ranges, 
        NumDimensions = num_coeffs,
        MaxSteps = max_steps,
        TraceMode = :silent # ログ出力を抑制
    )
    
    best_coeffs = best_candidate(res)
    best_fit = best_fitness(res)
    
    return (best_coeffs, best_fit)
end
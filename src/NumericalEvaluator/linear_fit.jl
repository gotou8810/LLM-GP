# linear_fit.jl

using DataFrames
using Random
using LinearAlgebra

"""
eval_func(coeffs, row) が係数 c について線形かどうかを数値的に検証し、
線形であれば厳密な最小二乗法(OLS)で係数を同定して返す。線形でなければ nothing を返す。

背景: 従来はBlackBoxOptim(有界・確率的なMAE最小化)のみで係数を求めていたが、
xv5/xmeas_20/xmeas_10のような多重共線性の強い変数群では、限られた反復回数の
探索が真の最適解に収束せず、符号すら不安定な解を返すことがXMEAS(13)の検証で
実際に確認された(GPループ内の500行サンプルでは符号が"合格"していたのに、
同じ変数の厳密なOLSでは全データでも小標本でも一貫して逆符号だった)。
数式が係数について線形である限り、OLSは唯一のグローバル最適解を持ち、
探索の収束性に依存しないため、可能な限りこちらを優先して使う。

線形性の判定はASTの記号解析ではなく、重ね合わせの原理
(f(c) = h + G*c が成り立つか)を複数のランダムな係数ベクトルで数値的に検証する方式を採る。
"""
function try_linear_ols_fit(eval_func::Function, num_coeffs::Int, df::DataFrame, target_y::Vector{Float64};
                             rng_seed::Int=42, tol::Float64=1e-6)
    if num_coeffs == 0
        return nothing
    end
    n = nrow(df)
    if n < num_coeffs + 5
        return nothing
    end

    rows = [df[i, :] for i in 1:n]

    # h(row) = f(0, row) (定数項・係数のかからない部分)
    zero_c = zeros(Float64, num_coeffs)
    h = Vector{Float64}(undef, n)
    for i in 1:n
        h[i] = Base.invokelatest(eval_func, zero_c, rows[i])
    end
    if any(!isfinite, h)
        return nothing
    end

    # G[:, j] = f(e_j, row) - h(row) (c[j]の単位変化に対する応答)
    G = Matrix{Float64}(undef, n, num_coeffs)
    for j in 1:num_coeffs
        e_j = zeros(Float64, num_coeffs)
        e_j[j] = 1.0
        for i in 1:n
            G[i, j] = Base.invokelatest(eval_func, e_j, rows[i]) - h[i]
        end
    end
    if any(!isfinite, G)
        return nothing
    end

    # 重ね合わせの原理をランダムな係数ベクトルで数値検証する(記号解析ではなく実測ベース)
    rng = MersenneTwister(rng_seed)
    for _ in 1:3
        c_test = randn(rng, num_coeffs) .* 3.0
        predicted_linear = h .+ G * c_test
        actual = Vector{Float64}(undef, n)
        for i in 1:n
            actual[i] = Base.invokelatest(eval_func, c_test, rows[i])
        end
        if any(!isfinite, actual)
            return nothing
        end
        scale = max(1.0, maximum(abs.(actual)))
        if maximum(abs.(actual .- predicted_linear)) > tol * scale
            return nothing  # 非線形(exp/sqrt/交互作用等)と判定、呼び出し側でBlackBoxOptimにフォールバック
        end
    end

    # 線形と確認できたので、厳密なOLSで係数同定する(BlackBoxOptimの近似探索より常に優れる)
    coeffs = G \ (target_y .- h)
    return coeffs
end

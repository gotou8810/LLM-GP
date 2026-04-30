# cli.jl

using JSON
using DataFrames
using Statistics

"""
CLIエントリポイント
標準入力からJSONを受け取り、パースと評価を行い、結果をJSON形式で標準出力に返す。
"""
function main(in_io::IO=stdin, out_io::IO=stdout)
    input_str = read(in_io, String)

    local parsed_json
    try
        parsed_json = JSON.parse(input_str)
    catch e
        error_resp = Dict(
            "status" => "error",
            "error_type" => "ParseError",
            "message" => "Invalid JSON input: $(e)"
        )
        JSON.print(out_io, error_resp)
        return
    end

    # 必要なパラメータの抽出
    formula_str = get(parsed_json, "formula", "")
    target_var = get(parsed_json, "target_variable", "")
    dataset_path = get(parsed_json, "dataset_path", "")
    hparams = get(parsed_json, "hyperparameters", Dict())

    max_steps = get(hparams, "max_steps", 1000)
    search_range = get(hparams, "search_range", [-10.0, 10.0])
    search_range_tuple = (Float64(search_range[1]), Float64(search_range[2]))

    try
        # 1. データのロード
        df_raw = TEPDataLoader.load_rdata(dataset_path)

        # 数値列のみを抽出（正規化のため）
        numeric_cols = [n for n in names(df_raw) if eltype(df_raw[!, n]) <: Number]
        df_numeric = df_raw[:, numeric_cols]

        # 2. データの正規化 (Z-score: (x - mean) / std)
        # 目的変数も正規化することで、係数 c の探索を容易にする
        means = Dict(col => mean(df_numeric[!, col]) for col in numeric_cols)
        stds = Dict(col => std(df_numeric[!, col]) for col in numeric_cols)

        df_norm = copy(df_numeric)
        for col in numeric_cols
            if stds[col] > 0
                df_norm[!, col] = (df_numeric[!, col] .- means[col]) ./ stds[col]
            else
                df_norm[!, col] .= 0.0
            end
        end

        if !(target_var in numeric_cols)
            error("Target variable $target_var not found or not numeric.")
        end
        target_y = Vector{Float64}(df_norm[:, target_var])

        # 3. 数式のパース
        var_names = numeric_cols
        eval_func, num_coeffs, formula_expr = parse_formula_full(formula_str, var_names)

        # 4. 係数の最適化
        # 目的関数: 予測値と実測値のRMSE + ペナルティ
        penalty_weight = 0.001 # 少し弱める
        node_count = count_nodes(formula_expr)

        # 高速化のため、最適化時はサンプリングしたデータを使用する
        total_rows = nrow(df_norm)
        # 安定した後半のデータからランダムにサンプリング
        sample_indices = rand(101:total_rows, min(500, total_rows - 100))
        df_sample = df_norm[sample_indices, :]
        target_sample = target_y[sample_indices]

        objective = (c) -> begin
            errors = Float64[]
            for i in 1:nrow(df_sample)
                row = df_sample[i, :]
                try
                    pred = eval_func(c, row)
                    # 予測値を現実的な範囲（正規化データなので-20〜20程度）に収める
                    if isnan(pred) || isinf(pred)
                        push!(errors, 20.0)
                    else
                        err = abs(pred - target_sample[i])
                        push!(errors, min(err, 20.0))
                    end
                catch
                    push!(errors, 20.0)
                end
            end
            return mean(errors) + (node_count * penalty_weight)
        end

        if num_coeffs > 0
            best_coeffs, best_fitness = optimize_coefficients(
                objective, num_coeffs; 
                search_range=search_range_tuple, 
                max_steps=max_steps
            )
        else
            # 係数がない場合はそのまま評価
            best_coeffs = Float64[]
            best_fitness = objective(best_coeffs)
        end

        # 5. 結果の算出
        penalty = node_count * penalty_weight
        rmse = max(0.0, best_fitness - penalty)

        response = Dict(
            "status" => "success",
            "fitness" => isnan(best_fitness) ? 1e18 : best_fitness,
            "rmse" => isnan(rmse) ? 1e18 : rmse,
            "penalty" => penalty,
            "coefficients" => best_coeffs
        )
        JSON.print(out_io, response)

    catch e
        error_resp = Dict(
            "status" => "error",
            "error_type" => string(typeof(e)),
            "message" => "Evaluation failed: $(e)\n$(stacktrace(catch_backtrace())[1:3])"
        )
        JSON.print(out_io, error_resp)
    end
end
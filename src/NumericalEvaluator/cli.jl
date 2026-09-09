# cli.jl

using JSON
using DataFrames
using Statistics

# "<xmeas_N|xmv_N>_lag<K>" という命名規則の変数トークンを数式中から検出するための正規表現。
# プロンプト(prompt_manager.py)がLLMに「flux変数はラグ付きでも使える」と伝えているにもかかわらず、
# 以前はこのCLI側にラグ列を生成する仕組みが一切なく、LLMが xmeas_21_lag5 等を提案しても
# 単純に未定義変数エラーで評価が落ちるだけだった(プロンプトの約束と実装が食い違っていた)。
const LAG_VAR_PATTERN = r"\b((?:xmeas|xmv)_\d+)_lag(\d+)\b"

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

        # ラン・サンプル順に並べ替える(念のため)。simulationRun/sample列を跨いだ
        # 差分・ラグの汚染を防ぐための土台となる(下記のラン境界マスクもこの並び順を前提にする)。
        has_run_col = "simulationRun" in names(df_raw)
        has_sample_col = "sample" in names(df_raw)
        if has_run_col && has_sample_col
            sort!(df_raw, ["simulationRun", "sample"])
        end
        run_vals = has_run_col ? df_raw[!, "simulationRun"] : nothing

        # 数値列のみを抽出（正規化のため）
        numeric_cols = [n for n in names(df_raw) if eltype(df_raw[!, n]) <: Number]
        df_numeric = df_raw[:, numeric_cols]

        N = nrow(df_numeric)
        # 各行が「有効な現在状態(t)」として使えるかどうかのマスク。
        # ①ラグ列が同一ラン内で十分な履歴を持たない(=ラン先頭付近) ②直後の行が別ランに切り替わる
        # (=このtからのΔyがラン境界を跨ぐ)場合はfalseにする。
        row_valid = trues(N)
        if run_vals !== nothing
            for i in 1:(N - 1)
                if run_vals[i] != run_vals[i + 1]
                    row_valid[i] = false
                end
            end
            row_valid[N] = false
        end

        # formula文字列中の "<var>_lag<K>" トークンを検出し、ランを跨がないシフト列を動的生成する。
        for m in eachmatch(LAG_VAR_PATTERN, formula_str)
            base = m.captures[1]
            lag_n = parse(Int, m.captures[2])
            lag_col_name = "$(base)_lag$(lag_n)"
            if base in numeric_cols && !(lag_col_name in numeric_cols)
                base_vals = Float64.(df_numeric[!, base])
                lagged = zeros(Float64, N)
                for i in 1:N
                    j = i - lag_n
                    if j >= 1 && (run_vals === nothing || run_vals[i] == run_vals[j])
                        lagged[i] = base_vals[j]
                    else
                        row_valid[i] = false
                    end
                end
                df_numeric[!, lag_col_name] = lagged
                push!(numeric_cols, lag_col_name)
            end
        end

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

        # 差分予測モードの判定（デフォルト: true）
        predict_diff = get(hparams, "predict_diff", true)
        if predict_diff
            # ターゲット変数の時間差分 Δy(t) = y(t) - y(t-1)
            target_diff = target_y[2:end] .- target_y[1:end-1]

            # 説明変数として1ステップ前の状態 X(t-1) を用いる
            df_norm = df_norm[1:end-1, :]
            target_y = target_diff
            row_valid = row_valid[1:end-1]
            println(stderr, "Applying 1-step difference pre-processing (Euler discrete-time derivative: Δy(t) ≈ f(X(t-1))). Evaluation length: $(length(target_y))")
        end

        # ラグ生成/ラン境界により無効化された行をここで除外する
        # (これ以降のランダムサンプリングは有効な行だけを対象にする)。
        if !all(row_valid)
            valid_idx = findall(row_valid)
            df_norm = df_norm[valid_idx, :]
            target_y = target_y[valid_idx]
            println(stderr, "Excluded $(N - length(valid_idx)) rows invalidated by lag construction / run boundaries. Remaining: $(length(target_y))")
        end

        # 3. 数式のパース
        var_names = numeric_cols
        eval_func, num_coeffs, formula_expr = parse_formula_full(formula_str, var_names)

        # 4. 係数の最適化
        # 目的関数: 予測値と実測値のMAE(外れ値は error_cap で上限) + 複雑さペナルティ
        # (calculate_fitness, fitness.jl と共通のロジック)
        penalty_weight = 0.001 # 少し弱める
        node_count = count_nodes(formula_expr)

        # 高速化のため、最適化時はサンプリングしたデータを使用する
        total_rows = nrow(df_norm)
        # 安定した後半のデータからランダムにサンプリング
        sample_indices = rand(101:total_rows, min(500, total_rows - 100))
        df_sample = df_norm[sample_indices, :]
        target_sample = target_y[sample_indices]

        objective = (c) -> calculate_fitness(
            eval_func, c, df_sample, target_sample, formula_expr;
            penalty_weight=penalty_weight,
            on_error=(e) -> println(stderr, "Evaluation error for formula [", formula_str, "]: ", e)
        )

        # 係数について線形な数式(c[1]*term1 + c[2]*term2 + ... の形)であれば、
        # BlackBoxOptim(有界・確率的なMAE最小化。多重共線性下では収束せず符号すら
        # 不安定になりうることがXMEAS(13)の検証で判明した)よりも、
        # 唯一のグローバル最適解を持つ厳密なOLSを優先して使う。
        # 判定・フィットには探索用サンプル(500行)より大きな標本を使い、信頼性を確保する。
        linear_fit_rows = min(20000, total_rows - 100)
        linear_fit_indices = rand(101:total_rows, linear_fit_rows)
        df_linear_sample = df_norm[linear_fit_indices, :]
        target_linear_sample = target_y[linear_fit_indices]
        linear_coeffs = num_coeffs > 0 ? try_linear_ols_fit(eval_func, num_coeffs, df_linear_sample, target_linear_sample) : nothing

        if linear_coeffs !== nothing
            println(stderr, "Formula is linear in coefficients - using exact OLS fit (n=$(linear_fit_rows)) instead of BlackBoxOptim.")
            best_coeffs = linear_coeffs
            best_fitness = objective(best_coeffs)
        elseif num_coeffs > 0
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
        # 注意: "rmse" というキー名だが、実際は500行サンプルに対するMAE(外れ値キャップ付き)。
        # 呼び出し側(loop.py等)との互換性のためキー名は維持している。
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
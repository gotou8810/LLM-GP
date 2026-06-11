using JSON, DataFrames, Statistics, RData
include("src/TEPDataLoader.jl")
include("src/NumericalEvaluator/parser.jl")
include("src/NumericalEvaluator/fitness.jl")
include("src/NumericalEvaluator/optimizer.jl")

input = JSON.parse(read(stdin, String))
formula = input["formula"]
target = input["target_variable"]
path = input["dataset_path"]

df_raw = TEPDataLoader.load_rdata(path)
numeric_cols_raw = [n for n in names(df_raw) if eltype(df_raw[!, n]) <: Number]
df_eval = df_raw[:, numeric_cols_raw]
total_rows = nrow(df_eval)

for col in numeric_cols_raw
    col_data = Vector{Float64}(df_eval[!, col])
    lag5_data = Vector{Float64}(undef, total_rows)
    for i in 1:min(5, total_rows); lag5_data[i] = col_data[1]; end
    if total_rows >= 6; lag5_data[6:end] = col_data[1:end-5]; end
    df_eval[!, col * "_lag5"] = lag5_data
end

cols = names(df_eval)
eval_func, num_coeffs, ast, _ = parse_formula_full(formula, cols)

target_y = Vector{Float64}(df_eval[:, target])
sample_idx = rand(101:total_rows, 500)
df_sample = df_eval[sample_idx, :]
target_sample = target_y[sample_idx]

obj = (c) -> begin
    sum_err = 0.0
    for i in 1:nrow(df_sample)
        p = Base.invokelatest(eval_func, c, df_sample[i, :])
        sum_err += (p - target_sample[i])^2
    end
    return sqrt(sum_err / 500)
end

best_c, fitness = optimize_coefficients(obj, num_coeffs; max_steps=1000)
println("SUCCESS, Fitness: ", fitness)

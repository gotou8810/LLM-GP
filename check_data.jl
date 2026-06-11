using RData
using DataFrames
using Statistics

dataset_path = "TEP_FaultFree_Training.RData"
objs = RData.load(dataset_path)
df = first(values(objs))
if !(df isa DataFrame)
    df = DataFrame(df, :auto)
end

println("Column names: ", names(df))
println("Number of columns: ", length(names(df)))
println("Number of rows: ", nrow(df))
vars = ["xmeas_7", "xmeas_8", "xmeas_9", "xmeas_17"]
println("Variable\tMean\tStd\tMin\tMax")
for v in vars
    if v in names(df)
        col = df[!, v]
        println("$v\t$(mean(col))\t$(std(col))\t$(min(col...))\t$(max(col...))")
    else
        # Try generic names if not found
        println("$v not found")
    end
end

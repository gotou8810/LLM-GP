include("src/TEPDataLoader.jl")
using .TEPDataLoader
using Statistics
df = load_rdata("TEP_Faulty_Training.RData")
println("xmeas_7: mean=", mean(df.xmeas_7), " std=", std(df.xmeas_7))
println("xmeas_13: mean=", mean(df.xmeas_13), " std=", std(df.xmeas_13))
println("Correlation: ", cor(df.xmeas_7, df.xmeas_13))

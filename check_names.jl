using RData, DataFrames
objs = RData.load("TEP_Faulty_Training.RData")
df = first(values(objs))
println(names(df)[1:50])
println(names(df)[51:end])

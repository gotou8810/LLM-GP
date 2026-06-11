include("src/TEPDataLoader.jl")
using .TEPDataLoader
using Statistics
df = load_rdata("TEP_Faulty_Training.RData")

function get_lag(v, n)
    res = copy(v)
    res[1:n] .= v[1]
    res[n+1:end] .= v[1:end-n]
    return res
end

x7 = df.xmeas_7
x13 = df.xmeas_13

println("Cor(x13, x7): ", cor(x13, x7))
println("Cor(x13, x7_lag5): ", cor(x13, get_lag(x7, 5)))
println("Cor(x13, x7_lag10): ", cor(x13, get_lag(x7, 10)))
println("Cor(x13, x7_lag20): ", cor(x13, get_lag(x7, 20)))

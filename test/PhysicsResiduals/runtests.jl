using Test

include("../../src/PhysicsResiduals/PhysicsResiduals.jl")
using .PhysicsResiduals

@testset "PhysicsResiduals Tests" begin

    @testset "Module Load" begin
        # タスク1.1時点では骨格のみであり、コンポーネントはまだ実装されていない。
        # モジュール自体がエラーなく読み込めることだけを確認する(各コンポーネントの
        # 個別テストはタスク1.2以降で実装とともに追加する)。
        @test PhysicsResiduals isa Module
    end

end

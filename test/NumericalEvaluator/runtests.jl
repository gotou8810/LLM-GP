using Test

# モジュールの読み込み
include("../../src/NumericalEvaluator/NumericalEvaluator.jl")
using .NumericalEvaluator

@testset "NumericalEvaluator Tests" begin
    @testset "Module Load" begin
        # モジュールが正常に読み込まれ、エクスポートされた関数が存在するか確認
        @test isdefined(NumericalEvaluator, :parse_formula)
        @test isdefined(NumericalEvaluator, :calculate_fitness)
        @test isdefined(NumericalEvaluator, :optimize_coefficients)
        @test isdefined(NumericalEvaluator, :main)
    end

    @testset "CLI Entrypoint (Integration)" begin
        using JSON
        
        # プロジェクトルートにある実データへのパス
        data_path = joinpath(dirname(dirname(@__DIR__)), "TEP_FaultFree_Training.RData")
        
        if isfile(data_path)
            # 正常なJSON入力（実データを使用）
            # 式中の c[1], c[2] を最適化し、xmeas_7 を予測する
            valid_json = """
            {
              "formula": "c[1] * xmeas_1 + c[2]",
              "target_variable": "xmeas_7",
              "dataset_path": "$data_path",
              "hyperparameters": {
                "max_steps": 100,
                "search_range": [-10.0, 10.0]
              }
            }
            """
            
            in_io = IOBuffer(valid_json)
            out_io = IOBuffer()
            
            NumericalEvaluator.main(in_io, out_io)
            
            output_str = String(take!(out_io))
            output_json = JSON.parse(output_str)
            
            if output_json["status"] == "error"
                println("CLI Error Message: ", output_json["message"])
                println("CLI Error Type: ", output_json["error_type"])
            end
            
            @test output_json["status"] == "success"
            @test output_json["fitness"] > 0.0
            @test length(output_json["coefficients"]) >= 1
            @test haskey(output_json, "rmse")
            @test haskey(output_json, "penalty")
        else
            @warn "Local test data not found: $data_path. Skipping CLI Integration test."
        end

        # 不正なJSON入力 (パースエラー)
        invalid_json = "{"
        in_io_err = IOBuffer(invalid_json)
        out_io_err = IOBuffer()
        
        NumericalEvaluator.main(in_io_err, out_io_err)
        
        output_str_err = String(take!(out_io_err))
        output_json_err = JSON.parse(output_str_err)
        
        @test output_json_err["status"] == "error"
        @test output_json_err["error_type"] == "ParseError"
    end

    @testset "Parser" begin
        # 正常系: パース成功と関数の実行
        var_names = ["xmeas_1", "xmeas_2"]
        formula_str = "c[1] * xmeas_1 + c[2] * exp(xmeas_2)"
        
        func = NumericalEvaluator.parse_formula(formula_str, var_names)
        @test func isa Function
        
        # 実行テスト
        c_test = [2.0, 3.0]
        row_test = Dict("xmeas_1" => 10.0, "xmeas_2" => 0.0)
        # 期待値: 2.0 * 10.0 + 3.0 * exp(0.0) = 20.0 + 3.0 = 23.0
        @test func(c_test, row_test) ≈ 23.0

        # 異常系: サポートされていない関数や演算子が含まれる場合
        invalid_formula_1 = "system(\"rm -rf\")"
        @test_throws ErrorException NumericalEvaluator.parse_formula(invalid_formula_1, var_names)
        
        invalid_formula_2 = "c[1] * unknown_func(xmeas_1)"
        @test_throws ErrorException NumericalEvaluator.parse_formula(invalid_formula_2, var_names)
    end # end of Parser

    @testset "Fitness" begin
        using DataFrames
        
        # テスト用のダミーデータ
        df = DataFrame("X1" => [1.0, 2.0, 3.0], "X2" => [0.0, 1.0, 2.0])
        target_y = [2.0, 5.0, 8.0]
        
        ast = :(c[1] * X1 + c[2] * X2)
        func = NumericalEvaluator.parse_formula("c[1] * X1 + c[2] * X2", ["X1", "X2"])
        
        coeffs = [2.0, 1.0]
        fitness = NumericalEvaluator.calculate_fitness(func, coeffs, df, target_y, ast)
        
        @test fitness isa Float64
        @test fitness > 0.0
        
        coeffs_bad = [1.0, 0.0]
        fitness_bad = NumericalEvaluator.calculate_fitness(func, coeffs_bad, df, target_y, ast)
        @test fitness_bad > fitness
    end # end of Fitness

    @testset "Optimizer" begin
        objective_func(c) = (c[1] - 3.0)^2 + (c[2] + 2.0)^2
        
        num_coeffs = 2
        search_range = (-10.0, 10.0)
        max_steps = 2000
        
        best_coeffs, best_fitness = NumericalEvaluator.optimize_coefficients(
            objective_func, num_coeffs; 
            search_range=search_range, max_steps=max_steps
        )
        
        @test length(best_coeffs) == 2
        @test isapprox(best_coeffs[1], 3.0, atol=0.1)
        @test isapprox(best_coeffs[2], -2.0, atol=0.1)
        @test best_fitness < 0.1
    end
end

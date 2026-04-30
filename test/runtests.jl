using Test
using Downloads

# We need to include the source file since we are not fully managing this as a Pkg locally yet
include("../src/TEPDataLoader.jl")
using .TEPDataLoader

@testset "TEPDataLoader Tests" begin
    @testset "download_data" begin
        # 正常系: 有効なURLからのダウンロード
        # テスト用のファイルとして、GitHub上の適当な小さいファイルを使用
        url = "https://raw.githubusercontent.com/JuliaLang/julia/master/README.md"
        dest = tempname()
        try
            result = download_data(url, dest)
            @test result == dest
            @test isfile(dest)
            @test filesize(dest) > 0
        finally
            isfile(dest) && rm(dest)
        end

        # 異常系: 無効なURL
        invalid_url = "https://invalid.url/nonexistent_file_12345"
        dest_err = tempname()
        @test_throws RequestError download_data(invalid_url, dest_err)
        @test !isfile(dest_err)
    end

    @testset "load_rdata" begin
        using DataFrames
        using Downloads
        
        # 正常系: 有効なローカルの .RData ファイルの読み込み
        # プロジェクトルートにある TEP_FaultFree_Training.RData を使用
        valid_file = joinpath(dirname(@__DIR__), "TEP_FaultFree_Training.RData")
        if isfile(valid_file)
            df = load_rdata(valid_file)
            @test df isa DataFrame
            @test nrow(df) > 0
            @test ncol(df) > 0
            @test "faultNumber" in names(df)
        else
            @warn "Local test data not found: $valid_file. Skipping real data load test."
        end

        # 異常系: ファイルが存在しない
        @test_throws SystemError load_rdata("nonexistent.RData")

        # 異常系: 無効なファイルフォーマット
        invalid_file = tempname() * ".RData"
        write(invalid_file, "this is not an RData file")
        try
            # RData.load が何らかのエラーを投げることを期待
            @test_throws ErrorException load_rdata(invalid_file)
        finally
            rm(invalid_file)
        end
    end

    @testset "extract_variables" begin
        using DataFrames
        df = DataFrame(A = 1:3, B = ["x", "y", "z"], C = [0.1, 0.2, 0.3])
        
        # 正常系: 存在する列の抽出
        vars = ["A", "C"]
        extracted = extract_variables(df, vars)
        @test ncol(extracted) == 2
        @test names(extracted) == ["A", "C"]
        @test extracted.A == 1:3
        @test extracted.C == [0.1, 0.2, 0.3]
        
        # 正常系: 1列のみの抽出
        vars_single = ["B"]
        extracted_single = extract_variables(df, vars_single)
        @test ncol(extracted_single) == 1
        @test names(extracted_single) == ["B"]
        
        # 異常系: 存在しない列の指定
        vars_missing = ["A", "D"]
        # ErrorException が投げられ、メッセージに D が含まれていることを確認
        try
            extract_variables(df, vars_missing)
            @test false # Should not reach here
        catch e
            @test e isa ErrorException
            @test occursin("D", e.msg)
        end
        
        # 異常系: 全て存在しない列の指定
        vars_all_missing = ["X", "Y"]
        @test_throws ErrorException extract_variables(df, vars_all_missing)
    end

    @testset "Integration Test" begin
        using DataFrames
        
        # プロジェクトルートにある TEP_FaultFree_Training.RData を使用
        local_file_path = joinpath(dirname(@__DIR__), "TEP_FaultFree_Training.RData")
        
        if isfile(local_file_path)
            # 1. ロード (ダウンロード処理はスキップして直接ロード)
            df = load_rdata(local_file_path)
            @test df isa DataFrame
            @test ncol(df) == 55
            
            # 2. 変数の抽出 (実データに含まれる代表的な列)
            target_vars = ["faultNumber", "simulationRun", "sample", "xmeas_1", "xmeas_41"]
            final_df = extract_variables(df, target_vars)
            
            @test final_df isa DataFrame
            @test ncol(final_df) == 5
            @test names(final_df) == target_vars
            @test nrow(final_df) == nrow(df)
        else
            @warn "Local test data not found: $local_file_path. Skipping Integration Test."
        end
    end
end

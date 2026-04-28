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
        
        # 正常系: 有効な .RData (.rda) ファイルの読み込み
        valid_rda_url = "https://raw.githubusercontent.com/JuliaData/RData.jl/main/test/data_v3/dfattributes.rda"
        valid_file = tempname() * ".rda"
        try
            Downloads.download(valid_rda_url, valid_file)
            df = load_rdata(valid_file)
            @test df isa DataFrame
            @test nrow(df) > 0
            @test ncol(df) > 0
        finally
            isfile(valid_file) && rm(valid_file)
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
end

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
end

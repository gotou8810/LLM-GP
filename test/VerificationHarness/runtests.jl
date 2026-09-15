using Test

include("../../src/VerificationHarness.jl")
using .VerificationHarness

@testset "VerificationHarness Tests" begin

    @testset "Module Load" begin
        @test isdefined(VerificationHarness, :FeatureSpec)
        @test isdefined(VerificationHarness, :run_full_verification)
    end

    @testset "自己回帰項ガード" begin
        # 特徴量にターゲット自身が含まれる場合はエラーで停止すること
        # (CLAUDE.mdが禁止する自己回帰項の、ハーネス側での機械的ガード)
        features_with_self_ref = [VerificationHarness.FeatureSpec(:xmeas_7, 0)]
        @test_throws ErrorException VerificationHarness.assert_no_self_reference(:xmeas_7, features_with_self_ref)

        # ターゲットが含まれていなければエラーにならないこと
        features_ok = [VerificationHarness.FeatureSpec(:xmeas_10, 1)]
        @test VerificationHarness.assert_no_self_reference(:xmeas_7, features_ok) === nothing
    end

    @testset "Integration: XMEAS(7)で既知の結果を再現する" begin
        healthy_path = joinpath(dirname(dirname(@__DIR__)), "TEP_FaultFree_Training.RData")
        faulty_path = joinpath(dirname(dirname(@__DIR__)), "TEP_Faulty_Training.RData")

        if isfile(healthy_path) && isfile(faulty_path)
            result = run_full_verification(
                target = :xmeas_7,
                features = [FeatureSpec(:xmeas_10, 1)],
                label = "test",
                healthy_path = healthy_path,
                faulty_path = faulty_path
            )

            # verify_xmeas7_no_ar.jl(個別スクリプト)で得た既知の結果と一致することを確認
            # (許容誤差付き。係数は完全一致するはず=同じOLS計算のため)
            @test isapprox(result["coefficients"][1], 21.99712, atol=0.01)
            @test isapprox(result["coefficients"][2], -7.41260, atol=0.01)
            @test isapprox(result["skill_fit"], 0.0105, atol=0.001)
            @test isapprox(result["skill_holdout"], 0.0111, atol=0.001)
            @test isapprox(result["f1"], 0.5234, atol=0.001)
            @test result["far_run_pct"] == 0.0

            # アブレーション: 唯一の特徴量(xmeas_10)を除去すると、Skillはほぼゼロになるはず
            # (残るのは切片のみ=素朴予想と実質同じ)
            ablation_result = result["ablation"]["除去:xmeas_10"]
            @test isapprox(ablation_result["skill_fit"], 0.0, atol=0.001)
        else
            @warn "Local test data not found. Skipping VerificationHarness integration test."
        end
    end

end

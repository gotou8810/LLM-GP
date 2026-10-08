using Test
using DataFrames

include("../../src/PhysicsResiduals/PhysicsResiduals.jl")
using .PhysicsResiduals

# verify_injection_timingの実データテスト用。TEPDataLoader.load_rdataは
# PhysicsResiduals内部でも使われているが(FaultTimingのTEPDataLoader依存、design.md参照)、
# テスト側では実データをPhysicsResiduals.verify_injection_timingの
# df_normal/df_faulty引数として直接渡すために、独立にincludeして使う
# (test/VerificationHarness/runtests.jlと同じ「実データが無ければスキップ」規約)。
include("../../src/TEPDataLoader.jl")
using .TEPDataLoader: load_rdata

@testset "PhysicsResiduals Tests" begin

    @testset "Module Load" begin
        # タスク1.1時点では骨格のみであり、コンポーネントはまだ実装されていない。
        # モジュール自体がエラーなく読み込めることだけを確認する(各コンポーネントの
        # 個別テストはタスク1.2以降で実装とともに追加する)。
        @test PhysicsResiduals isa Module
    end

    @testset "FAULT_INJECTION_SAMPLE" begin
        # Rieth et al. 2017データセットの投入サンプルは21で固定(docs/dataset_spec.md参照)
        @test PhysicsResiduals.FAULT_INJECTION_SAMPLE == 21
    end

    @testset "respects_run_boundary" begin
        # 2ランの合成データ(各ランでsample列の順序を意図的に乱してある)に対し、
        # [run_col, :sample]でソートされたDataFrameが返ることを確認する。
        # これにより、呼び出し側がgroupby(sorted, run_col)で安全にラン単位の
        # 時系列処理(diff等)を行える(design.md「データ正確性」FaultTiming参照)。
        df_synth = DataFrame(
            simulationRun = [1, 1, 1, 2, 2, 2],
            sample = [3, 1, 2, 2, 3, 1],
            xmeas_9 = [10.0, 11.0, 12.0, 100.0, 101.0, 99.0]
        )

        sorted_df = PhysicsResiduals.respects_run_boundary(df_synth, :simulationRun)

        @test sorted_df.simulationRun == [1, 1, 1, 2, 2, 2]
        @test sorted_df.sample == [1, 2, 3, 1, 2, 3]

        # ラン境界をまたいだ値が生成されないことの確認:
        # ラン1はsample順で11.0→12.0→10.0、ラン2はsample順で99.0→100.0→101.0であり、
        # ラン1の末尾(10.0)とラン2の先頭(99.0)が連続値として混ざっていないこと
        grouped = groupby(sorted_df, :simulationRun)
        run1 = grouped[(simulationRun = 1,)]
        run2 = grouped[(simulationRun = 2,)]
        @test run1.xmeas_9 == [11.0, 12.0, 10.0]
        @test run2.xmeas_9 == [99.0, 100.0, 101.0]

        # デフォルト引数(run_col=:simulationRun)でも同じ結果になること
        @test PhysicsResiduals.respects_run_boundary(df_synth) == sorted_df

        # 必須列が欠けている場合はサイレントなNaN伝播ではなく明示的エラーで停止する
        df_missing_col = DataFrame(sample = [1, 2])
        @test_throws ErrorException PhysicsResiduals.respects_run_boundary(df_missing_col, :simulationRun)
    end

    @testset "verify_injection_timing (合成データ)" begin
        # 正常データ: samples 1:3、全runでxmv_10はrunに応じた小さなジッター
        # (-0.1, 0.0, 0.1をrun番号でサイクル)を持つが、サンプルには依存しない。
        # これにより正常データの各サンプルindexでの標準偏差が常に非ゼロになる。
        runs_col = repeat(1:10, inner = 3)
        samples_col = repeat(1:3, outer = 10)
        jitter(run) = 0.1 * ((run % 3) - 1)

        df_normal_synth = DataFrame(
            simulationRun = runs_col,
            sample = samples_col,
            xmv_10 = Float64[50.0 + jitter(run) for run in runs_col]
        )

        # 故障データ: IDV99は、ここではpre_injection_max_sample=2でテストする想定で、
        # sample=1,2では正常と変わらず、sample=3で初めて巨大な逸脱(90.0)が生じる合成シナリオ
        df_faulty_synth = DataFrame(
            simulationRun = runs_col,
            sample = samples_col,
            faultNumber = fill(99, 30),
            xmv_10 = Float64[s <= 2 ? 50.0 + jitter(run) : 90.0 for (run, s) in zip(runs_col, samples_col)]
        )

        # pre_injection_max_sample=2なので、sample<=2のみが検査対象。
        # そこでは正常データと故障データが一致するためtrueが返るはず。
        @test PhysicsResiduals.verify_injection_timing(
            df_faulty_synth, [99];
            pre_injection_max_sample = 2, significance_z = 3.0,
            check_col = :xmv_10, df_normal = df_normal_synth
        ) == true

        # pre_injection_max_sample=3まで広げると、sample=3の巨大な逸脱(90.0 vs 50.0)を
        # 検査対象に含めることになるため、falseが返るはず
        @test PhysicsResiduals.verify_injection_timing(
            df_faulty_synth, [99];
            pre_injection_max_sample = 3, significance_z = 3.0,
            check_col = :xmv_10, df_normal = df_normal_synth
        ) == false
    end

    @testset "verify_injection_timing (実データ: IDV4/11/14)" begin
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")
        faulty_path = joinpath(project_root, "TEP_Faulty_Training.RData")

        if isfile(healthy_path) && isfile(faulty_path)
            df_normal = load_rdata(healthy_path)
            df_faulty = load_rdata(faulty_path)

            # タスク1.2の完了確認: 対象3 IDV(4, 11, 14)について、
            # サンプル20以前(FAULT_INJECTION_SAMPLE=21より前)に
            # 正常データの分布からの有意な逸脱がないことを統計的に確認する
            @test PhysicsResiduals.verify_injection_timing(
                df_faulty, [4, 11, 14];
                df_normal = df_normal
            ) == true
        else
            @warn "Local test data not found. Skipping verify_injection_timing real-data test."
        end
    end

end

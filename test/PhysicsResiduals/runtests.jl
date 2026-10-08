using Test
using DataFrames
using Random

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

    # ========================================================================
    # タスク1.3: 残差式とlambda制約の定義(ResidualFormula)
    # Requirements: 1.1, 1.2, 1.5, 1.6
    # ========================================================================

    @testset "LAMBDA_SIGN_CONSTRAINTS" begin
        # Requirement 1.2: 同定(タスク2.1)より前に、各未知パラメータの期待符号を
        # 宣言しておく。design.md ResidualFormula State Managementの
        # リテラル定義(a=(:positive, 0.0), b=(:negative, 0.0))と一致することを確認する。
        # (a>0はk>0, UA>0より。b<0はa>0, T_cw,in>0より; brief.md「符号・値域の事前制約」参照)
        @test PhysicsResiduals.LAMBDA_SIGN_CONSTRAINTS.a == (:positive, 0.0)
        @test PhysicsResiduals.LAMBDA_SIGN_CONSTRAINTS.b == (:negative, 0.0)
    end

    @testset "build_design_matrix (合成データ)" begin
        # Requirement 1.1: y=Tr-Tcw_out, x1=u10*Tcw_out, x2=u10 が正しく構築されることを
        # 既知の合成データで確認する。
        df_synth = DataFrame(
            xmeas_9 = [120.0, 121.0, 122.5],
            xmeas_21 = [94.0, 94.5, 95.0],
            xmv_10 = [40.0, 41.0, 42.0]
        )
        feats = PhysicsResiduals.build_design_matrix(df_synth)

        @test feats isa PhysicsResiduals.ResidualFeatures
        @test feats.y ≈ [120.0 - 94.0, 121.0 - 94.5, 122.5 - 95.0]
        @test feats.x1 ≈ [40.0 * 94.0, 41.0 * 94.5, 42.0 * 95.0]
        @test feats.x2 ≈ [40.0, 41.0, 42.0]
        @test length(feats.y) == length(feats.x1) == length(feats.x2) == 3

        # 列名をキーワード引数で明示的に指定しても同じ結果になること(design.mdの既定引数)
        df_renamed = DataFrame(tr = df_synth.xmeas_9, tcwout = df_synth.xmeas_21, u10 = df_synth.xmv_10)
        feats2 = PhysicsResiduals.build_design_matrix(df_renamed; tr_col = :tr, tcw_out_col = :tcwout, u10_col = :u10)
        @test feats2.y ≈ feats.y
        @test feats2.x1 ≈ feats.x1
        @test feats2.x2 ≈ feats.x2

        # 列が欠けている場合はサイレントなNaN伝播ではなく明示的エラーで停止する
        # (design.md Implementation Notes「Validation」参照)
        df_missing = DataFrame(xmeas_9 = [1.0], xmeas_21 = [2.0])
        @test_throws ErrorException PhysicsResiduals.build_design_matrix(df_missing)
    end

    @testset "build_design_matrix (実データ: タスク1.3完了確認)" begin
        # タスク1.3の完了確認: 実データに対しbuild_design_matrixを呼ぶと、
        # 同じ長さの3ベクトル(y, x1, x2)が返る。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")

        if isfile(healthy_path)
            df_normal = load_rdata(healthy_path)
            feats = PhysicsResiduals.build_design_matrix(df_normal)

            @test feats isa PhysicsResiduals.ResidualFeatures
            @test length(feats.y) == length(feats.x1) == length(feats.x2)
            @test length(feats.y) == nrow(df_normal)
            @test all(isfinite, feats.y)
            @test all(isfinite, feats.x1)
            @test all(isfinite, feats.x2)
        else
            @warn "Local test data not found. Skipping build_design_matrix real-data test."
        end
    end

    @testset "assess_quasi_steady_adequacy" begin
        # Requirement 1.5: 準定常(代数式)仮定が正常データの残差挙動を十分に説明できるか
        # を判定する。本実装はラグ1自己相関検定を用いる(コード内コメント参照)。
        # 「十分」と「不十分」の両方を正しく判別できることを示す(どちらでも同じ値を
        # 返すような自明な実装ではないことを証明する)。
        rng = MersenneTwister(2024)

        # 十分なケース: 自己相関のないi.i.d.ノイズ -> true(準定常で十分)
        n = 2000
        adequate_resid = randn(rng, n) .* 0.01
        @test PhysicsResiduals.assess_quasi_steady_adequacy(adequate_resid) == true

        # 不十分なケース: dTcw_out/dtに相当する緩やかな系統的変動(強い自己相関)を
        # 持つ残差 -> false(動的項の追加が必要)
        t = collect(1:n)
        inadequate_resid = 0.05 .* sin.(t ./ 15.0) .+ randn(rng, n) .* 0.001
        @test PhysicsResiduals.assess_quasi_steady_adequacy(inadequate_resid) == false

        # 残差系列が短すぎる場合は明示的エラー
        @test_throws ErrorException PhysicsResiduals.assess_quasi_steady_adequacy(Float64[0.1, 0.2])
    end

    @testset "build_design_matrix_with_dynamic_term (Requirement 1.5の動的項追加ロジック)" begin
        # assess_quasi_steady_adequacyがfalse(不十分)と判定した場合に追加する
        # Tcw_outの時間変化率項(x3)を構築するロジック。ラン境界をまたいで差分を
        # 取らないこと(各ランの先頭サンプルは後方差分が取れないため除外される)を確認する。
        df_synth = DataFrame(
            simulationRun = [1, 1, 1, 2, 2, 2],
            sample = [1, 2, 3, 1, 2, 3],
            xmeas_9 = [120.0, 121.0, 122.0, 130.0, 131.0, 133.0],
            xmeas_21 = [94.0, 94.5, 95.5, 90.0, 90.5, 91.0],
            xmv_10 = [40.0, 41.0, 42.0, 50.0, 51.0, 52.0]
        )

        feats = PhysicsResiduals.build_design_matrix_with_dynamic_term(df_synth)

        @test feats isa PhysicsResiduals.ResidualFeaturesDynamic
        @test length(feats.y) == length(feats.x1) == length(feats.x2) == length(feats.x3)
        # 各ラン3サンプルから先頭1サンプルが除外されるため、2ラン×2サンプル=4行
        @test length(feats.y) == 4

        # ラン1の2番目のサンプル(sample=2)のx3 = (94.5-94.0)/3.0
        @test feats.x3[1] ≈ (94.5 - 94.0) / 3.0
        # ラン1の3番目のサンプル(sample=3)のx3 = (95.5-94.5)/3.0
        @test feats.x3[2] ≈ (95.5 - 94.5) / 3.0
        # ラン2の先頭から計算されたx3がラン1の末尾からの差分と混ざっていないこと
        @test feats.x3[3] ≈ (90.5 - 90.0) / 3.0
        @test feats.x3[4] ≈ (91.0 - 90.5) / 3.0

        # 列が欠けている場合は明示的エラー
        df_missing = DataFrame(simulationRun = [1], sample = [1], xmeas_9 = [1.0])
        @test_throws ErrorException PhysicsResiduals.build_design_matrix_with_dynamic_term(df_missing)
    end

    @testset "k/UA 非同定可能性の明記 (Requirement 1.6)" begin
        # kとUAが個別には同定不可能で、比a=k/UAのみが同定可能であることが
        # レポート出力に使えるドキュメント文字列として明記されていることを確認する。
        note = PhysicsResiduals.LAMBDA_NON_IDENTIFIABILITY_NOTE
        @test occursin("k", note)
        @test occursin("UA", note)
        @test occursin("k/UA", note)
        @test occursin("T_cw,in", note) || occursin("Tcw_in", note) || occursin("Tcw,in", note)
    end

end

using Test
using DataFrames
using Random
using Statistics

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

    # ========================================================================
    # タスク2.1: 正常データの分割とlambda同定(LambdaIdentifier)
    # Requirements: 2.1, 2.2, 2.3, 1.3, 1.4
    # ========================================================================

    @testset "split_normal_data (実データ: 非重複・run境界の正しさ)" begin
        # Requirement 2.2: fit/holdoutの2部分集合が重複なく分割されることを、
        # 実データ(simulationRun=1..500)で確認する(design.md LambdaIdentifier
        # Service Interfaceのリテラルシグネチャ: fit_run_max既定400, run_col既定:simulationRun)。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")

        if isfile(healthy_path)
            df_normal = load_rdata(healthy_path)

            df_fit_wrapped, df_holdout = PhysicsResiduals.split_normal_data(df_normal)

            # 型安全性要件(タスク2.1本文): identify_lambdaに渡せる側はNormalFitSplitで
            # ラップされている。holdout側はLambdaValidator(タスク3.1以降)がそのまま
            # DataFrameとして使う想定のためラップしない(design.mdのLambdaValidator
            # Service Interface df_holdout::DataFrameと整合)。
            @test df_fit_wrapped isa PhysicsResiduals.NormalFitSplit
            @test df_holdout isa DataFrames.DataFrame

            df_fit = df_fit_wrapped.df

            # 既定fit_run_max=400: fit側はすべてrun<=400、holdout側はすべてrun>400
            @test all(df_fit.simulationRun .<= 400)
            @test all(df_holdout.simulationRun .> 400)

            # 非重複性(Requirement 2.2): 両部分集合のrun集合に共通部分がない
            fit_runs = Set(df_fit.simulationRun)
            holdout_runs = Set(df_holdout.simulationRun)
            @test isempty(intersect(fit_runs, holdout_runs))

            # 行の欠落・重複がないこと(2分割が全体を汲み尽くす)
            @test nrow(df_fit) + nrow(df_holdout) == nrow(df_normal)

            # カスタムfit_run_maxでも正しく分割されること
            df_fit_200_wrapped, df_holdout_200 = PhysicsResiduals.split_normal_data(df_normal; fit_run_max = 200)
            @test all(df_fit_200_wrapped.df.simulationRun .<= 200)
            @test all(df_holdout_200.simulationRun .> 200)
            @test nrow(df_fit_200_wrapped.df) + nrow(df_holdout_200) == nrow(df_normal)

            # 必須列が欠けている場合は明示的エラー
            df_missing = DataFrame(sample = [1, 2])
            @test_throws ErrorException PhysicsResiduals.split_normal_data(df_missing)
        else
            @warn "Local test data not found. Skipping split_normal_data real-data test."
        end
    end

    @testset "identify_lambda (合成データ: タスク2.1完了確認、既知a,bの復元)" begin
        # タスク2.1の完了確認: 既知のa,bから生成した合成データに対しidentify_lambdaを
        # 実行すると、数値許容誤差内で元のa,bが復元される。
        #
        # y = a*x1 + b*x2 (x1=u10*Tcw_out, x2=u10) という線形関係を、
        # xmeas_9 = Tr = Tcw_out + a*x1 + b*x2 として構築することで、
        # build_design_matrixが計算するy=Tr-Tcw_outが厳密にa*x1+b*x2に一致するようにする。
        rng = MersenneTwister(777)
        n = 80
        a_true = 2.0
        t_cw_in_true = 30.0           # Tcw_outの正常平均(94.6)より十分低く、妥当範囲[0,60]内
        b_true = -a_true * t_cw_in_true  # = -60.0

        tcw_out = 90.0 .+ 10.0 .* rand(rng, n)      # [90, 100]
        u10 = 30.0 .+ 20.0 .* rand(rng, n)          # [30, 50]
        x1 = u10 .* tcw_out
        x2 = u10
        tr = tcw_out .+ a_true .* x1 .+ b_true .* x2  # 雑音なし(厳密OLSの復元能力を直接検証)

        df_synth = DataFrame(xmeas_9 = tr, xmeas_21 = tcw_out, xmv_10 = u10)
        wrapped = PhysicsResiduals.NormalFitSplit(df_synth)

        lam = PhysicsResiduals.identify_lambda(wrapped)

        @test lam isa PhysicsResiduals.ReactorCwLambda
        @test isapprox(lam.a, a_true; atol = 1e-6, rtol = 1e-6)
        @test isapprox(lam.b, b_true; atol = 1e-6, rtol = 1e-6)
        @test isapprox(lam.t_cw_in, t_cw_in_true; atol = 1e-4, rtol = 1e-4)

        # 小さなガウス雑音を加えた場合でも、十分なサンプル数(n=80)があれば
        # 元のa,bに近い値が復元されること(厳密ゼロ誤差は要求しない)
        tr_noisy = tr .+ randn(rng, n) .* 1e-3
        df_noisy = DataFrame(xmeas_9 = tr_noisy, xmeas_21 = tcw_out, xmv_10 = u10)
        lam_noisy = PhysicsResiduals.identify_lambda(PhysicsResiduals.NormalFitSplit(df_noisy))
        @test isapprox(lam_noisy.a, a_true; atol = 1e-2, rtol = 1e-2)
        @test isapprox(lam_noisy.b, b_true; atol = 1.0, rtol = 1e-2)
    end

    @testset "identify_lambda 型安全性(異常データを受け取れない型シグネチャ)" begin
        # タスク2.1本文: 「入力の型シグネチャが異常データを受け取れないようにする」。
        #
        # Juliaの型システムは値の出自(このDataFrameが本当に正常運転データか)を
        # 追跡できないため、本実装はidentify_lambdaの引数型をNormalFitSplit
        # (split_normal_dataだけが正規に生成する不透明ラッパー)に限定することで、
        # 「split_normal_dataを経由しない生DataFrame(異常データをload_rdataで
        # 直接読み込んだものを含む)はidentify_lambdaに渡せない」ことを、
        # 呼び出し側のメソッド解決(ディスパッチ)の段階でMethodErrorとして強制する。
        #
        # これはdesign.mdのリテラルシグネチャ`identify_lambda(df_fit::DataFrame)`を
        # 拡張したものである(タスク1.2/1.3で認められた、design.mdの記述意図
        # 「関数シグネチャレベルで異常データ型を受け取らないことで保証する」を
        # 実現するための開示済みの拡張。CONCERNとして状況報告で明記する)。
        df_plain = DataFrame(
            xmeas_9 = [120.0, 121.0, 122.0],
            xmeas_21 = [94.0, 94.5, 95.0],
            xmv_10 = [40.0, 41.0, 42.0]
        )

        # 生DataFrame(異常データを直接load_rdataしたものを模擬)はidentify_lambdaの
        # メソッドシグネチャに一致するメソッドが存在しないため、MethodErrorになる。
        @test_throws MethodError PhysicsResiduals.identify_lambda(df_plain)

        # split_normal_dataが返すNormalFitSplitでラップされたデータは受理される
        # (正常経路であることの確認、上のテストと対になる陽性ケース)
        wrapped = PhysicsResiduals.NormalFitSplit(df_plain)
        lam = PhysicsResiduals.identify_lambda(wrapped)
        @test lam isa PhysicsResiduals.ReactorCwLambda
    end

    @testset "check_physical_plausibility (符号制約・物理的妥当性)" begin
        # Requirement 1.3: 符号が事前宣言(a>0, b<0)と一致しない場合は無効フラグ。
        # Requirement 1.4: 導出T_cw,inがT_cw,out以上、または妥当範囲外なら物理的不整合フラグ。

        # 妥当なケース: a>0, b<0, Tcw_in=30.0 < Tcw_out平均94.6, 妥当範囲[0,60]内
        lam_ok = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        result_ok = PhysicsResiduals.check_physical_plausibility(lam_ok; tcw_out_mean = 94.6)
        @test result_ok.valid == true
        @test result_ok.invalid_reason === nothing
        # a, b, t_cw_inの値そのものは変更されない
        @test result_ok.a == lam_ok.a
        @test result_ok.b == lam_ok.b
        @test result_ok.t_cw_in == lam_ok.t_cw_in

        # 不正ケース1: 符号不一致(aが負、本来は正が期待される)
        lam_wrong_sign = PhysicsResiduals.ReactorCwLambda(-2.0, -60.0, -30.0, true, nothing)
        result_wrong_sign = PhysicsResiduals.check_physical_plausibility(lam_wrong_sign; tcw_out_mean = 94.6)
        @test result_wrong_sign.valid == false
        @test result_wrong_sign.invalid_reason !== nothing
        @test occursin("符号", result_wrong_sign.invalid_reason)

        # 不正ケース2: Tcw_in(=100.0)がTcw_out平均(94.6)以上 -> 物理的不整合
        lam_too_hot = PhysicsResiduals.ReactorCwLambda(2.0, -200.0, 100.0, true, nothing)
        result_too_hot = PhysicsResiduals.check_physical_plausibility(lam_too_hot; tcw_out_mean = 94.6)
        @test result_too_hot.valid == false
        @test result_too_hot.invalid_reason !== nothing
        @test occursin("物理的不整合", result_too_hot.invalid_reason)

        # 不正ケース3: 符号は正しい(a>0, b<0)が、Tcw_in(=85.0)が妥当範囲[0,60]の外
        # (Tcw_out平均94.6未満ではあるが、工業用冷却水として非現実的に高い) -> 物理的不整合。
        # 注意: 符号制約下ではt_cw_in=-b/a>0が自動的に成り立つため、「符号は正しいが
        # t_cw_inが負」という組み合わせは数学的に矛盾する。妥当範囲の上限超過で
        # このケースを構成する。
        t_cw_in_too_high = 85.0
        a_case3 = 2.0
        b_case3 = -a_case3 * t_cw_in_too_high  # = -170.0 (符号は正しくb<0)
        lam_out_of_range = PhysicsResiduals.ReactorCwLambda(a_case3, b_case3, t_cw_in_too_high, true, nothing)
        result_out_of_range = PhysicsResiduals.check_physical_plausibility(lam_out_of_range; tcw_out_mean = 94.6)
        @test result_out_of_range.valid == false
        @test result_out_of_range.invalid_reason !== nothing
        @test occursin("物理的不整合", result_out_of_range.invalid_reason)
    end

    @testset "ReactorCwLambdaはイミュータブル" begin
        # design.md Logical Data Model: ReactorCwLambda等はすべてイミュータブルな
        # 値型(Julia struct)として定義する(Requirement 6.3の型レベル保証の前提)。
        lam = PhysicsResiduals.ReactorCwLambda(1.0, -1.0, 1.0, true, nothing)
        @test_throws ErrorException (lam.a = 99.0)
        @test isimmutable(lam)
    end

    @testset "identify_lambda (実データ: パイプライン統合・既知の多重共線性所見)" begin
        # identify_lambda -> check_physical_plausibilityのパイプラインが実データ
        # (fit部分集合、全500runのうちrun<=400、n=200,000行)でエラーなく動作し、
        # 整合した型付き結果を返すことを確認する。
        #
        # 既知の所見(本テスト実行時に確認、CLAUDE.md §8の学術的誠実さに従い正直に記録する):
        # 閉ループ制御下では、x1=u10*Tcw_out と x2=u10 の相関がcor=0.995に達する
        # 強い多重共線性が生じる(Tcw_out=XMEAS(21)の標準偏差がわずか0.131であり、
        # 平均94.6に対してほぼ一定であるため、x1はx2のほぼ定数倍になる)。これにより
        # 全fitデータ(n=200,000)に対する厳密OLSは、符号が事前宣言(a>0, b<0)と
        # 一致しない不安定な解(a,bの符号が反転)を返すことがある。
        #
        # これはidentify_lambda/check_physical_plausibility自体の実装の誤りではなく、
        # 実データの統計的性質(閉ループ制御による説明変数の低分散・高相関)が引き起こす
        # 既知のリスクである。design.mdはこの種の不安定性をまさにLambdaValidator
        # (タスク3.1以降、ブートストラップ不確かさ・holdout安定性チェック)の責務として
        # 分離しており、本タスク(2.1)のcheck_physical_plausibilityは「符号・物理的
        # 妥当性を正しく検証して報告する」ことが責務であって「常にvalid=trueを返す」
        # ことではない。したがって本テストは、結果の妥当性を一方的に仮定せず、
        # valid/invalidのいずれであっても内部整合性(invalid時は理由が伴うこと、
        # valid時は符号・範囲制約を実際に満たすこと)を検証する。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")

        if isfile(healthy_path)
            df_normal = load_rdata(healthy_path)
            df_fit_wrapped, _df_holdout = PhysicsResiduals.split_normal_data(df_normal)

            lam_raw = PhysicsResiduals.identify_lambda(df_fit_wrapped)
            @test lam_raw isa PhysicsResiduals.ReactorCwLambda
            @test isfinite(lam_raw.a)
            @test isfinite(lam_raw.b)
            @test isfinite(lam_raw.t_cw_in)
            @test isapprox(lam_raw.t_cw_in, -lam_raw.b / lam_raw.a; rtol = 1e-9)

            tcw_out_mean = mean(df_fit_wrapped.df.xmeas_21)
            lam = PhysicsResiduals.check_physical_plausibility(lam_raw; tcw_out_mean = tcw_out_mean)

            @test lam isa PhysicsResiduals.ReactorCwLambda
            if lam.valid
                @test lam.invalid_reason === nothing
                @test lam.a > 0.0
                @test lam.b < 0.0
                @test lam.t_cw_in < tcw_out_mean
                @test PhysicsResiduals.PLAUSIBLE_TCW_IN_RANGE[1] <= lam.t_cw_in <= PhysicsResiduals.PLAUSIBLE_TCW_IN_RANGE[2]
            else
                @test lam.invalid_reason isa String
                @test !isempty(lam.invalid_reason)
            end
        else
            @warn "Local test data not found. Skipping identify_lambda real-data test."
        end
    end

    # ========================================================================
    # タスク2.2: λの不確かさとホールドアウト安定性の検証(LambdaValidator)
    # Requirements: 3.1, 3.2, 3.3
    # ========================================================================

    """
        _make_synth_run_df(rng, n_runs, rows_per_run, noise_std; a_true, t_cw_in_true)

    タスク2.2のテスト用ヘルパー: 既知のa, t_cw_inから、複数run・各runが
    simulationRun列で区別される合成正常データを生成する(タスク2.1の
    identify_lambdaテストと同じ y = Tcw_out + a*x1 + b*x2 の構成法を、
    run単位ブートストラップが扱える複数run構造に拡張したもの)。
    """
    function _make_synth_run_df(rng, n_runs::Int, rows_per_run::Int, noise_std::Float64;
                                 a_true::Float64 = 2.0, t_cw_in_true::Float64 = 30.0)
        b_true = -a_true * t_cw_in_true
        sim_run = Int[]
        xmeas_9 = Float64[]
        xmeas_21 = Float64[]
        xmv_10 = Float64[]
        for run in 1:n_runs
            tcw_out = 90.0 .+ 10.0 .* rand(rng, rows_per_run)
            u10 = 30.0 .+ 20.0 .* rand(rng, rows_per_run)
            x1 = u10 .* tcw_out
            x2 = u10
            tr = tcw_out .+ a_true .* x1 .+ b_true .* x2 .+ randn(rng, rows_per_run) .* noise_std
            append!(sim_run, fill(run, rows_per_run))
            append!(xmeas_9, tr)
            append!(xmeas_21, tcw_out)
            append!(xmv_10, u10)
        end
        return DataFrame(simulationRun = sim_run, xmeas_9 = xmeas_9, xmeas_21 = xmeas_21, xmv_10 = xmv_10)
    end

    @testset "_resample_runs_with_replacement (run単位ブロックブートストラップ、行単位ではないことの確認)" begin
        # Requirement 3.1の実装制約(design.md LambdaValidator「Responsibilities & Constraints」:
        # リサンプリングはラン単位で行い、ラン内の時系列相関を壊さない)を直接検証する。
        #
        # 各runに一意な「指紋」(連番marker)を持たせ、リサンプリング後も:
        #   (1) 各ブロックが必ずrun_len行ちょうどである(runの一部だけが抜き出されない)
        #   (2) 各ブロック内のsimulationRunが単一の値である(異なるrunの行が混ざらない)
        #   (3) 各ブロックのmarker列が、いずれかの元runの完全な順序付き数列と一致する
        #       (run内の行順序が保たれている。行単位シャッフルならこの一致は成立しない)
        # ことを確認する。
        run_len = 4
        n_runs = 5
        df_synth = DataFrame(
            simulationRun = repeat(1:n_runs, inner = run_len),
            marker = vcat([collect((r * 100 + 1):(r * 100 + run_len)) for r in 1:n_runs]...)
        )

        rng = MersenneTwister(42)
        resampled = PhysicsResiduals._resample_runs_with_replacement(df_synth, :simulationRun; rng = rng)

        @test nrow(resampled) == nrow(df_synth)
        @test nrow(resampled) % run_len == 0

        original_patterns = Set(Tuple(collect((r * 100 + 1):(r * 100 + run_len))) for r in 1:n_runs)
        n_chunks = nrow(resampled) ÷ run_len
        for c in 1:n_chunks
            chunk = resampled[((c - 1) * run_len + 1):(c * run_len), :]
            @test length(unique(chunk.simulationRun)) == 1
            @test Tuple(chunk.marker) in original_patterns
        end

        # 複数シードにわたって、runの採択パターン(出現順序の並び)が変化すること
        # (= 復元抽出であることの確認。row単位の固定シャッフルのような決定論的挙動ではない)
        distinct_patterns = Set{Vector{Int}}()
        for seed in 1:30
            r = MersenneTwister(seed)
            trial = PhysicsResiduals._resample_runs_with_replacement(df_synth, :simulationRun; rng = r)
            ids_in_order = Int[trial.simulationRun[(c - 1) * run_len + 1] for c in 1:(nrow(trial) ÷ run_len)]
            push!(distinct_patterns, ids_in_order)
        end
        @test length(distinct_patterns) > 1

        # 必須列が欠けている場合は明示的エラー
        df_missing = DataFrame(marker = [1, 2])
        @test_throws ErrorException PhysicsResiduals._resample_runs_with_replacement(df_missing, :simulationRun)
    end

    @testset "bootstrap_lambda_uncertainty (合成データ: CI幅がノイズ水準に応じて変化することの証明)" begin
        # design.md LambdaValidator Service Interface: bootstrap_lambda_uncertainty(df_fit; n_resamples, confidence)
        # は単純な固定幅のプレースホルダーではなく、実際のデータのばらつきに応じてCIが
        # 狭く/広くなることを示す(低ノイズ -> 狭いCI、高ノイズ -> 広いCIを同じrng系列で比較)。
        rng_low = MersenneTwister(11)
        df_low_noise = _make_synth_run_df(rng_low, 30, 20, 0.01)
        rng_high = MersenneTwister(11)
        df_high_noise = _make_synth_run_df(rng_high, 30, 20, 5.0)

        split_low = PhysicsResiduals.NormalFitSplit(df_low_noise)
        split_high = PhysicsResiduals.NormalFitSplit(df_high_noise)

        unc_low = PhysicsResiduals.bootstrap_lambda_uncertainty(split_low; n_resamples = 150, rng = MersenneTwister(1))
        unc_high = PhysicsResiduals.bootstrap_lambda_uncertainty(split_high; n_resamples = 150, rng = MersenneTwister(1))

        @test unc_low isa PhysicsResiduals.LambdaUncertainty
        @test unc_high isa PhysicsResiduals.LambdaUncertainty

        width(ci) = ci[2] - ci[1]
        @test width(unc_low.a_ci) < width(unc_high.a_ci)
        @test width(unc_low.t_cw_in_ci) < width(unc_high.t_cw_in_ci)

        # CIの下端<=上端(整合性)
        for unc in (unc_low, unc_high)
            @test unc.a_ci[1] <= unc.a_ci[2]
            @test unc.b_ci[1] <= unc.b_ci[2]
            @test unc.t_cw_in_ci[1] <= unc.t_cw_in_ci[2]
        end
    end

    @testset "bootstrap_lambda_uncertainty (実データ: タスク2.2完了確認)" begin
        # タスク2.2の完了確認: 実際の正常データにbootstrap_lambda_uncertaintyを実行すると、
        # a, b, T_cw,inそれぞれの信頼区間が返る。
        #
        # ランタイム抑制のため、全fit部分集合(run<=400, n~200,000)ではなく、先頭20run
        # (run=1..20, n~10,000)の実データ部分集合を用いる(タスク指示の「完了確認テストは
        # 全fit分割を使わなくてもよい」判断に基づく、STATUS REPORTのCONCERNSに記録)。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")

        if isfile(healthy_path)
            df_normal = load_rdata(healthy_path)
            df_small = filter(row -> row.simulationRun <= 20, df_normal)
            split_small = PhysicsResiduals.NormalFitSplit(df_small)

            t_start = time()
            uncertainty = PhysicsResiduals.bootstrap_lambda_uncertainty(
                split_small; n_resamples = 100, rng = MersenneTwister(2026)
            )
            elapsed = time() - t_start
            @info "bootstrap_lambda_uncertainty real-data wall-clock time (20 runs, 100 resamples)" elapsed

            @test uncertainty isa PhysicsResiduals.LambdaUncertainty
            for ci in (uncertainty.a_ci, uncertainty.b_ci, uncertainty.t_cw_in_ci)
                @test ci[1] <= ci[2]
                @test isfinite(ci[1]) && isfinite(ci[2])
            end
        else
            @warn "Local test data not found. Skipping bootstrap_lambda_uncertainty real-data test."
        end
    end

    @testset "check_holdout_stability (合成データ: 安定/不安定の判別)" begin
        # Requirement 3.2: holdoutでの再評価がfit時の不確かさ範囲内かを判定する。
        # Requirement 3.3: 範囲外ならfalse(不安定)を返す。
        #
        # 注意(パラメータ選定の理由): ブートストラップCIは、fit側に存在する有限個の
        # run(ここでは30個)の「どの組み合わせを選ぶか」による変動のみを捉えるため、
        # 全く新規に生成されたholdoutデータ(新しいrunの乱数、別シード)固有の推定誤差は
        # 完全には反映されない(run単位ブロックブートストラップの既知の性質であり、実装の
        # 誤りではない)。そのため、ノイズが極端に小さい場合(例: noise_std=5e-4)はCIが
        # 機械精度近くまで潰れてしまい、独立した新規drawのholdout推定値がわずかにそこから
        # 外れてfalseになりやすい。逆にノイズが大きすぎる場合は、名目上95%の被覆率でも
        # a・b・T_cw,inの3つ同時に収まる必要があるため偶然外れることがある。本テストでは、
        # 固定シードの組み合わせで両ケース(安定/不安定)が明確に分かれることを事前に
        # 数値実験で確認した値(noise_std=0.02, n_runs=30)を用いる。シフトケース
        # (t_cw_in: 30->60)は、このノイズ水準に対して十分大きく、CI幅よりはるかに大きい
        # ため、シード選択に依らず安定してfalseになる。
        a_true = 2.0
        t_cw_in_true = 30.0
        noise_std = 0.02
        n_runs = 30
        rows_per_run = 20

        rng_fit = MersenneTwister(1001)
        df_fit = _make_synth_run_df(rng_fit, n_runs, rows_per_run, noise_std; a_true = a_true, t_cw_in_true = t_cw_in_true)
        split_fit = PhysicsResiduals.NormalFitSplit(df_fit)
        lam_fit = PhysicsResiduals.identify_lambda(split_fit)
        uncertainty = PhysicsResiduals.bootstrap_lambda_uncertainty(split_fit; n_resamples = 150, rng = MersenneTwister(2001))

        # 安定ケース: holdoutが同じ真のlambdaから生成される -> CI内に収まりtrue
        rng_holdout_ok = MersenneTwister(3001)
        df_holdout_ok = _make_synth_run_df(
            rng_holdout_ok, n_runs, rows_per_run, noise_std; a_true = a_true, t_cw_in_true = t_cw_in_true
        )
        @test PhysicsResiduals.check_holdout_stability(lam_fit, uncertainty, df_holdout_ok) == true

        # 不安定ケース: holdoutでt_cw_inが大きくシフト(30->60)した状態から生成
        # -> 再同定されたt_cw_inがfit時のCI外となりfalse
        rng_holdout_shift = MersenneTwister(4001)
        df_holdout_shift = _make_synth_run_df(
            rng_holdout_shift, n_runs, rows_per_run, noise_std; a_true = a_true, t_cw_in_true = 60.0
        )
        @test PhysicsResiduals.check_holdout_stability(lam_fit, uncertainty, df_holdout_shift) == false
    end

    @testset "check_holdout_stability (実データ: 実行可能性の確認)" begin
        # 実データでの安定性判定の真偽そのものは、タスク2.1で確認済みの多重共線性所見
        # (閉ループ制御下でx1, x2の相関が高いこと)の影響を受け得るため、本テストでは
        # true/falseいずれであっても正しいとみなし、断定しない(CLAUDE.md学術的誠実さ)。
        # 完了確認は、関数が実データに対してエラーなく実行されBool型を返すことのみとする。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")

        if isfile(healthy_path)
            df_normal = load_rdata(healthy_path)
            df_small_fit = filter(row -> row.simulationRun <= 20, df_normal)
            df_small_holdout = filter(row -> 20 < row.simulationRun <= 40, df_normal)

            split_small_fit = PhysicsResiduals.NormalFitSplit(df_small_fit)
            lam_small = PhysicsResiduals.identify_lambda(split_small_fit)
            uncertainty_small = PhysicsResiduals.bootstrap_lambda_uncertainty(
                split_small_fit; n_resamples = 80, rng = MersenneTwister(7)
            )

            stable = PhysicsResiduals.check_holdout_stability(lam_small, uncertainty_small, df_small_holdout)
            @test stable isa Bool
        else
            @warn "Local test data not found. Skipping check_holdout_stability real-data test."
        end
    end

end

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
using .TEPDataLoader: load_rdata, load_rdata_subset

# 異常データ(TEP_Faulty_Training.RData、約5,000,000行)を全体読み込みすると1プロセスで
# 数GBのメモリを消費するため、本テストが対象とするIDV(4, 11, 14)の行だけを
# キャッシュ経由で読み込む(初回のみ全体を読み込んでキャッシュを作成する)。
load_faulty_target_idvs(faulty_path) = load_rdata_subset(faulty_path; fault_numbers = [4, 11, 14])

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
            df_faulty = load_faulty_target_idvs(faulty_path)

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

    # ========================================================================
    # タスク3.1: 平均シフト型検知の実装(MeanShiftDetector、IDV4)
    # Requirements: 4.1, 4.2, 4.3, 4.4, 4.5
    # ========================================================================

    """
        _residual(lam, tr, tcw_out, u10)

    タスク3.1のテスト用ヘルパー: lam=(a,b)を使って、単一行の反応器冷却水残差
    |y - (a*x1 + b*x2)| (y=tr-tcw_out, x1=u10*tcw_out, x2=u10) を直接計算する。
    `calibrate_threshold`/`detect_mean_shift`の実装が内部で呼ぶはずの
    `build_design_matrix`+残差計算と独立に、期待値を手計算で求めるためのヘルパー。
    """
    function _residual(lam::PhysicsResiduals.ReactorCwLambda, tr::Float64, tcw_out::Float64, u10::Float64)
        y = tr - tcw_out
        x1 = u10 * tcw_out
        x2 = u10
        return abs(y - (lam.a * x1 + lam.b * x2))
    end

    """
        _make_run_df(idv, run_id, samples, resid_at_sample; lam, tcw_out=94.6, u10=40.0)

    タスク3.1のテスト用ヘルパー: 1ランの合成故障データを構築する。各サンプルについて、
    `resid_at_sample(sample)`が返す値ちょうどの残差(非負)になるように`xmeas_9`を逆算する
    (tcw_out, u10は全サンプルで一定値に固定し、x1, x2を定数にすることで、残差への
    寄与をxmeas_9側の加算項だけに単純化する)。
    """
    function _make_run_df(idv::Int, run_id::Int, samples::Vector{Int}, resid_at_sample::Function;
                           lam::PhysicsResiduals.ReactorCwLambda, tcw_out::Float64 = 94.6, u10::Float64 = 40.0)
        n = length(samples)
        x1 = u10 * tcw_out
        x2 = u10
        baseline = lam.a * x1 + lam.b * x2  # resid=0となる基準のa*x1+b*x2
        xmeas_9 = Float64[tcw_out + baseline + resid_at_sample(s) for s in samples]
        return DataFrame(
            faultNumber = fill(idv, n),
            simulationRun = fill(run_id, n),
            sample = samples,
            xmeas_9 = xmeas_9,
            xmeas_21 = fill(tcw_out, n),
            xmv_10 = fill(u10, n)
        )
    end

    @testset "calibrate_threshold (正常保留データのみからFIT残差最大×1.25、Requirement 4.3)" begin
        # design.md MeanShiftDetector Service Interface:
        #   calibrate_threshold(lam, df_normal_holdout; margin=1.25)::Float64
        # しきい値は「正常の検証データ(保留部分集合)のみから決定する」(Requirement 4.3)。
        # calibrate_thresholdの引数にはdf_normal_holdoutしかなく、異常データへの
        # 参照手段自体が存在しない(型シグネチャレベルでの保証、タスク2.1と同じ思想)。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)

        tcw_out = 94.6
        u10 = 40.0
        x1 = u10 * tcw_out
        x2 = u10
        baseline = lam.a * x1 + lam.b * x2

        # 既知の残差(|resid|)を持つ3行の合成holdoutデータ: 0.5, 1.0, 2.0 -> 最大2.0
        resids = [0.5, 1.0, 2.0]
        df_holdout = DataFrame(
            simulationRun = [401, 402, 403],
            xmeas_9 = Float64[tcw_out + baseline + r for r in resids],
            xmeas_21 = fill(tcw_out, 3),
            xmv_10 = fill(u10, 3)
        )

        threshold_default = PhysicsResiduals.calibrate_threshold(lam, df_holdout)
        @test isapprox(threshold_default, maximum(resids) * 1.25; atol = 1e-9)

        threshold_custom_margin = PhysicsResiduals.calibrate_threshold(lam, df_holdout; margin = 2.0)
        @test isapprox(threshold_custom_margin, maximum(resids) * 2.0; atol = 1e-9)

        # Requirement 4.3の「異常データを参照しない」ことを実装レベルで保証するため、
        # df_normal_holdoutにfaultNumber != 0の行(異常データ由来)が含まれる場合は
        # 明示的エラーで停止する(サイレントな受理ではない)
        df_with_fault = DataFrame(
            simulationRun = [401],
            faultNumber = [4],
            xmeas_9 = [tcw_out + baseline],
            xmeas_21 = [tcw_out],
            xmv_10 = [u10]
        )
        @test_throws ErrorException PhysicsResiduals.calibrate_threshold(lam, df_with_fault)

        # margin<=0は物理的に無意味な閾値を生むため明示的エラー
        @test_throws ErrorException PhysicsResiduals.calibrate_threshold(lam, df_holdout; margin = 0.0)
    end

    @testset "detect_mean_shift (しきい値超過/未超過の正しい判別)" begin
        # design.md MeanShiftDetector Service Interface:
        #   detect_mean_shift(lam, df, threshold)::Vector{Bool}
        # 残差がしきい値を超える行のみtrueになること(どちらでも同じ値を返す自明な
        # 実装ではないことを示す)。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        tcw_out = 94.6
        u10 = 40.0
        x1 = u10 * tcw_out
        x2 = u10
        baseline = lam.a * x1 + lam.b * x2

        # 残差: [1.0(未満), 5.0(超過), 3.0(ちょうどしきい値、超過ではない)]
        threshold = 3.0
        resids = [1.0, 5.0, 3.0]
        df = DataFrame(
            xmeas_9 = Float64[tcw_out + baseline + r for r in resids],
            xmeas_21 = fill(tcw_out, 3),
            xmv_10 = fill(u10, 3)
        )

        flags = PhysicsResiduals.detect_mean_shift(lam, df, threshold)
        @test flags isa Vector{Bool}
        @test flags == [false, true, false]
        @test length(flags) == nrow(df)
    end

    """
        _make_holdout_df(resids; lam, tcw_out=94.6, u10=40.0)

    タスク3.1(remediation)のテスト用ヘルパー: `calibrate_threshold`/`evaluate_fault_detection`の
    `df_normal_holdout`引数に渡す、既知の残差`resids`を持つ正常保留データを構築する。
    """
    function _make_holdout_df(resids::Vector{Float64}; lam::PhysicsResiduals.ReactorCwLambda,
                               tcw_out::Float64 = 94.6, u10::Float64 = 40.0)
        x1 = u10 * tcw_out
        x2 = u10
        baseline = lam.a * x1 + lam.b * x2
        n = length(resids)
        return DataFrame(
            simulationRun = collect(401:(400 + n)),
            xmeas_9 = Float64[tcw_out + baseline + r for r in resids],
            xmeas_21 = fill(tcw_out, n),
            xmv_10 = fill(u10, n)
        )
    end

    @testset "evaluate_fault_detection (合成データ: FDR/ADD/FARの正しさ、投入時刻基準のADD)" begin
        # design.md MeanShiftDetector Service Interface:
        #   evaluate_fault_detection(lam, threshold, df_faulty, target_idvs)::DetectionMetrics
        # Requirement 4.4: IDVごとのFDRと、投入時刻(サンプル21)基準の検知遅れ(ADD)を報告する。
        # Requirement 4.5: FARを検知指標と区別して報告する。design.md MeanShiftDetector
        # 「Responsibilities & Constraints」は「正常検証データ(保留部分集合)」という語を
        # しきい値決定(4.3)に使っており、Requirement 4.5はこれを再利用する同じ語を使う。
        # したがってFARはdf_faultyではなく、calibrate_thresholdに渡すのと同じholdout
        # DataFrame(キーワード引数df_normal_holdout)から計算されなければならない
        # (レビュー指摘: 以前の実装はdf_faultyの投入前ウィンドウという別データソースを
        # 使っていた、という定義のすり替えへの修正)。
        # Requirement 8.2: ADDはFAULT_INJECTION_SAMPLE(=21)を基準に計測し、ラン先頭からでは
        # ない(findfirst(v->v>0, fault_col)のような常にサンプル1を返すバグを再導入しない)。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        threshold = 3.0

        samples = collect(1:30)

        # IDV=77: 2ラン。サンプル1~20は残差0(正常同等)。サンプル25で初めて
        # 残差10.0(閾値超過)が発生し、以降も超過が続く -> 検知遅れ = 25 - 21 = 4。
        # (ここが本テストの核心: faultNumber列はラン全体で定数の77であり、
        # findfirst(v -> v > 0, fault_col)のような実装は常にサンプル1(インデックス1)を
        # 返してしまう誤り。真の投入時刻サンプル21を基準にすると、検知はサンプル25
        # なので遅れは4であり、ラン先頭(サンプル1)からの遅れ24とは異なる値になる。)
        resid_fn_detected(s) = s < 25 ? 0.0 : 10.0
        run1 = _make_run_df(77, 1, samples, resid_fn_detected; lam = lam)
        run2 = _make_run_df(77, 2, samples, resid_fn_detected; lam = lam)

        # IDV=78: 1ラン。残差は常に0(投入後も含め、しきい値を一度も超えない) -> 未検知。
        resid_fn_undetected(s) = 0.0
        run3 = _make_run_df(78, 1, samples, resid_fn_undetected; lam = lam)

        df_faulty = vcat(run1, run2, run3)

        # holdoutはすべて残差0(しきい値3.0未満) -> far_pct=0%になるはず
        df_holdout = _make_holdout_df(fill(0.0, 5); lam = lam)

        metrics = PhysicsResiduals.evaluate_fault_detection(
            lam, threshold, df_faulty, [77, 78, 99]; df_normal_holdout = df_holdout
        )

        @test metrics isa PhysicsResiduals.DetectionMetrics

        # IDV77: 2ランとも検知 -> FDR=100%
        @test isapprox(metrics.fdr_by_idv[77], 100.0; atol = 1e-9)
        # 検知遅れはFAULT_INJECTION_SAMPLE(=21)基準でちょうど4(25-21)。
        # ラン先頭(サンプル1)基準なら24になってしまうため、この一致はADD計算が
        # 正しく投入時刻基準であることの直接的な証拠になる(Requirement 8.2の回帰防止)。
        @test isapprox(metrics.add_by_idv[77], 4.0; atol = 1e-9)
        @test metrics.add_by_idv[77] != 24.0

        # IDV78: 1ランとも未検知 -> FDR=0%、ADDは「検知なし」のセンチネル値(-1.0、
        # VerificationHarness.evaluate_fdiと同じ既存プロジェクト規約)
        @test isapprox(metrics.fdr_by_idv[78], 0.0; atol = 1e-9)
        @test metrics.add_by_idv[78] == -1.0

        # IDV99: df_faultyに存在しない(評価不能) -> 欠損としてNaNで明示する
        # (design.md Error Categories「評価不能」参照。他IDVの評価は継続している)
        @test isnan(metrics.fdr_by_idv[99])
        @test isnan(metrics.add_by_idv[99])

        # FAR: df_normal_holdoutのすべての行の残差が0(しきい値未満)なので0%
        @test isapprox(metrics.far_pct, 0.0; atol = 1e-9)
    end

    @testset "evaluate_fault_detection (合成データ: FARはdf_normal_holdoutのみに依存し、df_faultyの内容には依存しない)" begin
        # レビュー指摘の核心を直接検証する: far_pctはdf_faultyの投入前ウィンドウ(古い実装の
        # データソース)の内容が変わっても変化してはならず、df_normal_holdout(新しい・正しい
        # データソース)の内容が変わると変化しなければならない。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        threshold = 3.0
        samples = collect(1:30)

        # df_faultyの投入前ウィンドウ(sample=10)に、古い実装ならfar_pctを動かしていたはずの
        # 誤報相当の残差(10.0 > threshold)を混入させる。投入後(>=21)は残差0のまま
        # (検知自体はさせず、FAR計算の独立性のみを見る)。
        resid_fn_preinjection_spike(s) = s == 10 ? 10.0 : 0.0
        df_faulty = _make_run_df(80, 1, samples, resid_fn_preinjection_spike; lam = lam)

        # Case 1: holdoutがすべて残差0(しきい値未満) -> far_pctは0%のはず。
        # df_faultyの投入前ウィンドウに誤報相当の値を混入させていても、
        # far_pctがholdoutのみから計算されていればこの値は変化しない。
        df_holdout_clean = _make_holdout_df(fill(0.0, 5); lam = lam)
        metrics_clean = PhysicsResiduals.evaluate_fault_detection(
            lam, threshold, df_faulty, [80]; df_normal_holdout = df_holdout_clean
        )
        @test isapprox(metrics_clean.far_pct, 0.0; atol = 1e-9)

        # Case 2: 同じdf_faultyのまま、holdoutの内容だけを変える(5点中1点がしきい値超過)。
        # far_pctが変化すれば、実装が実際にdf_normal_holdoutを参照していることの直接的な証拠になる
        # (シグネチャにdf_normal_holdoutが存在するだけの見せかけの実装ではないことの確認)。
        df_holdout_noisy = _make_holdout_df([0.0, 0.0, 10.0, 0.0, 0.0]; lam = lam)
        metrics_noisy = PhysicsResiduals.evaluate_fault_detection(
            lam, threshold, df_faulty, [80]; df_normal_holdout = df_holdout_noisy
        )
        @test isapprox(metrics_noisy.far_pct, 20.0; atol = 1e-9)  # 1/5 * 100

        # 投入後は残差0のままなので未検知(FDR=0%)であることも確認(FARと検知指標が
        # 独立に計算されていることの確認、Requirement 4.5)
        @test isapprox(metrics_clean.fdr_by_idv[80], 0.0; atol = 1e-9)
        @test isapprox(metrics_noisy.fdr_by_idv[80], 0.0; atol = 1e-9)
    end

    @testset "evaluate_fault_detection (holdoutベースFARの0%-by-construction、開示された限界)" begin
        # calibrate_thresholdが出力するthreshold(=max(|resid_holdout|)*margin, margin>1)を
        # 同じholdoutに対してevaluate_fault_detectionへ渡すと、far_pctは構造的に常に0.0になる
        # (detect_mean_shiftが厳密不等号resid > thresholdを使うため、holdout自身の最大残差でも
        # 閾値を超えられない)。これはバグではなく、docstringに明記した開示済みの限界である。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        df_holdout = _make_holdout_df([0.5, 1.0, 2.0]; lam = lam)
        threshold = PhysicsResiduals.calibrate_threshold(lam, df_holdout)

        samples = collect(1:30)
        df_faulty = _make_run_df(81, 1, samples, s -> 0.0; lam = lam)

        metrics = PhysicsResiduals.evaluate_fault_detection(
            lam, threshold, df_faulty, [81]; df_normal_holdout = df_holdout
        )
        @test isapprox(metrics.far_pct, 0.0; atol = 1e-9)
    end

    @testset "evaluate_fault_detection (防御的チェック: df_normal_holdoutの要求と異常データ混入の拒否)" begin
        # df_normal_holdoutは必須キーワード引数であり、省略するとUndefKeywordErrorになる
        # (calibrate_thresholdの防御的チェックと同じ思想: サイレントなデフォルト値での
        # 受理ではなく、呼び出し側の誤りを即座に検出する)。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        threshold = 3.0
        samples = collect(1:30)
        df_faulty = _make_run_df(82, 1, samples, s -> 0.0; lam = lam)

        @test_throws UndefKeywordError PhysicsResiduals.evaluate_fault_detection(
            lam, threshold, df_faulty, [82]
        )

        # df_normal_holdoutにfaultNumber != 0の行(異常データ由来)が含まれる場合は、
        # calibrate_thresholdと同じ理由で明示的エラーで停止する
        df_holdout_with_fault = DataFrame(
            simulationRun = [401],
            faultNumber = [4],
            xmeas_9 = [94.6 + lam.a * (40.0 * 94.6) + lam.b * 40.0],
            xmeas_21 = [94.6],
            xmv_10 = [40.0]
        )
        @test_throws ErrorException PhysicsResiduals.evaluate_fault_detection(
            lam, threshold, df_faulty, [82]; df_normal_holdout = df_holdout_with_fault
        )
    end

    @testset "evaluate_fault_detection (実データ: タスク3.1完了確認、IDV4)" begin
        # タスク3.1の完了確認: 実際の異常データ(IDV4)に対しevaluate_fault_detectionを
        # 実行すると、FDR・ADD・FAR付きの検知指標(DetectionMetrics)が返る。
        #
        # ランタイム抑制のため(タスク2.2の完了確認テストと同じ判断、STATUS REPORTの
        # CONCERNSに記録): 正常データはfit側の先頭20run(run<=20)のみ、異常データ(IDV4)
        # はsimulationRun<=20のみに絞り込む。異常データはload_faulty_target_idvsにより
        # IDV(4, 11, 14)のキャッシュから読み込む(.RDataファイル全体の読み込みはキャッシュ
        # 作成時の初回のみ)。lambda同定・しきい値計算・検知評価はこの絞り込みにより
        # 高速になる。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")
        faulty_path = joinpath(project_root, "TEP_Faulty_Training.RData")

        if isfile(healthy_path) && isfile(faulty_path)
            df_normal = load_rdata(healthy_path)
            df_normal_small = filter(row -> row.simulationRun <= 40, df_normal)

            split_fit = PhysicsResiduals.NormalFitSplit(filter(row -> row.simulationRun <= 20, df_normal_small))
            df_holdout_small = filter(row -> row.simulationRun > 20, df_normal_small)

            lam_raw = PhysicsResiduals.identify_lambda(split_fit)
            lam = PhysicsResiduals.check_physical_plausibility(
                lam_raw; tcw_out_mean = mean(split_fit.df.xmeas_21)
            )

            threshold = PhysicsResiduals.calibrate_threshold(lam, df_holdout_small)
            @test threshold isa Float64
            @test isfinite(threshold)
            @test threshold > 0.0

            # 異常データの読み込み(初回はキャッシュ作成を含む)に要する時間を
            # 以下のwall-clock計測から除外するため、ロード完了後にt_startを置く
            df_faulty_all = load_faulty_target_idvs(faulty_path)
            df_faulty_idv4_small = filter(
                row -> row.faultNumber == 4 && row.simulationRun <= 20, df_faulty_all
            )
            @test nrow(df_faulty_idv4_small) > 0

            t_start = time()
            metrics = PhysicsResiduals.evaluate_fault_detection(
                lam, threshold, df_faulty_idv4_small, [4]; df_normal_holdout = df_holdout_small
            )
            elapsed = time() - t_start
            @info "evaluate_fault_detection real-data wall-clock time (IDV4, 20 runs, excl. RData.load)" elapsed

            @test metrics isa PhysicsResiduals.DetectionMetrics
            @test haskey(metrics.fdr_by_idv, 4)
            @test haskey(metrics.add_by_idv, 4)
            @test 0.0 <= metrics.fdr_by_idv[4] <= 100.0
            @test isfinite(metrics.far_pct)
            @test 0.0 <= metrics.far_pct <= 100.0
            # ADDが「検知なし」(-1.0)でない限り、FAULT_INJECTION_SAMPLE(=21)を基準とした
            # 非負の遅れであるはず(ラン先頭基準の誤った実装なら、投入前のサンプルにも
            # 反応してしまい、意味不明な値になりうる)
            if metrics.add_by_idv[4] != -1.0
                @test metrics.add_by_idv[4] >= 0.0
            end
        else
            @warn "Local test data not found. Skipping evaluate_fault_detection real-data test."
        end
    end

    # ========================================================================
    # タスク3.2: 分散変化型検知の実装(VarianceShiftDetector、IDV11/14)
    # Requirements: 5.1, 5.2, 5.3, 5.4
    #
    # 命名衝突の解決(タスク本文の指示): design.md VarianceShiftDetector「Service
    # Interface」はevaluate_fault_detectionという名前をMeanShiftDetectorと文字通り
    # 再利用しているが、シグネチャは
    #   MeanShiftDetector:     evaluate_fault_detection(lam, threshold, df_faulty, target_idvs; df_normal_holdout)
    #   VarianceShiftDetector: evaluate_fault_detection(lam, window, threshold, df_faulty, target_idvs; df_normal_holdout)
    # であり、位置引数の個数が4個/5個と異なるため、Juliaの多重ディスパッチにより
    # 曖昧性なく区別できる(design.md Postconditions「戻り値はMeanShiftDetector.
    # DetectionMetricsと同じ型で、別経路の結果として区別可能」とも整合)。したがって
    # タスク3.1の既存メソッドをリネーム・上書きせず、同名の第2メソッドとして追加する。
    # ========================================================================

    @testset "calibrate_variance_threshold (正常保留データのみからの窓内標準偏差最大×margin、Requirement 5.3)" begin
        # design.md VarianceShiftDetector Service Interface:
        #   calibrate_variance_threshold(lam, df_normal_holdout; window, margin=1.25)::Float64
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        window = 2

        # run401: 残差は常に0 -> 窓内標準偏差は常に0
        # run402: 残差=[0.0, 5.0, -5.0] -> 窓(window=2)内標準偏差はstd([0,5])とstd([5,-5])の2通り
        run401 = _make_run_df(0, 401, [1, 2, 3], s -> [0.0, 0.0, 0.0][s]; lam = lam)
        run402 = _make_run_df(0, 402, [1, 2, 3], s -> [0.0, 5.0, -5.0][s]; lam = lam)
        df_holdout = vcat(run401, run402)

        expected_max_std = max(std([0.0, 5.0]), std([5.0, -5.0]))

        threshold_default = PhysicsResiduals.calibrate_variance_threshold(lam, df_holdout; window = window)
        @test isapprox(threshold_default, expected_max_std * 1.25; atol = 1e-9)

        threshold_custom_margin = PhysicsResiduals.calibrate_variance_threshold(
            lam, df_holdout; window = window, margin = 2.0
        )
        @test isapprox(threshold_custom_margin, expected_max_std * 2.0; atol = 1e-9)

        # Requirement 5.3の「異常データを参照しない」ことを実装レベルで保証するため、
        # calibrate_thresholdと同じ防御的チェック(faultNumber != 0の行を拒否)を行う
        df_with_fault = _make_run_df(11, 403, [1, 2, 3], s -> 0.0; lam = lam)
        @test_throws ErrorException PhysicsResiduals.calibrate_variance_threshold(
            lam, df_with_fault; window = window
        )

        # margin<=0は物理的に無意味な閾値を生むため明示的エラー
        @test_throws ErrorException PhysicsResiduals.calibrate_variance_threshold(
            lam, df_holdout; window = window, margin = 0.0
        )

        # window<2は窓内標準偏差が定義不能(NaN)になる退化ケースのため明示的エラー
        @test_throws ErrorException PhysicsResiduals.calibrate_variance_threshold(
            lam, df_holdout; window = 1
        )
    end

    @testset "detect_variance_shift (しきい値超過/未超過の正しい判別、Requirement 5.1/5.2)" begin
        # design.md VarianceShiftDetector Service Interface:
        #   detect_variance_shift(lam, df, window, threshold)::Vector{Bool}
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        window = 2

        r = [0.0, 0.0, 10.0, 0.0]
        df = _make_run_df(90, 1, collect(1:4), s -> r[s]; lam = lam)

        # サンプル3・4の窓(window=2)はどちらも多重集合{0,10}なので標準偏差は同じ値
        expected_std_34 = std([0.0, 10.0])

        # しきい値ちょうどでは厳密不等号(超過ではない)なのでフラグは立たない
        flags_not_flagged = PhysicsResiduals.detect_variance_shift(lam, df, window, expected_std_34)
        @test flags_not_flagged isa Vector{Bool}
        @test flags_not_flagged == [false, false, false, false]
        @test length(flags_not_flagged) == nrow(df)

        # しきい値をわずかに下げると超過してフラグが立つ
        flags_flagged = PhysicsResiduals.detect_variance_shift(lam, df, window, expected_std_34 - 1e-6)
        @test flags_flagged == [false, false, true, true]
    end

    @testset "detect_variance_shift (ラン境界を尊重し、ランをまたいで窓を構成しないこと、Requirement 8.3/5.1)" begin
        # window=2のとき、ランをまたいで窓を構成してしまう誤った実装は、あるランの
        # 最終サンプルと次のランの先頭サンプルを1つの窓として扱ってしまう。
        # run1(残差=[0,0])・run2(残差=[1000,-1000])を作り、しきい値500を、
        # 「ランをまたいだ窓(std([0,1000])≈707.1)」と「run2内だけの窓(std([1000,-1000])≈1414.2)」
        # の間に設定することで、ランをまたぐ誤実装とラン境界を尊重する正しい実装を直接
        # 区別できるようにする。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        window = 2
        threshold = 500.0

        run1 = _make_run_df(91, 1, [1, 2], s -> [0.0, 0.0][s]; lam = lam)
        run2 = _make_run_df(91, 2, [1, 2], s -> [1000.0, -1000.0][s]; lam = lam)

        # ケース1: 入力行順序がソート順(run1 -> run2)と一致する場合
        df_ordered = vcat(run1, run2)
        flags_ordered = PhysicsResiduals.detect_variance_shift(lam, df_ordered, window, threshold)
        # run2の先頭サンプル(global行3)はrun2内ではまだ1サンプルしかなく窓を構成できない
        # ため未発火(false)。もしランをまたいで窓を構成する誤実装なら、run1の最終サンプル
        # (残差0)とrun2の先頭サンプル(残差1000)を窓にしてstd([0,1000])≈707.1>500となり
        # 誤って発火(true)してしまう。
        @test flags_ordered == [false, false, false, true]

        # ケース2: 入力行順序をソート順と逆(run2 -> run1)にしても、戻り値は入力df自身の
        # 行順序に対応すること(respects_run_boundaryによる内部ソートの後、元の行順序へ
        # 正しく戻されていることの確認)。
        df_scrambled = vcat(run2, run1)
        flags_scrambled = PhysicsResiduals.detect_variance_shift(lam, df_scrambled, window, threshold)
        @test flags_scrambled == [false, true, false, false]
    end

    @testset "detect_variance_shift は detect_mean_shift と独立に発火する (Requirement 5.1/5.2)" begin
        # 平均ベースの検知経路(detect_mean_shift)とは独立に、分散ベースの検知経路
        # (detect_variance_shift)が発火することを直接証明する。振幅40で正負に振動する
        # 残差(|40|<50なので平均ベースの|resid|>50は一度も発火しない)を投入時刻
        # (サンプル21)以降に与えると、窓内(window=2)標準偏差std([40,-40])≈56.57は
        # 分散しきい値30を超えるため、分散ベースは独立に発火する。
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        mean_threshold = 50.0
        window = 2
        variance_threshold = 30.0

        samples = collect(1:30)
        r = Float64[s < 21 ? 0.0 : (iseven(s) ? -40.0 : 40.0) for s in samples]
        df = _make_run_df(92, 1, samples, s -> r[s]; lam = lam)

        mean_flags = PhysicsResiduals.detect_mean_shift(lam, df, mean_threshold)
        @test all(!, mean_flags)

        variance_flags = PhysicsResiduals.detect_variance_shift(lam, df, window, variance_threshold)
        @test any(variance_flags)
        @test all(.!variance_flags[1:21])
        @test all(variance_flags[22:30])

        # evaluate_fault_detectionレベル(多重ディスパッチで区別される2メソッド)でも
        # 同じ独立性が確認できることを示す: 平均ベースは未検知(FDR=0%)、分散ベースは
        # 検知(FDR=100%)という、平均ベースの検知結果に関わらず分散ベースが独立に
        # 検知フラグを発する(Requirement 5.2)ことの直接証拠。
        #
        # 注: _make_holdout_df(タスク3.1)は:sample/:simulationRun列を持たない
        # (MeanShiftDetector版のdf_normal_holdoutは行単位の残差計算のみで、ラン境界を
        # 意識しないため不要だった)。VarianceShiftDetector版は窓内標準偏差の計算に
        # ラン境界(:simulationRun・:sample)が必須のため、ここでは_make_run_dfで
        # 必要な列を持つholdoutを構築する(idv=0で正常データであることを表現)。
        df_holdout = _make_run_df(0, 501, collect(1:5), s -> 0.0; lam = lam)

        mean_metrics = PhysicsResiduals.evaluate_fault_detection(
            lam, mean_threshold, df, [92]; df_normal_holdout = df_holdout
        )
        variance_metrics = PhysicsResiduals.evaluate_fault_detection(
            lam, window, variance_threshold, df, [92]; df_normal_holdout = df_holdout
        )

        @test isapprox(mean_metrics.fdr_by_idv[92], 0.0; atol = 1e-9)
        @test isapprox(variance_metrics.fdr_by_idv[92], 100.0; atol = 1e-9)
        @test isapprox(variance_metrics.add_by_idv[92], 1.0; atol = 1e-9)
    end

    @testset "evaluate_fault_detection (防御的チェック: VarianceShiftDetector側のdf_normal_holdout要求と異常データ混入の拒否)" begin
        lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        window = 2
        threshold = 3.0
        samples = collect(1:30)
        df_faulty = _make_run_df(82, 1, samples, s -> 0.0; lam = lam)

        @test_throws UndefKeywordError PhysicsResiduals.evaluate_fault_detection(
            lam, window, threshold, df_faulty, [82]
        )

        df_holdout_with_fault = DataFrame(
            simulationRun = [401],
            faultNumber = [4],
            sample = [1],
            xmeas_9 = [94.6 + lam.a * (40.0 * 94.6) + lam.b * 40.0],
            xmeas_21 = [94.6],
            xmv_10 = [40.0]
        )
        @test_throws ErrorException PhysicsResiduals.evaluate_fault_detection(
            lam, window, threshold, df_faulty, [82]; df_normal_holdout = df_holdout_with_fault
        )
    end

    @testset "evaluate_fault_detection (実データ: タスク3.2完了確認、IDV11・IDV14、VarianceShiftDetector)" begin
        # タスク3.2の完了確認: 実際の異常データ(IDV11, IDV14)に対しevaluate_fault_detectionを
        # 実行すると、平均シフト経路とは別の検知指標(DetectionMetrics)が返る。
        #
        # 窓長window=20(=60分、3分間隔サンプリング)の選定理由: 本タスクの実装時検証
        # (scratchpad調査、brief.mdのIDV11/14ラン内標準偏差比6.5〜13.8倍の実測と整合)で、
        # window=10/15/20/30のいずれでも正常保留データに対する窓内標準偏差の最大値に対し、
        # IDV11/14投入後の窓内標準偏差が明確に(72%〜100%のサンプルで)それを超えることを
        # 確認済み。window=20は単一サンプルノイズに支配されるほど短くはなく(1時間相当の
        # 平滑化)、かつ故障検知が過度に遅れるほど長くもない、妥当な中間値として選定した。
        project_root = dirname(dirname(@__DIR__))
        healthy_path = joinpath(project_root, "TEP_FaultFree_Training.RData")
        faulty_path = joinpath(project_root, "TEP_Faulty_Training.RData")
        window = 20

        if isfile(healthy_path) && isfile(faulty_path)
            df_normal = load_rdata(healthy_path)
            df_normal_small = filter(row -> row.simulationRun <= 40, df_normal)

            split_fit = PhysicsResiduals.NormalFitSplit(filter(row -> row.simulationRun <= 20, df_normal_small))
            df_holdout_small = filter(row -> row.simulationRun > 20, df_normal_small)

            lam_raw = PhysicsResiduals.identify_lambda(split_fit)
            lam = PhysicsResiduals.check_physical_plausibility(
                lam_raw; tcw_out_mean = mean(split_fit.df.xmeas_21)
            )

            variance_threshold = PhysicsResiduals.calibrate_variance_threshold(
                lam, df_holdout_small; window = window
            )
            @test variance_threshold isa Float64
            @test isfinite(variance_threshold)
            @test variance_threshold > 0.0

            mean_threshold = PhysicsResiduals.calibrate_threshold(lam, df_holdout_small)

            df_faulty_all = load_faulty_target_idvs(faulty_path)
            df_faulty_small = filter(
                row -> row.faultNumber in (11, 14) && row.simulationRun <= 20, df_faulty_all
            )
            @test nrow(df_faulty_small) > 0

            t_start = time()
            variance_metrics = PhysicsResiduals.evaluate_fault_detection(
                lam, window, variance_threshold, df_faulty_small, [11, 14]; df_normal_holdout = df_holdout_small
            )
            elapsed = time() - t_start
            @info "evaluate_fault_detection (VarianceShiftDetector) real-data wall-clock time (IDV11/14, 20 runs)" elapsed

            mean_metrics = PhysicsResiduals.evaluate_fault_detection(
                lam, mean_threshold, df_faulty_small, [11, 14]; df_normal_holdout = df_holdout_small
            )

            @test variance_metrics isa PhysicsResiduals.DetectionMetrics
            @test mean_metrics isa PhysicsResiduals.DetectionMetrics

            for idv in (11, 14)
                @test haskey(variance_metrics.fdr_by_idv, idv)
                @test haskey(variance_metrics.add_by_idv, idv)
                @test 0.0 <= variance_metrics.fdr_by_idv[idv] <= 100.0
                if variance_metrics.add_by_idv[idv] != -1.0
                    @test variance_metrics.add_by_idv[idv] >= 0.0
                end
            end
            @test isfinite(variance_metrics.far_pct)
            @test 0.0 <= variance_metrics.far_pct <= 100.0

            # 完了確認の核心: 分散経路の指標は平均経路の指標と別個のインスタンスとして
            # 算出され、少なくとも1つのIDVでFDRまたはADDの値が異なる(design.md
            # VarianceShiftDetector Postconditions「戻り値はMeanShiftDetector.
            # DetectionMetricsと同じ型で、別経路の結果として区別可能」)。
            @test variance_metrics !== mean_metrics
            differs = any(
                !isequal(variance_metrics.fdr_by_idv[idv], mean_metrics.fdr_by_idv[idv]) ||
                !isequal(variance_metrics.add_by_idv[idv], mean_metrics.add_by_idv[idv])
                for idv in (11, 14)
            )
            @test differs
        else
            @warn "Local test data not found. Skipping evaluate_fault_detection (VarianceShiftDetector) real-data test."
        end
    end

    @testset "diagnose_sliding_window (合成データ: 既知のlambdaドリフトの方向・大きさの正しい復元、タスク4.1完了確認)" begin
        # タスク4.1の完了確認: 凍結lambda(frozen)と、既知のドリフトを持つ直近窓データ
        # (true_a2, true_t_cw_in2がfrozenからの既知差分を持つ)に対しdiagnose_sliding_windowを
        # 実行すると、各lambda要素(a, b, 導出t_cw_in)の変化の方向(符号)と大きさ(絶対値)が
        # 正しく返ることを確認する。identify_lambda(タスク2.1)と同じ厳密OLS復元ロジックを
        # 再利用しているため、ノイズなしの合成データでは数値誤差内で既知の真値に一致するはずである
        # (identify_lambdaの既存テスト「identify_lambda (合成データ: タスク2.1完了確認、既知a,bの復元)」
        # と同じデータ構築パターンを踏襲)。
        rng = MersenneTwister(2024)
        n = 80

        # 凍結lambda(検知に使われている値、これ自体はダミーの既知値として直接構築する)
        a_frozen = 2.0
        t_cw_in_frozen = 30.0
        b_frozen = -a_frozen * t_cw_in_frozen  # -60.0
        frozen_lam = PhysicsResiduals.ReactorCwLambda(a_frozen, b_frozen, t_cw_in_frozen, true, nothing)

        # 直近窓データの真のlambda: aは増加(+0.3)、t_cw,inは上昇(+5.0)という既知のドリフトを持つ
        # (例えばIDV(4)による冷却水入口温度上昇の仮説と同じ方向性、CLAUDE.md §4(b)参照)
        a_window_true = a_frozen + 0.3           # 2.3
        t_cw_in_window_true = t_cw_in_frozen + 5.0  # 35.0
        b_window_true = -a_window_true * t_cw_in_window_true  # -79.9

        tcw_out = 90.0 .+ 10.0 .* rand(rng, n)
        u10 = 30.0 .+ 20.0 .* rand(rng, n)
        x1 = u10 .* tcw_out
        x2 = u10
        tr = tcw_out .+ a_window_true .* x1 .+ b_window_true .* x2  # 雑音なし

        df_recent = DataFrame(xmeas_9 = tr, xmeas_21 = tcw_out, xmv_10 = u10)

        # 凍結lambdaの呼び出し前の値を保存し、呼び出し後に不変であることを確認するための比較用
        frozen_before = (frozen_lam.a, frozen_lam.b, frozen_lam.t_cw_in, frozen_lam.valid, frozen_lam.invalid_reason)

        result = PhysicsResiduals.diagnose_sliding_window(frozen_lam, df_recent)

        @test result isa PhysicsResiduals.DiagnosticResult

        # window_lambdaは直近窓データから厳密OLSで復元された真値に(数値誤差内で)一致する
        @test isapprox(result.window_lambda.a, a_window_true; atol = 1e-6, rtol = 1e-6)
        @test isapprox(result.window_lambda.b, b_window_true; atol = 1e-4, rtol = 1e-6)
        @test isapprox(result.window_lambda.t_cw_in, t_cw_in_window_true; atol = 1e-4, rtol = 1e-4)

        # frozen_lambdaは引数として渡したものと同一の値を保持する
        @test result.frozen_lambda === frozen_lam

        # 各差分(delta)は方向(符号)と大きさ(絶対値)の両方を正しく運ぶ: a, t_cw,inは増加(正)、
        # bはより負に変化(負の方向)というドリフトの既知の向きと一致すること
        @test isapprox(result.delta_a, a_window_true - a_frozen; atol = 1e-6, rtol = 1e-6)
        @test result.delta_a > 0.0  # aは増加方向

        @test isapprox(result.delta_b, b_window_true - b_frozen; atol = 1e-4, rtol = 1e-6)
        @test result.delta_b < 0.0  # bはより負の方向

        @test isapprox(result.delta_t_cw_in, t_cw_in_window_true - t_cw_in_frozen; atol = 1e-4, rtol = 1e-4)
        @test result.delta_t_cw_in > 0.0  # t_cw,inは上昇方向

        # 凍結lambdaは呼び出し前後で不変(Requirement 6.3、design.md Postconditions
        # 「frozen_lamは呼び出し前後で不変」)であることを、フィールド値の比較で確認する
        # (ReactorCwLambdaはイミュータブルなstructだが、関数が引数とは別の新しいオブジェクトを
        # 誤って返すことで呼び出し元の変数を上書きするような使われ方をしていないことも含めて確認する)
        frozen_after = (frozen_lam.a, frozen_lam.b, frozen_lam.t_cw_in, frozen_lam.valid, frozen_lam.invalid_reason)
        @test frozen_before == frozen_after
    end

    @testset "diagnose_sliding_window (frozen_lamを書き換える操作がAPIに存在しないこと、Requirement 6.3)" begin
        # design.md LambdaDiagnostics「Validation」: Requirement 6.3は型レベルで担保される
        # (frozen_lamを書き換える操作がAPIに存在しない)。ReactorCwLambdaはmutable structではなく
        # イミュータブルなstructであるため、フィールド代入(frozen_lam.a = ...)自体が
        # Juliaの言語レベルでコンパイルエラーとなることを確認する。
        frozen_lam = PhysicsResiduals.ReactorCwLambda(2.0, -60.0, 30.0, true, nothing)
        @test_throws ErrorException frozen_lam.a = 999.0
    end

    @testset "diagnose_sliding_window (診断窓は検知フラグ周辺の直近データであり、異常データを含んでよいこと、Requirement 6.1/design.md Preconditions)" begin
        # design.md LambdaDiagnostics Service Interface「Preconditions: df_recentは検知フラグが
        # 発生した周辺の直近データ」。これは検知(=異常発生)後の診断を想定しており、
        # calibrate_threshold/calibrate_variance_threshold(Requirement 5.4等)のような
        # 「正常データのみ」を要求する防御的チェックとは異なる目的の関数である
        # (CLAUDE.md §3「検知時はlambdaを固定する。診断時のみ、スライディングウィンドウで
        # 再推定し、どのlambdaがどれだけ動いたかを報告する」が診断の対象として想定する状況)。
        #
        # df_recentにfaultNumber != 0の行(異常データ)を含めても、diagnose_sliding_windowが
        # エラーを投げずに正しく動作すること(スプリアスな拒否が起きないこと)を確認する。
        rng = MersenneTwister(99)
        n = 40
        a_true = 2.0
        t_cw_in_true = 30.0
        b_true = -a_true * t_cw_in_true

        tcw_out = 90.0 .+ 10.0 .* rand(rng, n)
        u10 = 30.0 .+ 20.0 .* rand(rng, n)
        x1 = u10 .* tcw_out
        x2 = u10
        tr = tcw_out .+ a_true .* x1 .+ b_true .* x2

        # IDV(4)の異常データを模擬するfaultNumber列(全行が故障中)を付加する。
        # build_design_matrixが参照する列(xmeas_9/xmeas_21/xmv_10)はそのままなので、
        # 同定ロジック自体はfaultNumber列の値を一切参照しない
        df_recent_faulty = DataFrame(
            xmeas_9 = tr, xmeas_21 = tcw_out, xmv_10 = u10,
            faultNumber = fill(4, n), simulationRun = fill(1, n), sample = collect(1:n)
        )

        frozen_lam = PhysicsResiduals.ReactorCwLambda(1.5, -45.0, 30.0, true, nothing)

        # エラーが投げられず、正しく同定結果が返ること(スプリアスな拒否が起きないことの確認)
        result = PhysicsResiduals.diagnose_sliding_window(frozen_lam, df_recent_faulty)
        @test result isa PhysicsResiduals.DiagnosticResult
        @test isapprox(result.window_lambda.a, a_true; atol = 1e-6, rtol = 1e-6)
        @test isapprox(result.window_lambda.t_cw_in, t_cw_in_true; atol = 1e-4, rtol = 1e-4)
    end

end

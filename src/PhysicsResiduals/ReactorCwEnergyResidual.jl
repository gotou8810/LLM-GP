# ============================================================================
# 反応器冷却水エネルギー収支残差 (reactor-cw-energy-residual spec)
#
# 本ファイルは、design.md「Components and Interfaces」で定義された以下10コンポーネントを
# 関数群として実装する予定地点(本タスク1.1では骨格のみで、ロジックは未実装):
#   - ResidualFormula        : 残差式 r = k*u10*(Tr-Tcwout) - UA*(Tr-Tcwout) の定義
#   - FaultTiming            : 故障投入時刻(サンプル21, 定数)とサニティチェック
#   - LambdaIdentifier       : 正常データ(fit部分集合)のみでの未知パラメータlambda同定
#   - LambdaValidator        : holdout部分集合での不確かさ・安定性・符号検証
#   - MeanShiftDetector      : 平均シフト型故障(IDV4)向けの検知経路
#   - VarianceShiftDetector  : 分散変化型故障(IDV11, IDV14)向けの検知経路
#   - LambdaDiagnostics      : 検知後のスライディング窓によるlambda再推定(凍結値は上書きしない)
#   - ComparisonExperiments  : 操作量ablationおよび持続性ベースラインとの比較実験
#   - MaskingChecker         : 対象外故障による操作量マスキングの確認
#   - EvaluationReport       : 上記すべてを統合したJSON形式のレポート出力
#
# 実装はタスク1.2以降で段階的に追加する。
# ============================================================================

using DataFrames
using Statistics

# FaultTimingはdesign.md「Components and Interfaces」でTEPDataLoaderをP0依存として
# 明記している(実データでの投入時刻サニティチェックのため)。本ファイルはPhysicsResiduals.jl
# にincludeされるので、ここでのincludeはPhysicsResiduals.TEPDataLoaderという
# サブモジュールになる(src/TEPDataLoader.jl自体は変更しない、読み取り専用の参照)。
include(joinpath(@__DIR__, "..", "TEPDataLoader.jl"))
using .TEPDataLoader: load_rdata

# ============================================================================
# FaultTiming (design.md「データ正確性」> FaultTiming、research.md
# 「故障投入時刻の確定方法」/「故障投入時刻は実行時検出ではなく定数として定義する」参照)
#
# Requirements: 8.1, 8.2, 8.3
# ============================================================================

"""
Rieth et al. 2017データセット(本プロジェクトが使用する版)における故障投入サンプル。

`docs/dataset_spec.md`に記載の実測(IDV(1)/(4)/(6)でサンプル20まで完全にz≈0、
サンプル21でz≈9.7に急変)により確認済みの定数であり、どのIDV・どの`simulationRun`
でも共通である。`faultNumber`列はラン全体に付与された定数ラベルであり投入時刻
そのものではないため(Requirement 8.1)、投入時刻はラベル列からではなく本定数を
直接使用すること。
"""
const FAULT_INJECTION_SAMPLE = 21

"""
    verify_injection_timing(df_faulty, target_idvs; pre_injection_max_sample=20,
                             significance_z=3.0, check_col=:xmv_10,
                             df_normal=nothing, healthy_path="TEP_FaultFree_Training.RData")::Bool

`FAULT_INJECTION_SAMPLE`(=21)という定数を実データに対してうのみにせず、対象の
故障(`target_idvs`)について、投入サンプルより前(`1:pre_injection_max_sample`)に
正常データの分布から有意な逸脱がないことを統計的に確認するサニティチェック
(Requirement 8.1)。

# 統計的方法
各`idv ∈ target_idvs`・各サンプルindex `s ∈ 1:pre_injection_max_sample`について、
- 正常データ(`df_normal`)の全runにわたる`check_col`の、サンプル`s`時点での平均`μ_s`と
  標準偏差`σ_s`をベースライン分布として計算する。
- 故障データ(`df_faulty`)から`faultNumber == idv`のrunを取り出し、サンプル`s`時点での
  `check_col`の全run平均`x̄_s`を計算する。
- zスコア `z = (x̄_s - μ_s) / σ_s` を計算する。

`target_idvs`のいずれか・`1:pre_injection_max_sample`のいずれかで`|z| > significance_z`
となるサンプルが1つでもあれば`false`を返す(投入時刻の前提が崩れている可能性があり、
評価を中断すべきことを示す)。すべてのサンプルで`|z| <= significance_z`であれば`true`
を返す。

`check_col`の既定値は`:xmv_10`(反応器冷却水流量操作量)。本specが対象とするIDV(4)
(冷却水入口温度ステップ)・IDV(11)(同ランダム変動)・IDV(14)(冷却水弁固着)はいずれも
この操作量を直接・間接に動かす故障であり(brief.mdの実測: IDV4ではこの操作量が
7σ変動する)、3 IDVに対して単一の変数で一貫してチェックできる
(research.mdの「投入時刻はどの変数で確認しても同じ経験的事実」という知見に基づく)。

`df_normal`を明示的に渡さない場合は、`healthy_path`(既定: プロジェクトルートの
`TEP_FaultFree_Training.RData`)から`TEPDataLoader.load_rdata`で読み込む
(design.mdのFaultTiming→TEPDataLoader依存、および`VerificationHarness.run_full_verification`
の`healthy_path`既定値規約を踏襲)。
"""
function verify_injection_timing(df_faulty::DataFrame, target_idvs::Vector{Int};
                                  pre_injection_max_sample::Int=20,
                                  significance_z::Float64=3.0,
                                  check_col::Symbol=:xmv_10,
                                  df_normal::Union{DataFrame,Nothing}=nothing,
                                  healthy_path::String="TEP_FaultFree_Training.RData")::Bool
    for col in (:faultNumber, :simulationRun, :sample, check_col)
        if !hasproperty(df_faulty, col)
            error("verify_injection_timing: df_faultyに必要な列 '$(col)' が存在しません")
        end
    end

    normal_df = df_normal === nothing ? load_rdata(healthy_path) : df_normal
    for col in (:sample, check_col)
        if !hasproperty(normal_df, col)
            error("verify_injection_timing: 正常データに必要な列 '$(col)' が存在しません")
        end
    end

    # 正常データの投入前ウィンドウのみを対象に、サンプルindexごとのベースライン(平均・標準偏差)を
    # 全runにわたって計算する。
    normal_pre = filter(row -> row.sample <= pre_injection_max_sample, normal_df)
    normal_mean = Dict{Int,Float64}()
    normal_std = Dict{Int,Float64}()
    for g in groupby(normal_pre, :sample)
        s = g.sample[1]
        vals = Vector{Float64}(g[!, check_col])
        normal_mean[s] = mean(vals)
        normal_std[s] = std(vals)
    end

    for idv in target_idvs
        df_idv_pre = filter(row -> row.faultNumber == idv && row.sample <= pre_injection_max_sample, df_faulty)
        if nrow(df_idv_pre) == 0
            error("verify_injection_timing: IDV($idv)のデータがdf_faultyに存在しません")
        end
        for g in groupby(df_idv_pre, :sample)
            s = g.sample[1]
            if !haskey(normal_mean, s)
                continue
            end
            sd = normal_std[s]
            sd_safe = sd > 0.0 ? sd : eps(Float64)
            faulty_mean_s = mean(Vector{Float64}(g[!, check_col]))
            z = (faulty_mean_s - normal_mean[s]) / sd_safe
            if abs(z) > significance_z
                return false
            end
        end
    end

    return true
end

"""
    respects_run_boundary(df, run_col=:simulationRun)::DataFrame

異なる`simulationRun`をまたいだデータ参照(例: あるランの最終サンプルを次のランの
先頭サンプルの「1サンプル前」として扱ってしまう誤り)を防ぐための分割ユーティリティ
(Requirement 8.3)。

`src/VerificationHarness.jl`が各関数内で個別に行っている
`sort(df, [run_col, :sample])`→`groupby(df_sorted, run_col)`という確立済みの
プロジェクト規約を、独立した再利用可能なユーティリティとして切り出したもの
(design.mdのFaultTiming「後続specが同じ定数を再利用できるよう独立した小さな
ユーティリティとして切り出す」方針を、ラン境界分割にも適用)。

返り値は`[run_col, :sample]`でソートされた`DataFrame`であり、呼び出し側はこれに対して
`groupby(result, run_col)`することで、ラン単位の時系列処理(差分計算等)を
ラン境界をまたぐことなく安全に行える。
"""
function respects_run_boundary(df::DataFrame, run_col::Symbol=:simulationRun)::DataFrame
    for col in (run_col, :sample)
        if !hasproperty(df, col)
            error("respects_run_boundary: dfに必要な列 '$(col)' が存在しません")
        end
    end
    return sort(df, [run_col, :sample])
end

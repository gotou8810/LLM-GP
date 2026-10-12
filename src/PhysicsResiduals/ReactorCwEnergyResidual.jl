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
using Random

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

# ============================================================================
# ResidualFormula (design.md「物理式・同定」> ResidualFormula参照)
#
# 残差式 r = k*u10*(Tcw_out - Tcw_in) - UA*(Tr - Tcw_out) を、両辺をUAで割って
# (Tr - Tcw_out)について解いた線形形式 y = a*x1 + b*x2 として表現する
# (brief.md「スケール不定性の解消と同定可能性」参照):
#
#   y  = Tr - Tcw_out                         (目的変数, XMEAS(9) - XMEAS(21))
#   x1 = u10 * Tcw_out                         (説明変数1, XMV(10) * XMEAS(21))
#   x2 = u10                                   (説明変数2, XMV(10))
#   a  = k / UA                                (同定可能な比)
#   b  = -a * Tcw_in = -(k/UA) * Tcw_in        (同定可能、Tcw_inは非測定)
#
# したがって y = a*x1 + b*x2 という lambda=(a,b) について線形な2パラメータ回帰になる。
#
# Requirements: 1.1, 1.2, 1.5, 1.6
# ============================================================================

"""
    ResidualFeatures

`build_design_matrix`の戻り値。反応器冷却水エネルギー収支残差を線形回帰
y = a*x1 + b*x2 として同定するための設計行列(3本の等長ベクトル)を保持する
(design.md ResidualFormula「State Management」参照)。

# フィールド
- `y::Vector{Float64}`: 目的変数 Tr - Tcw_out (XMEAS(9) - XMEAS(21))
- `x1::Vector{Float64}`: 説明変数1 u10 * Tcw_out (XMV(10) * XMEAS(21))
- `x2::Vector{Float64}`: 説明変数2 u10 (XMV(10))

3ベクトルは常に同じ長さ・同じ行インデックス集合に対応する(Invariant)。
"""
struct ResidualFeatures
    y::Vector{Float64}          # Tr - Tcw_out
    x1::Vector{Float64}         # u10 * Tcw_out
    x2::Vector{Float64}         # u10
end

"""
    LAMBDA_SIGN_CONSTRAINTS

未知パラメータlambda=(a, b)について、同定(タスク2.1 `LambdaIdentifier.identify_lambda`)
より前に宣言する期待符号の制約(Requirement 1.2、design.md ResidualFormula State
Management のリテラル定義と一致)。

- `a`: k>0(伝熱係数)・UA>0(総括伝熱係数×伝熱面積)より、a=k/UA>0が期待される
- `b`: a>0・Tcw_in>0(冷却水入口温度は絶対温度として正)より、b=-a*Tcw_in<0が期待される

この定数は符号制約の「事前宣言」であり、同定結果との事後照合(符号不一致時に
無効フラグを立てる処理, Requirement 1.3)自体は本タスクの範囲外で、
タスク2.1の`LambdaIdentifier.check_physical_plausibility`が担う
(design.md Requirements Traceability参照)。
"""
const LAMBDA_SIGN_CONSTRAINTS = (a = (:positive, 0.0), b = (:negative, 0.0))

"""
    LAMBDA_NON_IDENTIFIABILITY_NOTE

Requirement 1.6: 伝熱係数`k`と総括伝熱係数×伝熱面積`UA`は、残差式
`r = k*u10*(Tcw_out - Tcw_in) - UA*(Tr - Tcw_out)` の両辺を任意にスケールしても
同じ式が成り立つ(両辺を定数倍しても残差=0の関係は変わらない)ため、個別には
同定不可能である。同定可能なのは比`a = k/UA`のみであり、非測定の`Tcw_in`
(冷却水入口温度)は`b = -a*Tcw_in`の関係から`Tcw_in = -b/a`として導出される。

この定数文字列は、コード内ドキュメントとしてだけでなく、`EvaluationReport`等の
レポート出力(design.md Data Contracts & Integration参照)にそのまま含めることを
想定した、固定の報告用文言である(brief.md「同定可能性の結論」と同一の主張)。
"""
const LAMBDA_NON_IDENTIFIABILITY_NOTE =
    "伝熱係数k(熱伝達係数)と総括伝熱係数×伝熱面積UAは、残差式 r = k*u10*(Tcw_out - Tcw_in) " *
    "- UA*(Tr - Tcw_out) 全体のスケール不定性のため個別には同定不可能である。同定可能なのは " *
    "比 a = k/UA のみであり、非測定の冷却水入口温度 T_cw,in は b = -a*T_cw,in の関係から " *
    "T_cw,in = -b/a として導出される。kとUAそれぞれの値を主張してはならない。"

"""
    build_design_matrix(df; tr_col=:xmeas_9, tcw_out_col=:xmeas_21, u10_col=:xmv_10)::ResidualFeatures

反応器冷却水エネルギー収支残差の設計行列を構築する(Requirement 1.1)。

\$\$y = T_r - T_{cw,out}, \\quad x_1 = u_{10}\\,T_{cw,out}, \\quad x_2 = u_{10}\$\$

- Preconditions: `df`に`tr_col`・`tcw_out_col`・`u10_col`の列が存在する
- Postconditions: 返される`ResidualFeatures`の3ベクトルは`df`と同じ行数・行順序を保つ
- Invariants: `y`・`x1`・`x2`は常に同じ行インデックス集合に対応する

列が存在しない場合はサイレントなNaN伝播を避けるため明示的エラーで停止する
(design.md Implementation Notes「Validation」参照)。
"""
function build_design_matrix(df::DataFrame; tr_col::Symbol=:xmeas_9, tcw_out_col::Symbol=:xmeas_21,
                              u10_col::Symbol=:xmv_10)::ResidualFeatures
    for col in (tr_col, tcw_out_col, u10_col)
        if !hasproperty(df, col)
            error("build_design_matrix: dfに必要な列 '$(col)' が存在しません")
        end
    end

    tr = Vector{Float64}(df[!, tr_col])
    tcw_out = Vector{Float64}(df[!, tcw_out_col])
    u10 = Vector{Float64}(df[!, u10_col])

    y = tr .- tcw_out
    x1 = u10 .* tcw_out
    x2 = u10

    return ResidualFeatures(y, x1, x2)
end

"""
    ResidualFeaturesDynamic

Requirement 1.5の「準定常(代数式)の仮定が正常データの挙動を十分に説明できないと
判定された場合に、Tcw_outの時間変化率を表す項を残差式に追加する」ロジックの戻り値。
`ResidualFeatures`の3本に、動的項`x3 = d(Tcw_out)/dt`(後方差分)を加えた4本の
等長ベクトルを保持する。

design.mdのResidualFormula Service Interfaceは`assess_quasi_steady_adequacy`の
戻り値をBool(十分/不十分の判定のみ)と定義しているため、この判定を受けて実際に
動的項付きの設計行列を構築する役割は、本関数`build_design_matrix_with_dynamic_term`
が担う(design.md ResidualFormula「Responsibilities & Constraints」の「不十分なら
Tcw_outの変化率項を式に追加する」という責務を、判定とは別の関数として分離して実装)。
"""
struct ResidualFeaturesDynamic
    y::Vector{Float64}          # Tr - Tcw_out
    x1::Vector{Float64}         # u10 * Tcw_out
    x2::Vector{Float64}         # u10
    x3::Vector{Float64}         # d(Tcw_out)/dt (後方差分, ラン境界を尊重)
end

"""
    build_design_matrix_with_dynamic_term(df; tr_col=:xmeas_9, tcw_out_col=:xmeas_21,
                                           u10_col=:xmv_10, run_col=:simulationRun,
                                           sample_col=:sample, dt_minutes=3.0)::ResidualFeaturesDynamic

Requirement 1.5: 準定常仮定(`assess_quasi_steady_adequacy`が`false`)が不十分と
判定された場合に追加する、Tcw_outの時間変化率項

\$\$x_3(t) = \\frac{T_{cw,out}(t) - T_{cw,out}(t-1)}{\\Delta t}\$\$

(後方差分、既定`\\Delta t = 3`分、`docs/dataset_spec.md`のサンプリング間隔に一致)
を含む設計行列を構築する。

`respects_run_boundary`(タスク1.2、FaultTiming)を用いて`run_col`でソート・分割し、
各`simulationRun`の先頭サンプルは後方差分が取れないため除外する(ラン境界をまたいだ
差分を計算しないこと、`docs/dataset_spec.md`「ラン境界の扱い」参照)。したがって
戻り値の行数は`df`の行数より`unique(df[!, run_col])`の個数だけ少ない。

列が存在しない場合は明示的エラーで停止する。
"""
function build_design_matrix_with_dynamic_term(df::DataFrame; tr_col::Symbol=:xmeas_9,
                                                tcw_out_col::Symbol=:xmeas_21, u10_col::Symbol=:xmv_10,
                                                run_col::Symbol=:simulationRun, sample_col::Symbol=:sample,
                                                dt_minutes::Float64=3.0)::ResidualFeaturesDynamic
    for col in (tr_col, tcw_out_col, u10_col, run_col, sample_col)
        if !hasproperty(df, col)
            error("build_design_matrix_with_dynamic_term: dfに必要な列 '$(col)' が存在しません")
        end
    end

    sorted_df = respects_run_boundary(df, run_col)

    y_all = Float64[]
    x1_all = Float64[]
    x2_all = Float64[]
    x3_all = Float64[]

    for g in groupby(sorted_df, run_col)
        tr = Vector{Float64}(g[!, tr_col])
        tcw_out = Vector{Float64}(g[!, tcw_out_col])
        u10 = Vector{Float64}(g[!, u10_col])
        n = length(tcw_out)
        if n < 2
            continue
        end
        for i in 2:n
            push!(y_all, tr[i] - tcw_out[i])
            push!(x1_all, u10[i] * tcw_out[i])
            push!(x2_all, u10[i])
            push!(x3_all, (tcw_out[i] - tcw_out[i - 1]) / dt_minutes)
        end
    end

    return ResidualFeaturesDynamic(y_all, x1_all, x2_all, x3_all)
end

"""
    _norminvcdf(p)::Float64

標準正規分布の累積分布関数の逆関数(分位点関数)の近似。Peter J. Acklamの
有理関数近似(相対誤差 <~ 1.15e-9)を実装する。

`Statistics`標準ライブラリには分布の分位点関数が含まれず、本specは新規パッケージ
依存を追加しない方針(design.md Technology Stack参照)のため、
`assess_quasi_steady_adequacy`が有意水準から臨界値を求めるのに必要な
この近似を自前で実装する。
"""
function _norminvcdf(p::Float64)::Float64
    if !(0.0 < p < 1.0)
        error("_norminvcdf: pは(0,1)の範囲でなければなりません (p=$p)")
    end

    a1 = -3.969683028665376e+01; a2 = 2.209460984245205e+02
    a3 = -2.759285104469687e+02; a4 = 1.383577518672690e+02
    a5 = -3.066479806614716e+01; a6 = 2.506628277459239e+00

    b1 = -5.447609879822406e+01; b2 = 1.615858368580409e+02
    b3 = -1.556989798598866e+02; b4 = 6.680131188771972e+01
    b5 = -1.328068155288572e+01

    c1 = -7.784894002430293e-03; c2 = -3.223964580411365e-01
    c3 = -2.400758277161838e+00; c4 = -2.549732539343734e+00
    c5 = 4.374664141464968e+00; c6 = 2.938163982698783e+00

    d1 = 7.784695709041462e-03; d2 = 3.224671290700398e-01
    d3 = 2.445134137142996e+00; d4 = 3.754408661907416e+00

    p_low = 0.02425
    p_high = 1 - p_low

    if p < p_low
        q = sqrt(-2 * log(p))
        return (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) /
               ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
    elseif p <= p_high
        q = p - 0.5
        r = q * q
        return (((((a1 * r + a2) * r + a3) * r + a4) * r + a5) * r + a6) * q /
               (((((b1 * r + b2) * r + b3) * r + b4) * r + b5) * r + 1)
    else
        q = sqrt(-2 * log(1 - p))
        return -(((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) /
                ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
    end
end

"""
    assess_quasi_steady_adequacy(normal_resid; significance=0.05)::Bool

Requirement 1.5: 準定常(代数式)仮定のもとでの残差が、正常データの挙動を十分に
説明できるかを判定する(design.md ResidualFormula Service Interfaceのリテラル
シグネチャに一致)。`true`なら準定常仮定で十分、`false`なら
`build_design_matrix_with_dynamic_term`による動的項の追加が必要と判定する。

# 統計的方法(本実装での選択、design.md Implementation Notes「Risks」参照)
入力`normal_resid`(凍結前の正常データに対する残差 y - (a*x1 + b*x2) を想定)の
ラグ1自己相関係数

\$\$\\hat\\rho_1 = \\frac{\\sum_{t=1}^{n-1}(r_t-\\bar r)(r_{t+1}-\\bar r)}{\\sum_{t=1}^{n}(r_t-\\bar r)^2}\$\$

を計算する。残差が系統的な未説明構造を持たない(帰無仮説: ホワイトノイズ)場合、
大標本近似で \$\\hat\\rho_1 \\sim N(0, 1/n)\$ (Bartlettの近似)が成り立つことを用いて、

\$\$z = \\hat\\rho_1\\sqrt{n}\$\$

を計算し、有意水準`significance`(両側)に対応する標準正規分布の臨界値`z_crit`と
比較する。`|z| <= z_crit`であれば準定常仮定で十分(`true`)、それを超えれば
系統的な未説明構造(例: Tcw_outの緩やかな時間変化に由来する自己相関)が残差に
残っており、動的項の追加が必要(`false`)と判定する。

この手法を選んだ理由: 準定常(代数式)仮定が破れている場合、本来は動的項
(d Tcw_out/dt)で説明されるべき時間方向の構造が、代数式の残差に時間相関として
現れるはずである。ラグ1自己相関は最も単純で解釈しやすい診断であり、design.mdが
「具体的な検定方法は実装時に正常データで検証する」としたリスクに対する、
本実装での明示的な選択である。

- Preconditions: `normal_resid`は凍結前の正常データに対する残差系列(長さ10以上)
- Postconditions: `true`なら準定常仮定で十分、`false`なら動的項の追加が必要
"""
function assess_quasi_steady_adequacy(normal_resid::Vector{Float64}; significance::Float64=0.05)::Bool
    n = length(normal_resid)
    if n < 10
        error("assess_quasi_steady_adequacy: 残差系列が短すぎます(n=$(n))。十分な長さの正常データ残差を渡してください。")
    end
    if !(0.0 < significance < 1.0)
        error("assess_quasi_steady_adequacy: significanceは(0,1)の範囲でなければなりません (significance=$significance)")
    end

    r_centered = normal_resid .- mean(normal_resid)
    denom = sum(r_centered .^ 2)
    if denom == 0.0
        # 残差が完全に定数(分散ゼロ)の場合、系統的構造を議論する余地がないため
        # 準定常仮定で十分とみなす
        return true
    end

    numer = sum(r_centered[1:end - 1] .* r_centered[2:end])
    rho1 = numer / denom

    z = rho1 * sqrt(n)
    z_crit = _norminvcdf(1.0 - significance / 2.0)

    return abs(z) <= z_crit
end

# ============================================================================
# LambdaIdentifier (design.md「同定・検証」> LambdaIdentifier参照)
#
# 正常データを`simulationRun`基準でfit/holdout部分集合に重複なく分割し(Requirement 2.2)、
# fit部分集合のみを使って厳密OLSでlambda=(a,b)を同定し(Requirement 2.1)、
# 符号制約(Requirement 1.3)と導出T_cw,inの物理的妥当性(Requirement 1.4)を検証する。
#
# Requirements: 2.1, 2.2, 2.3, 1.3, 1.4
# ============================================================================

"""
    NormalFitSplit

`split_normal_data`が返すfit部分集合を保持する、不透明な軽量ラッパー型。

# 型安全性に関する設計判断(タスク2.1本文「入力の型シグネチャが異常データを受け取れない
ようにする」への対応、design.md LambdaIdentifier「Responsibilities & Constraints」の
「入力は正常運転データのみ。異常データへの参照を一切持たない(関数シグネチャレベルで
異常データ型を受け取らないことで保証する)」という記述を実現するための拡張)

Juliaの型システムには、「このDataFrameの内容が本当に正常運転データか」という
値の出自・意味的性質を実行時に追跡する機能はない(`DataFrame`はデータの由来を
型として区別しない)。したがって「異常データ型を受け取らない」という字面通りの
保証は、生`DataFrame`を引数に取る関数では原理的に実現できない。

本実装では、`identify_lambda`の引数型を生`DataFrame`ではなく本型`NormalFitSplit`に
限定することで、**呼び出し経路**のレベルでの型安全性を実現する:
`split_normal_data`(本ファイルで定義)を経由して得られたfit部分集合だけが、
慣用的に`NormalFitSplit`としてラップされて`identify_lambda`に渡される。
異常データを`TEPDataLoader.load_rdata`等で直接読み込んだ生`DataFrame`は、
`identify_lambda`のメソッドシグネチャに一致しないため、Juliaのメソッド
ディスパッチの段階で`MethodError`となり、呼び出し自体が成立しない。

design.mdのリテラルシグネチャ(`split_normal_data(...)::Tuple{DataFrame,DataFrame}`、
`identify_lambda(df_fit::DataFrame)::ReactorCwLambda`)をこの点で拡張している。
この拡張はタスク1.2/1.3で認められた前例(design.mdの記述意図を字面より優先し、
開示された拡張として受理する)に従う。
"""
struct NormalFitSplit
    df::DataFrame
end

"""
    ReactorCwLambda

反応器冷却水エネルギー収支残差の未知パラメータlambda=(a,b)と、そこから導出される
非測定の冷却水入口温度T_cw,in、および符号・物理的妥当性チェックの結果を1つに保持する
イミュータブルな値型(design.md Logical Data Model「無効なlambdaが誤って検知に
使われることを型レベルで防ぐ」設計方針、Requirement 6.3の前提)。

`mutable struct`ではなく`struct`として定義することで、一度生成された`ReactorCwLambda`
の値は変更不可能であり、検知用に凍結したlambdaが誤って上書きされることを型レベルで
防ぐ(将来タスクのLambdaDiagnostics等が新しい`ReactorCwLambda`値を返すのみで、
既存の値を書き換えられないことの保証)。

# フィールド
- `a::Float64`: k/UA(伝熱係数と総括伝熱係数×伝熱面積の比)
- `b::Float64`: -a*T_cw,in
- `t_cw_in::Float64`: 導出値 -b/a (非測定の冷却水入口温度)
- `valid::Bool`: 符号制約(Requirement 1.3)・物理的妥当性(Requirement 1.4)の検証結果
- `invalid_reason::Union{String,Nothing}`: `valid=false`の場合に具体的な理由を保持する
"""
struct ReactorCwLambda
    a::Float64
    b::Float64
    t_cw_in::Float64
    valid::Bool
    invalid_reason::Union{String,Nothing}
end

"""
    PLAUSIBLE_TCW_IN_RANGE

非測定の冷却水入口温度T_cw,inについて、工業用冷却水として物理的に妥当な範囲(Requirement 1.4)。

research.mdのRisks「T_cw,inの物理的妥当範囲が未定義」および「具体的な数値範囲は
実装時に`reference/teprob.f`を参照せず、工業用冷却水の一般的な知識(例: 0〜60°C程度)
から独立に設定し、データとの整合性のみ確認する」という方針に基づき設定する
(`teprob.f`の数値を読み取ってlambdaの値を埋めることはbrief.md「teprob.fの使用規律」で
明示的に禁止されている。この範囲はデータリークと無関係な、一般的な工業知識のみに基づく)。
"""
const PLAUSIBLE_TCW_IN_RANGE = (0.0, 60.0)

"""
    split_normal_data(df_normal; fit_run_max=400, run_col=:simulationRun)::Tuple{NormalFitSplit,DataFrame}

正常運転データを`run_col`(既定`:simulationRun`)基準でfit部分集合とholdout部分集合に
重複なく分割する(Requirement 2.2)。`run_col <= fit_run_max`の行をfit側、
`run_col > fit_run_max`の行をholdout側とする(`src/VerificationHarness.jl`の
`fit_run_max`分割規約(`filter(row -> row.simulationRun <= fit_run_max, df)`)と同一の慣用句)。

fit側は`identify_lambda`に渡せる型`NormalFitSplit`でラップして返す。holdout側は
将来タスク(LambdaValidator.check_holdout_stability)がそのまま`DataFrame`として
使う想定のため、ラップしない(design.md LambdaValidator Service Interfaceの
`df_holdout::DataFrame`と整合させる)。

- Preconditions: `df_normal`に`run_col`列が存在する
- Postconditions: 戻り値の2部分集合は`run_col`の値で完全に分離され(重複なし)、
  行の欠落・重複なく元の`df_normal`を汲み尽くす
"""
function split_normal_data(df_normal::DataFrame; fit_run_max::Int=400,
                            run_col::Symbol=:simulationRun)::Tuple{NormalFitSplit,DataFrame}
    if !hasproperty(df_normal, run_col)
        error("split_normal_data: df_normalに必要な列 '$(run_col)' が存在しません")
    end

    df_fit = filter(row -> row[run_col] <= fit_run_max, df_normal)
    df_holdout = filter(row -> row[run_col] > fit_run_max, df_normal)

    return (NormalFitSplit(df_fit), df_holdout)
end

"""
    identify_lambda(df_fit::NormalFitSplit)::ReactorCwLambda

正常データのfit部分集合のみを用いて、厳密OLSでlambda=(a,b)を同定し、
T_cw,in = -b/a を導出する(Requirement 2.1)。

\$\$y = a\\,x_1 + b\\,x_2, \\quad y=T_r-T_{cw,out},\\ x_1=u_{10}T_{cw,out},\\ x_2=u_{10}\$\$

`ResidualFormula.build_design_matrix`で設計行列(y, x1, x2)を構築し、
`A = [x1 x2]`として`A \\ y`(`linear_fit.jl`末尾の厳密OLS`G \\ (y .- h)`と同じ
数値解法の慣用句。本残差は物理的導出から線形であることが自明なため、
`linear_fit.jl`の重ね合わせの原理による線形性検証ステップは不要、research.md
「既存Julia資産の残差式への適用可能性」参照)で解く。

引数型は生`DataFrame`ではなく`NormalFitSplit`(`split_normal_data`だけが正規に
生成する)に限定されており、これにより異常データを直接渡すことが型シグネチャの
レベルで構造的に不可能になっている(タスク2.1本文、`NormalFitSplit`のドキュメント参照)。

本関数自体は符号・物理的妥当性の検証を行わない(それは`check_physical_plausibility`の
責務であり、design.mdのService Interfaceで両者が独立した関数として定義されている
ことに従う)。`valid=true, invalid_reason=nothing`を暫定値として返し、
`check_physical_plausibility`の呼び出しによって最終的な検証結果に更新される。

- Preconditions: `df_fit.df`は正常データの同定用部分集合のみ(`split_normal_data`の出力)
- Postconditions: 返される`ReactorCwLambda.t_cw_in`は`-b/a`に厳密に一致する
"""
function identify_lambda(df_fit::NormalFitSplit)::ReactorCwLambda
    feats = build_design_matrix(df_fit.df)

    n = length(feats.y)
    if n < 3
        error("identify_lambda: 同定に十分なデータ行がありません (n=$n)。少なくとも3行必要です。")
    end

    design_matrix = hcat(feats.x1, feats.x2)
    coeffs = design_matrix \ feats.y
    a = coeffs[1]
    b = coeffs[2]

    if a == 0.0
        error("identify_lambda: aがゼロと同定されたため T_cw,in = -b/a を計算できません")
    end
    t_cw_in = -b / a

    return ReactorCwLambda(a, b, t_cw_in, true, nothing)
end

"""
    check_physical_plausibility(lam::ReactorCwLambda; tcw_out_mean::Float64)::ReactorCwLambda

同定されたlambdaについて、符号制約(Requirement 1.3)と導出T_cw,inの物理的妥当性
(Requirement 1.4)をまとめて検証し、検証結果を反映した新しい`ReactorCwLambda`を返す。

# 検証内容
1. **符号制約(Requirement 1.3)**: `ResidualFormula.LAMBDA_SIGN_CONSTRAINTS`の事前宣言
   (`a`は正、`b`は負)に実際の同定結果が一致するか。一致しなければ`valid=false`、
   `invalid_reason`に「符号不一致」である旨を記録する。
2. **物理的妥当性(Requirement 1.4)**: 符号制約を満たした場合に限り、導出された
   `T_cw,in`が`tcw_out_mean`(冷却水出口温度の正常平均)未満であり(冷却水は反応器を
   通過する間に加熱されるため、入口温度は出口温度より低いはずである)、かつ
   `PLAUSIBLE_TCW_IN_RANGE`(工業用冷却水として妥当な範囲)内にあるか。いずれかを
   満たさなければ`valid=false`、`invalid_reason`に「物理的不整合」である旨を記録する。

両方の検証に合格した場合のみ`valid=true, invalid_reason=nothing`を返す。
`a`・`b`・`t_cw_in`の値そのものは変更しない(検証は値を書き換えず、合否のみを判定する)。

- Preconditions: `lam`は`identify_lambda`の出力(または同形式の値)
- Postconditions: `valid=false`の場合、`invalid_reason`に具体的な理由(符号不一致／
  物理的不整合のいずれか)が入る
"""
function check_physical_plausibility(lam::ReactorCwLambda; tcw_out_mean::Float64)::ReactorCwLambda
    a_direction, a_threshold = LAMBDA_SIGN_CONSTRAINTS.a
    b_direction, b_threshold = LAMBDA_SIGN_CONSTRAINTS.b

    a_sign_ok = a_direction == :positive ? lam.a > a_threshold : lam.a < a_threshold
    b_sign_ok = b_direction == :negative ? lam.b < b_threshold : lam.b > b_threshold

    if !(a_sign_ok && b_sign_ok)
        reason = "符号不一致(Requirement 1.3): a=$(lam.a) (期待: $(a_direction), 閾値 $(a_threshold)), " *
                  "b=$(lam.b) (期待: $(b_direction), 閾値 $(b_threshold))"
        return ReactorCwLambda(lam.a, lam.b, lam.t_cw_in, false, reason)
    end

    below_outlet = lam.t_cw_in < tcw_out_mean
    in_plausible_range = PLAUSIBLE_TCW_IN_RANGE[1] <= lam.t_cw_in <= PLAUSIBLE_TCW_IN_RANGE[2]

    if !(below_outlet && in_plausible_range)
        reason = "物理的不整合(Requirement 1.4): T_cw,in=$(lam.t_cw_in) " *
                  "(T_cw,out平均=$(tcw_out_mean)未満であるべき, 妥当範囲=$(PLAUSIBLE_TCW_IN_RANGE))"
        return ReactorCwLambda(lam.a, lam.b, lam.t_cw_in, false, reason)
    end

    return ReactorCwLambda(lam.a, lam.b, lam.t_cw_in, true, nothing)
end

# ============================================================================
# LambdaValidator (design.md「同定・検証」> LambdaValidator参照)
#
# 同定されたlambdaの不確かさ(ブートストラップ信頼区間)を定量化し(Requirement 3.1)、
# holdout部分集合で再同定したlambdaがその信頼区間内に収まるかを判定する
# (Requirement 3.2)。収まらない場合はlambdaを不安定(検知用途にまだ採用できない)
# とフラグする(Requirement 3.3)。
#
# Requirements: 3.1, 3.2, 3.3
# Depends: LambdaIdentifier (タスク2.1: identify_lambda, NormalFitSplit, ReactorCwLambda,
#          split_normal_data)
# ============================================================================

"""
    LambdaUncertainty

`bootstrap_lambda_uncertainty`の戻り値。lambda=(a, b)と、そこから導出される
T_cw,inについて、ブートストラップ信頼区間(既定95%)を保持するイミュータブルな値型
(design.md LambdaValidator「State Management」のリテラル定義と一致)。

# フィールド
- `a_ci::Tuple{Float64,Float64}`: aの信頼区間 (下端, 上端)
- `b_ci::Tuple{Float64,Float64}`: bの信頼区間 (下端, 上端)
- `t_cw_in_ci::Tuple{Float64,Float64}`: T_cw,inの信頼区間 (下端, 上端)
"""
struct LambdaUncertainty
    a_ci::Tuple{Float64,Float64}
    b_ci::Tuple{Float64,Float64}
    t_cw_in_ci::Tuple{Float64,Float64}
end

"""
    _resample_runs_with_replacement(df, run_col; rng=Random.default_rng())::DataFrame

design.md LambdaValidator「Responsibilities & Constraints」の
「リサンプリングはラン単位で行い、ラン内の時系列相関を壊さない」(Requirement 3.1の
実装制約)を実現する、ラン単位ブロックブートストラップのリサンプリング本体。

`df`に含まれる一意な`run_col`値(例: `simulationRun`)の集合から、元と同じ個数だけ
**run全体**を復元抽出する(個々の行を抽出するのではない)。抽出された各runについて、
そのrunに属するすべての行を、`df`における元の行順序を保ったまま連結して返す。

これにより:
- 各runの内部時系列構造(サンプル順序、ラグ関係)はリサンプル後も完全に保たれる
  (行単位ブートストラップであれば破壊される)
- あるrunが0回・1回・複数回選ばれることで、run間のばらつきがブートストラップ標本に反映される

`identify_lambda`に(`NormalFitSplit`でラップして)渡すことで、run単位リサンプリングに
基づく\$\\lambda\$のブートストラップ分布を得られる(`bootstrap_lambda_uncertainty`参照)。

- Preconditions: `df`に`run_col`列が存在する
- Postconditions: 戻り値の行数は、選ばれた各runの元の行数の合計に等しい
  (runを部分的に切り出すことはない)
"""
function _resample_runs_with_replacement(df::DataFrame, run_col::Symbol;
                                          rng::Random.AbstractRNG = Random.default_rng())::DataFrame
    if !hasproperty(df, run_col)
        error("_resample_runs_with_replacement: dfに必要な列 '$(run_col)' が存在しません")
    end

    run_ids = unique(df[!, run_col])
    row_indices_by_run = Dict(id => findall(==(id), df[!, run_col]) for id in run_ids)

    sampled_ids = rand(rng, run_ids, length(run_ids))

    idx = Int[]
    for id in sampled_ids
        append!(idx, row_indices_by_run[id])
    end

    return df[idx, :]
end

"""
    bootstrap_lambda_uncertainty(df_fit::NormalFitSplit; n_resamples=200, confidence=0.95,
                                  run_col=:simulationRun, rng=Random.default_rng())::LambdaUncertainty

Requirement 3.1: 同定されたlambdaの各要素(a, b, T_cw,in)について、ラン単位ブロック
ブートストラップによる不確かさ(既定95%信頼区間、パーセンタイル法)を算出する。

# 方法
1. `_resample_runs_with_replacement`で、`df_fit.df`からラン単位の復元抽出標本を
   `n_resamples`回生成する(各標本はラン内の時系列相関を保つ、`run_col`既定`:simulationRun`)。
2. 各標本を`NormalFitSplit`でラップし、`identify_lambda`(タスク2.1、`LambdaIdentifier`の
   同定ロジックをそのまま再利用)を適用してa, b, T_cw,in=-b/aを得る。
3. 得られた`n_resamples`組の(a, b, T_cw,in)から、パーセンタイル法で
   `confidence`(既定0.95)信頼区間を各要素について算出する:
   下端 = 標本の`(1-confidence)/2`分位点、上端 = `1-(1-confidence)/2`分位点。

# 型安全性に関する設計判断(design.mdのリテラルシグネチャ`df_fit::DataFrame`からの拡張)
design.mdのLambdaValidator Service Interfaceは`df_fit::DataFrame`と記載しているが、
同Preconditionsは「`df_fit`は`LambdaIdentifier.split_normal_data`の同定用部分集合と
同一であること」と定める。タスク2.1の型安全性拡張により`split_normal_data`の
第1戻り値は実際には`NormalFitSplit`であるため、本関数も`identify_lambda`と同じ
`NormalFitSplit`型のみを受理することで、「同定用部分集合と同一」という前提を
呼び出し経路のレベルで保証する(タスク2.1で認められた拡張パターンをそのまま踏襲)。
内部で各ブートストラップ標本(生DataFrame)を`NormalFitSplit`でラップして
`identify_lambda`に渡すのは、呼び出し元のテストスイート補助ヘルパーとは別に、
本関数自身の責務である。

`run_col`・`rng`はdesign.mdのリテラルシグネチャにはないが、ラン単位リサンプリングの
実装(Requirement 3.1の制約)と再現性確保のために追加したキーワード引数(開示済みの
拡張)である。

# 数値的頑健性
極端に不運なリサンプリング標本(例: 単一runが支配的に選ばれ説明変数が退化する)では、
`identify_lambda`内部の`a==0.0`チェックがエラーを発する場合がある。これは個々の
ブートストラップ標本の失敗として扱い、該当標本のみをスキップする
(値そのもののサイレントなNaN伝播ではなく、"どの標本が、なぜ失敗したか"が
明確なエラー経路からの意図的なスキップであり、`build_design_matrix`等の
「列が存在しない場合は明示的エラー」という方針とは別の、統計的推定における
標準的なブートストラップ失敗標本の除外処理である)。

- Preconditions: `n_resamples >= 2`, `0 < confidence < 1`
- Postconditions: 有効な標本が2件未満の場合は明示的エラーで停止する
"""
function bootstrap_lambda_uncertainty(df_fit::NormalFitSplit; n_resamples::Int = 200,
                                       confidence::Float64 = 0.95,
                                       run_col::Symbol = :simulationRun,
                                       rng::Random.AbstractRNG = Random.default_rng())::LambdaUncertainty
    if n_resamples < 2
        error("bootstrap_lambda_uncertainty: n_resamplesは2以上でなければなりません (n_resamples=$n_resamples)")
    end
    if !(0.0 < confidence < 1.0)
        error("bootstrap_lambda_uncertainty: confidenceは(0,1)の範囲でなければなりません (confidence=$confidence)")
    end

    df = df_fit.df

    a_samples = Float64[]
    b_samples = Float64[]
    t_cw_in_samples = Float64[]

    for _ in 1:n_resamples
        resampled_df = _resample_runs_with_replacement(df, run_col; rng = rng)
        try
            lam = identify_lambda(NormalFitSplit(resampled_df))
            if isfinite(lam.a) && isfinite(lam.b) && isfinite(lam.t_cw_in)
                push!(a_samples, lam.a)
                push!(b_samples, lam.b)
                push!(t_cw_in_samples, lam.t_cw_in)
            end
        catch e
            if !(e isa ErrorException)
                rethrow(e)
            end
            # identify_lambdaが明示的エラーを発した標本(例: a==0.0で退化した説明変数)を
            # スキップする(上記docstring「数値的頑健性」参照)。
        end
    end

    if length(a_samples) < 2
        error("bootstrap_lambda_uncertainty: 有効なブートストラップ標本が不足しています " *
              "(有効標本数=$(length(a_samples)), n_resamples=$n_resamples)")
    end

    alpha = 1.0 - confidence
    lo_q = alpha / 2.0
    hi_q = 1.0 - alpha / 2.0

    a_ci = (quantile(a_samples, lo_q), quantile(a_samples, hi_q))
    b_ci = (quantile(b_samples, lo_q), quantile(b_samples, hi_q))
    t_cw_in_ci = (quantile(t_cw_in_samples, lo_q), quantile(t_cw_in_samples, hi_q))

    return LambdaUncertainty(a_ci, b_ci, t_cw_in_ci)
end

"""
    check_holdout_stability(lam::ReactorCwLambda, uncertainty::LambdaUncertainty,
                             df_holdout::DataFrame)::Bool

Requirement 3.2: holdout部分集合(`split_normal_data`の第2戻り値、`LambdaIdentifier`の
同定には使われていないデータ)で\$\\lambda\$を再同定し、`bootstrap_lambda_uncertainty`が
fit部分集合から算出した信頼区間(`uncertainty`)内に収まるかを判定する。

Requirement 3.3: a, b, T_cw,inのいずれか1つでも信頼区間外であれば`false`を返す
(呼び出し元は\$\\lambda\$を不安定とみなし、検知用途に採用してはならない、design.md
LambdaValidator「Postconditions」参照)。すべてが信頼区間内であれば`true`を返す。

`df_holdout`は`split_normal_data`の第2戻り値そのままの生`DataFrame`(design.mdの
リテラルシグネチャ、およびタスク2.1でholdout側がラップされない設計と整合)であり、
本関数内部で`NormalFitSplit`にラップして`identify_lambda`に渡す(「holdout部分集合で
\$\\lambda\$を再同定する」という責務を本関数が担う)。

`lam`(fit時に凍結された\$\\lambda\$)は、design.mdのService Interface契約を満たすために
受理するが、安定性判定自体はholdoutでの再同定結果と`uncertainty`の比較のみに基づく
(`uncertainty`自体がfit時の`lam`と同じfit部分集合から計算されているため、`lam`の値は
暗黙にこの比較へ反映されている)。

- Preconditions: `uncertainty`は同じfit部分集合に対する`bootstrap_lambda_uncertainty`の出力
- Postconditions: `false`が返る場合、呼び出し元は\$\\lambda\$を検知用途に採用してはならない
"""
function check_holdout_stability(lam::ReactorCwLambda, uncertainty::LambdaUncertainty,
                                  df_holdout::DataFrame)::Bool
    lam_holdout = identify_lambda(NormalFitSplit(df_holdout))

    a_in_range = uncertainty.a_ci[1] <= lam_holdout.a <= uncertainty.a_ci[2]
    b_in_range = uncertainty.b_ci[1] <= lam_holdout.b <= uncertainty.b_ci[2]
    t_cw_in_in_range = uncertainty.t_cw_in_ci[1] <= lam_holdout.t_cw_in <= uncertainty.t_cw_in_ci[2]

    return a_in_range && b_in_range && t_cw_in_in_range
end

# ============================================================================
# MeanShiftDetector (design.md「検知」> MeanShiftDetector参照)
#
# 凍結lambdaのもとで残差 |y - (a*x1 + b*x2)| を継続算出し(Requirement 4.1)、
# 正常検証データ(保留部分集合)のみから決定したしきい値(Requirement 4.3)を
# 超えた場合に検知フラグを発する(Requirement 4.2)。IDV(4)に対する評価では、
# FaultTiming.FAULT_INJECTION_SAMPLE(=21)を基準とした検知遅れとFDRを報告し
# (Requirement 4.4)、正常検証データに対する誤報率(FAR)を検知指標とは区別して
# 報告する(Requirement 4.5)。
#
# Requirements: 4.1, 4.2, 4.3, 4.4, 4.5
# Depends: LambdaValidator (タスク2.2: 検証済みlambda), FaultTiming (タスク1.2:
#          FAULT_INJECTION_SAMPLE)
# ============================================================================

"""
    DetectionMetrics

`evaluate_fault_detection`(MeanShiftDetector・VarianceShiftDetector共通)の戻り値。
IDVごとのFDR・ADDと、全体のFARを保持するイミュータブルな値型
(design.md MeanShiftDetector「State Management」のリテラル定義と一致)。

# フィールド
- `fdr_by_idv::Dict{Int,Float64}`: IDVごとの故障検知率(%)。対象IDVのデータが
  `df_faulty`に1件も存在しない場合は、計算不能であることを明示するため`NaN`を保持する
  (design.md Error Categories「評価不能」→当該IDVの`DetectionMetrics`に欠損を明示)。
- `add_by_idv::Dict{Int,Float64}`: IDVごとの平均検知遅れ(サンプル数)。
  `FaultTiming.FAULT_INJECTION_SAMPLE`からの相対値(Requirement 8.2)。
  当該IDVのいずれのランでも検知がなかった場合は`-1.0`(`VerificationHarness.evaluate_fdi`の
  既存規約`isempty(idv_delays[idv]) ? -1.0 : mean(...)`を踏襲した「検知なし」センチネル)。
  データが存在しない場合(評価不能)は`fdr_by_idv`と同様に`NaN`。
- `far_pct::Float64`: 正常検証データ(`split_normal_data`の保留部分集合、`evaluate_fault_detection`の
  `df_normal_holdout`キーワード引数)に対する誤報率(%)。現行のmax×margin閾値決定方式のもとでは
  構造的に`0.0`になる(`evaluate_fault_detection`のdocstring「開示すべき限界」参照)。
"""
struct DetectionMetrics
    fdr_by_idv::Dict{Int,Float64}
    add_by_idv::Dict{Int,Float64}
    far_pct::Float64
end

"""
    calibrate_threshold(lam, df_normal_holdout; margin=1.25)::Float64

Requirement 4.3: 検知しきい値を、異常データを一切参照せず正常の検証データ
(`split_normal_data`の保留部分集合)のみから決定する。

\$\$\\text{threshold} = \\max_i \\left| y_i - (a\\,x_{1,i} + b\\,x_{2,i}) \\right| \\times \\text{margin}\$\$

`src/VerificationHarness.jl`の既存規約(`threshold = maximum(model_resid_fit) * 1.25`、
本ファイル137行目付近のコメント参照)と同じ「残差最大×1.25」という暫定規約
(research.md「残差『第2の統計量』の設計」及びタスク3.1本文「FIT残差最大×1.25」参照)を
踏襲する。ただし本関数は、design.mdのリテラルシグネチャが唯一のデータ引数として
`df_normal_holdout`しか受け取らない(`VerificationHarness.jl`が`model_resid_fit`
(同定に使ったfit部分集合の残差)を基準にしていたのとは異なり、本関数は常に
holdout部分集合の残差を基準にする)という点で、`VerificationHarness.jl`の規約を
一部拡張している。この拡張はRequirement 4.3の「正常の検証データのみから決定する」
という字面と、design.mdの関数シグネチャ(異常データを渡す手段自体が存在しない)の
両方に文字通り合致させるための意図的な選択である。

- Preconditions: `df_normal_holdout`は`split_normal_data`の保留部分集合(またはそれに
  相当する、異常データを含まない正常運転データ)
- Postconditions: 返り値は常に正(`margin > 0`かつ残差は非負のため)
- Invariants: 本関数は異常データを受け取る手段を持たない(関数シグネチャに
  `df_normal_holdout::DataFrame`以外のデータ引数が存在しない)。さらに、
  `df_normal_holdout`に`faultNumber`列が存在し、かつ0以外の値を含む場合は、
  呼び出し側の誤り(異常データを誤って渡した)を早期に検出するため明示的エラーで
  停止する(`docs/dataset_spec.md`で確認済みの事実: 正常データの`faultNumber`は
  常に0であり、異常データのみが0以外の値を持つ)。
"""
function calibrate_threshold(lam::ReactorCwLambda, df_normal_holdout::DataFrame;
                              margin::Float64 = 1.25)::Float64
    if margin <= 0.0
        error("calibrate_threshold: marginは正でなければなりません (margin=$margin)")
    end
    if hasproperty(df_normal_holdout, :faultNumber) && any(df_normal_holdout.faultNumber .!= 0)
        error("calibrate_threshold: df_normal_holdoutに異常データ(faultNumber != 0の行)が" *
              "含まれています。Requirement 4.3は閾値決定に異常データを参照しないことを要求します。")
    end

    feats = build_design_matrix(df_normal_holdout)
    if isempty(feats.y)
        error("calibrate_threshold: df_normal_holdoutに行がありません")
    end

    resid = abs.(feats.y .- (lam.a .* feats.x1 .+ lam.b .* feats.x2))
    return maximum(resid) * margin
end

"""
    detect_mean_shift(lam, df, threshold)::Vector{Bool}

Requirement 4.1: 凍結された`lam`のもとで、`df`の各行について残差
\$|y - (a\\,x_1 + b\\,x_2)|\$ を継続算出する。
Requirement 4.2: 残差の大きさが`threshold`を**超えた**(厳密不等号、
`VerificationHarness.jl`の`resid[t] > threshold`と同じ慣用句)場合に検知フラグ`true`を
発する。

戻り値は`df`と同じ行順序・同じ長さの`Vector{Bool}`であり、行ごとに独立な判定である
(本関数自体はラン境界をまたぐ時間差分を取らないため、`respects_run_boundary`は
不要。`build_design_matrix`と同じ代数的・行単位の残差計算であることに留意)。

- Preconditions: `df`に`build_design_matrix`が要求する列(既定`:xmeas_9`, `:xmeas_21`,
  `:xmv_10`)が存在する
- Postconditions: `length(result) == nrow(df)`
"""
function detect_mean_shift(lam::ReactorCwLambda, df::DataFrame, threshold::Float64)::Vector{Bool}
    feats = build_design_matrix(df)
    resid = abs.(feats.y .- (lam.a .* feats.x1 .+ lam.b .* feats.x2))
    return resid .> threshold
end

"""
    evaluate_fault_detection(lam, threshold, df_faulty, target_idvs; df_normal_holdout)::DetectionMetrics

Requirement 4.4: `target_idvs`の各IDVについて、故障検知率(FDR)と、
`FaultTiming.FAULT_INJECTION_SAMPLE`(=21)を基準とした検知遅れ(ADD)を算出する。
Requirement 4.5: 正常の検証データに対する誤報率(FAR)を、検知指標とは区別して
(`DetectionMetrics`の別フィールドとして)報告する。
Requirement 8.2: 検知遅れは各ランの先頭からではなく、`FAULT_INJECTION_SAMPLE`から
計測する。`df_faulty`の`faultNumber`列はラン全体に付与された定数ラベルであり
投入時刻そのものではない(`docs/dataset_spec.md`)ため、`VerificationHarness.jl`の
既知バグ(`findfirst(v -> v > 0, fault_col)`が常にサンプル1を返す)を再導入しない。
Requirement 8.3: ラン境界をまたいで残差・検知を計算しない(`faultNumber`・
`simulationRun`でグループ化してからラン内でのみサンプル順に処理する)。

# FARの算出方法に関する設計判断(レビュー指摘への修正、CONCERNSに記録)
design.md MeanShiftDetector「Responsibilities & Constraints」は、Requirement 4.3の
しきい値決定について「正常検証データ(保留部分集合)のみから決定する」と明記しており、
Requirement 4.5が再利用する「正常の検証データ」という字句も、design.mdの確立済みの
語法に従えば同じ`split_normal_data`の保留部分集合(holdout)を指す。以前の実装は
`df_faulty`の投入前ウィンドウ(`sample < FAULT_INJECTION_SAMPLE`)という、holdoutとは
別のデータソースからFARを計算していたが、これはdesign.mdが確立した用語を無断で
読み替えるものであり、レビューで指摘された。

本実装はタスク2.1/2.2(`identify_lambda(df_fit::NormalFitSplit)`がdesign.mdの
リテラルな`identify_lambda(df_fit::DataFrame)`を拡張した前例)と同じ考え方で、
`evaluate_fault_detection`のシグネチャにキーワード引数`df_normal_holdout::DataFrame`
(`calibrate_threshold`が受け取るholdoutと同一のデータ)を追加し、`far_pct`を
`detect_mean_shift(lam, df_normal_holdout, threshold)`の結果から直接計算する。
これにより、design.mdが「正常検証データ」と呼ぶものを文字通りholdoutとして扱い、
Requirement 4.5を字面どおりに満たす。

## 開示すべき限界: holdoutベースのFARは、現行の閾値決定方式のもとでは構造的に0%になる
`calibrate_threshold`は`threshold = max(|resid_holdout|) * margin`(`margin > 1`)として
しきい値を定義し、`detect_mean_shift`は厳密不等号`resid > threshold`で検知を判定する。
したがって、`threshold`が`df_normal_holdout`自身の残差最大値にmarginを掛けた値である
以上、`df_normal_holdout`のどの行の残差も自分自身の最大値×margin(`margin>1`)を
超えることは数学的にあり得ず、`far_pct`は常に`0.0`になる。これはバグではなく、
現行のmax×margin閾値決定方式(research.md参照、`fdi-evaluation-foundation`での
パーセンタイル方式再検討の対象)の必然的な性質である。この0%という値は「誤報が
実際に発生しなかった」ことの検証済みの証拠ではなく、「このしきい値決定方式のもとでは
定義上誤報が発生しえない」という解釈上の限界として読むべきである
(CLAUDE.md §8/Requirement 9: 学術的誠実さと限界の記録)。異常データを参照しない
という制約(Requirement 2.3/4.3)を保ったまま、より情報量のあるFAR値を得るには、
`fdi-evaluation-foundation`が確立するパーセンタイル等の別の閾値決定方針が必要になる
(design.md「Revalidation Triggers」参照)。

- Preconditions: `threshold`は`calibrate_threshold`の出力(異常データを一切
  参照していない)。`df_normal_holdout`は`calibrate_threshold`に渡したholdoutと
  同一(またはそれに相当する、異常データを含まない正常運転データ)であることを
  想定する。`calibrate_threshold`と同じ防御的チェック(`faultNumber`列が存在し
  0以外の値を含む場合は明示的エラーで停止)を行う
- Postconditions: `target_idvs`のいずれかが`df_faulty`に1件も存在しない場合、
  当該IDVの`fdr_by_idv`・`add_by_idv`は`NaN`(評価不能の明示、design.md Error
  Categories参照)。`add_by_idv`の値は`FaultTiming.FAULT_INJECTION_SAMPLE`からの
  相対値である。`far_pct`は`df_normal_holdout`のみから計算され、`df_faulty`の
  内容(投入前ウィンドウを含む)には一切依存しない
"""
function evaluate_fault_detection(lam::ReactorCwLambda, threshold::Float64, df_faulty::DataFrame,
                                   target_idvs::Vector{Int};
                                   df_normal_holdout::DataFrame)::DetectionMetrics
    for col in (:faultNumber, :simulationRun, :sample)
        if !hasproperty(df_faulty, col)
            error("evaluate_fault_detection: df_faultyに必要な列 '$(col)' が存在しません")
        end
    end
    if hasproperty(df_normal_holdout, :faultNumber) && any(df_normal_holdout.faultNumber .!= 0)
        error("evaluate_fault_detection: df_normal_holdoutに異常データ(faultNumber != 0の行)が" *
              "含まれています。Requirement 4.5は正常の検証データ(holdout)のみからFARを" *
              "決定することを要求します。")
    end

    df_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])

    fdr_by_idv = Dict{Int,Float64}()
    add_by_idv = Dict{Int,Float64}()

    for idv in target_idvs
        df_idv = filter(row -> row.faultNumber == idv, df_sorted)

        if nrow(df_idv) == 0
            fdr_by_idv[idv] = NaN
            add_by_idv[idv] = NaN
            continue
        end

        total_runs = 0
        detected_runs = 0
        delays = Float64[]

        for g in groupby(df_idv, :simulationRun)
            total_runs += 1
            g_df = DataFrame(g)  # SubDataFrameをbuild_design_matrix/detect_mean_shiftに
                                  # 渡せる具体的なDataFrameへ変換する(型シグネチャの整合)
            samples = g_df.sample
            flags = detect_mean_shift(lam, g_df, threshold)

            post_idx = findall(s -> s >= FAULT_INJECTION_SAMPLE, samples)
            detect_pos = isempty(post_idx) ? nothing : findfirst(identity, flags[post_idx])
            if detect_pos !== nothing
                detect_sample = samples[post_idx[detect_pos]]
                push!(delays, Float64(detect_sample - FAULT_INJECTION_SAMPLE))
                detected_runs += 1
            end
        end

        fdr_by_idv[idv] = detected_runs / total_runs * 100.0
        add_by_idv[idv] = isempty(delays) ? -1.0 : mean(delays)
    end

    far_flags = detect_mean_shift(lam, df_normal_holdout, threshold)
    far_pct = isempty(far_flags) ? NaN : (count(identity, far_flags) / length(far_flags) * 100.0)

    return DetectionMetrics(fdr_by_idv, add_by_idv, far_pct)
end

# ============================================================================
# VarianceShiftDetector (design.md「検知」> VarianceShiftDetector参照)
#
# 凍結lambdaのもとで残差系列に対する窓内(移動)標準偏差を継続算出し(Requirement 5.1)、
# 正常検証データ(保留部分集合)のみから決定したしきい値(Requirement 5.3)を超えた場合に、
# 平均ベースの検知経路(MeanShiftDetector)が発火しているかどうかに関わらず独立に
# 検知フラグを発する(Requirement 5.2)。IDV(11)・IDV(14)に対する評価では、
# FaultTiming.FAULT_INJECTION_SAMPLE(=21)を基準とした検知遅れとFDRを、平均ベースの
# 検知結果とは区別して報告する(Requirement 5.4)。
#
# 命名衝突に関する設計判断(タスク本文の指示に基づく、タスク3.2):
# design.md VarianceShiftDetector「Service Interface」は、evaluate_fault_detectionという
# 関数名をMeanShiftDetector(タスク3.1)と文字通り再利用している。しかし両者のシグネチャは
#   MeanShiftDetector:     evaluate_fault_detection(lam, threshold, df_faulty, target_idvs; df_normal_holdout)      (位置引数4個)
#   VarianceShiftDetector: evaluate_fault_detection(lam, window, threshold, df_faulty, target_idvs; df_normal_holdout) (位置引数5個)
# であり、位置引数の個数そのものが異なるため、Juliaの多重ディスパッチにより型・個数の両面で
# 曖昧性なく区別できる(design.md VarianceShiftDetector「Postconditions」の「戻り値は
# MeanShiftDetector.DetectionMetricsと同じ型で、別経路の結果として区別可能」という記述とも
# 整合する、意図された多重ディスパッチによる名前再利用である)。したがってタスク3.1の
# 既存メソッドをリネーム・上書きせず、本タスクでは第2のメソッドとして追加する。
#
# Requirements: 5.1, 5.2, 5.3, 5.4
# Depends: LambdaValidator (タスク2.2: 検証済みlambda), FaultTiming (タスク1.2:
#          FAULT_INJECTION_SAMPLE, respects_run_boundary)
# ============================================================================

"""
    _signed_residual(lam, df)::Vector{Float64}

`y - (a*x1 + b*x2)`(符号付き残差)を計算する内部ヘルパー。MeanShiftDetectorの
`detect_mean_shift`が使う絶対値残差`|y - (a*x1+b*x2)|`とは異なり、本ヘルパーは
符号を保持したまま返す。

分散(窓内標準偏差)は系列の「ばらつき」を測る統計量であり、絶対値を取ってから
標準偏差を計算すると(整流によって)値の変動性そのものではなく平均シフト型の
挙動と混同されてしまう(design.md VarianceShiftDetector Intent「残差の時間窓内
変動性」の字義どおりの実装、Requirement 5.1がMeanShiftDetectorの平均ベース検知と
明確に独立であることを要求することとも整合する)。したがってVarianceShiftDetectorの
各関数はこの符号付き残差を一貫して使用する。
"""
function _signed_residual(lam::ReactorCwLambda, df::DataFrame)::Vector{Float64}
    feats = build_design_matrix(df)
    return feats.y .- (lam.a .* feats.x1 .+ lam.b .* feats.x2)
end

"""
    _variance_flags_for_run(resid, window, threshold)::Vector{Bool}

単一ラン内の符号付き残差系列`resid`(ラン境界をまたがないことが呼び出し元の責務)について、
各位置`i`での窓内(trailing window、`resid[i-window+1:i]`)標準偏差が`threshold`を
**超えた**(厳密不等号、`detect_mean_shift`と同じ慣用句)場合に`true`を返す。

窓を構成するのに十分な過去サンプルがない先頭`window-1`個の位置は、判定不能として
`false`を返す(単一サンプル・短すぎる窓によるノイズ由来の誤検知を避けるための
意図的な選択。research.mdのRisks「窓長が不適切な場合の挙動」参照)。
"""
function _variance_flags_for_run(resid::Vector{Float64}, window::Int, threshold::Float64)::Vector{Bool}
    m = length(resid)
    flags = fill(false, m)
    for i in window:m
        s = std(view(resid, (i - window + 1):i))
        if s > threshold
            flags[i] = true
        end
    end
    return flags
end

"""
    calibrate_variance_threshold(lam, df_normal_holdout; window, margin=1.25)::Float64

Requirement 5.3: 分散変化型検知の第2の統計量(窓内標準偏差)のしきい値を、異常データを
一切参照せず正常の検証データ(`split_normal_data`の保留部分集合)のみから決定する。

\$\$\\text{threshold}_{\\mathrm{var}} = \\max_{k,\\,i\\ge\\text{window}} \\operatorname{std}\\!\\left(r_k[i-\\text{window}+1{:}i]\\right) \\times \\text{margin}\$\$

ここで\$r_k\$はラン\$k\$内での符号付き残差系列(`_signed_residual`)であり、最大は
`df_normal_holdout`に含まれる全ランの全窓内標準偏差についてとる。`calibrate_threshold`
(タスク3.1、MeanShiftDetector)と同じ「保留部分集合の統計量の最大値×margin」という
暫定規約(research.md「残差『第2の統計量』の設計」参照)を、窓内標準偏差という
別の統計量に適用したものである。

窓はラン境界をまたがない(`respects_run_boundary`でソートしたうえで`simulationRun`ごとに
独立して窓を構成する、Requirement 8.3)。

- Preconditions: `df_normal_holdout`は`split_normal_data`の保留部分集合(またはそれに
  相当する、異常データを含まない正常運転データ)で、`simulationRun`・`sample`列を持つ。
  `window`はサンプル単位の正の整数(design.md Preconditions)
- Postconditions: 返り値は常に正(`margin > 0`かつ標準偏差は非負のため)
- Invariants: `calibrate_threshold`と同じ防御的チェック(`faultNumber`列が存在し0以外の
  値を含む場合は明示的エラーで停止、Requirement 5.3の「異常データを参照しない」の
  実装レベルでの保証)を行う。`window < 2`は標準偏差が定義不能(サンプル1点では
  Statistics.stdがNaNを返す退化ケース)なので明示的エラーとする(design.mdの字面上は
  「正の整数」だが、NaNをしきい値として黒子に受理してしまう危険を避けるための、
  タスク3.1の`margin<=0`拒否と同種の意図的な拡張)。
"""
function calibrate_variance_threshold(lam::ReactorCwLambda, df_normal_holdout::DataFrame;
                                       window::Int, margin::Float64 = 1.25)::Float64
    if margin <= 0.0
        error("calibrate_variance_threshold: marginは正でなければなりません (margin=$margin)")
    end
    if window < 2
        error("calibrate_variance_threshold: windowは2以上の整数でなければなりません " *
              "(window=$window)。window=1では窓内標準偏差が定義不能(NaN)です。")
    end
    for col in (:simulationRun, :sample)
        if !hasproperty(df_normal_holdout, col)
            error("calibrate_variance_threshold: df_normal_holdoutに必要な列 '$(col)' が存在しません")
        end
    end
    if hasproperty(df_normal_holdout, :faultNumber) && any(df_normal_holdout.faultNumber .!= 0)
        error("calibrate_variance_threshold: df_normal_holdoutに異常データ(faultNumber != 0の行)が" *
              "含まれています。Requirement 5.3は閾値決定に異常データを参照しないことを要求します。")
    end

    sorted = respects_run_boundary(df_normal_holdout)

    stds = Float64[]
    for g in groupby(sorted, :simulationRun)
        g_df = DataFrame(g)
        r = _signed_residual(lam, g_df)
        m = length(r)
        if m < window
            continue
        end
        for i in window:m
            push!(stds, std(view(r, (i - window + 1):i)))
        end
    end

    if isempty(stds)
        error("calibrate_variance_threshold: window=$(window)サンプルの窓を構成できるrunが" *
              "df_normal_holdoutに存在しません(各runの行数がwindow未満です)")
    end

    return maximum(stds) * margin
end

"""
    detect_variance_shift(lam, df, window, threshold)::Vector{Bool}

Requirement 5.1: 凍結された`lam`のもとで、`df`の各行について窓内(直近`window`サンプル)の
符号付き残差`y - (a\\,x_1 + b\\,x_2)`の標準偏差を継続算出する。
Requirement 5.2: 窓内標準偏差が`threshold`を**超えた**(厳密不等号、`detect_mean_shift`と
同じ慣用句)場合に、独立に検知フラグ`true`を発する。この判定はMeanShiftDetectorの
判定結果を一切参照しない(関数シグネチャ・実装のいずれにも`detect_mean_shift`の
呼び出しや`DetectionMetrics`への依存が存在しない)。
Requirement 8.3: 異なる`simulationRun`をまたいで窓(=標準偏差の計算範囲)を構成しない。
`respects_run_boundary`(タスク1.2、FaultTiming)で`[simulationRun, sample]`順にソートした
うえで、`simulationRun`ごとに独立して窓内標準偏差を計算する。

戻り値は`df`と同じ行数・**同じ行順序**(`df`自身の行順序、ソート後の順序ではない)の
`Vector{Bool}`である。内部で一時的な行インデックス列を付与してから`respects_run_boundary`で
ソートし、ラン単位で窓内標準偏差を計算したのち、その行インデックス列を使って結果を
`df`の元の行順序へ書き戻す。これにより、呼び出し元が`df`を事前にソートしていない場合
(例: 複数ランが`simulationRun`の昇順になっていない場合)でも、`detect_mean_shift`と同じ
「`length(result) == nrow(df)`かつ`result[i]`は`df`の行`i`に対応する」という契約を保つ。

各ラン内で窓を構成するのに十分な過去サンプルがない先頭`window-1`行は`false`になる
(`_variance_flags_for_run`参照)。

- Preconditions: `df`に`build_design_matrix`が要求する列(既定`:xmeas_9`, `:xmeas_21`,
  `:xmv_10`)、および`:simulationRun`・`:sample`列が存在する。`window`は2以上の整数
- Postconditions: `length(result) == nrow(df)`
"""
function detect_variance_shift(lam::ReactorCwLambda, df::DataFrame, window::Int,
                                threshold::Float64)::Vector{Bool}
    for col in (:simulationRun, :sample)
        if !hasproperty(df, col)
            error("detect_variance_shift: dfに必要な列 '$(col)' が存在しません")
        end
    end
    if window < 2
        error("detect_variance_shift: windowは2以上の整数でなければなりません (window=$window)。" *
              "window=1では窓内標準偏差が定義不能(NaN)です。")
    end

    n = nrow(df)
    row_idx_col = :_variance_shift_row_idx
    df_tagged = hcat(df, DataFrame(row_idx_col => collect(1:n)))
    sorted = respects_run_boundary(df_tagged)

    result = fill(false, n)
    for g in groupby(sorted, :simulationRun)
        g_df = DataFrame(g)
        r = _signed_residual(lam, g_df)
        flags_run = _variance_flags_for_run(r, window, threshold)
        orig_idxs = g_df[!, row_idx_col]
        for (pos, orig_i) in enumerate(orig_idxs)
            result[orig_i] = flags_run[pos]
        end
    end

    return result
end

"""
    evaluate_fault_detection(lam, window, threshold, df_faulty, target_idvs; df_normal_holdout)::DetectionMetrics

VarianceShiftDetector版の`evaluate_fault_detection`(design.md VarianceShiftDetector
Service Interface参照)。MeanShiftDetector版(タスク3.1、位置引数4個
`evaluate_fault_detection(lam, threshold, df_faulty, target_idvs; df_normal_holdout)`)とは
異なり、本メソッドは位置引数5個(`lam, window, threshold, df_faulty, target_idvs`)を
取るため、Juliaの多重ディスパッチにより曖昧性なく区別される(本ファイル上部の
「命名衝突に関する設計判断」参照)。

Requirement 5.4: `target_idvs`(典型的には`[11, 14]`)の各IDVについて、分散ベースの
故障検知率(FDR)と、`FaultTiming.FAULT_INJECTION_SAMPLE`(=21)を基準とした検知遅れ(ADD)を、
平均ベースの検知結果(MeanShiftDetector版`evaluate_fault_detection`の戻り値)とは別個の
`DetectionMetrics`インスタンスとして算出する。正常の検証データに対する誤報率(FAR)も
同様に、`detect_variance_shift`に基づいて独立に算出する。
Requirement 8.2: 検知遅れは各ランの先頭からではなく、`FAULT_INJECTION_SAMPLE`から計測する。
Requirement 8.3: ラン境界をまたいで窓内標準偏差・検知を計算しない(`faultNumber`・
`simulationRun`でグループ化してからラン内でのみサンプル順に処理する。`detect_variance_shift`
自身もラン単位で`respects_run_boundary`を適用するため、二重に安全である)。

本実装は、MeanShiftDetector版`evaluate_fault_detection`(タスク3.1)と全く同じ
制御フロー(IDVごとにラン単位でグループ化し、投入時刻以降で最初に発火したサンプルから
ADDを計算し、holdoutに対する`detect_variance_shift`の発火率をFARとする)を、
`detect_mean_shift`の代わりに`detect_variance_shift`(window付き)に置き換えて適用した
ものである。

## 開示すべき限界: holdoutベースのFARは、現行の閾値決定方式のもとでは構造的に0%になる
`calibrate_variance_threshold`は`threshold = max(窓内標準偏差_holdout) * margin`
(`margin > 1`)としてしきい値を定義し、`detect_variance_shift`は厳密不等号
`std > threshold`で検知を判定する。したがって、同じ`df_normal_holdout`を本関数の
キーワード引数`df_normal_holdout`に渡した場合、`far_pct`は構造的に`0.0`になる
(MeanShiftDetector版`evaluate_fault_detection`のdocstring「開示すべき限界」と全く同じ
数学的理由による、現行のmax×margin閾値決定方式の必然的な性質であり、バグではない。
CLAUDE.md §8/Requirement 9: 学術的誠実さと限界の記録)。

- Preconditions: `threshold`は`calibrate_variance_threshold`の出力(異常データを一切
  参照していない)。`df_normal_holdout`は`calibrate_variance_threshold`に渡したholdoutと
  同一(またはそれに相当する、異常データを含まない正常運転データ)であることを想定する。
  `calibrate_variance_threshold`と同じ防御的チェック(`faultNumber`列が存在し0以外の
  値を含む場合は明示的エラーで停止)を行う
- Postconditions: `target_idvs`のいずれかが`df_faulty`に1件も存在しない場合、
  当該IDVの`fdr_by_idv`・`add_by_idv`は`NaN`(評価不能の明示、design.md Error
  Categories参照)。`add_by_idv`の値は`FaultTiming.FAULT_INJECTION_SAMPLE`からの
  相対値である。`far_pct`は`df_normal_holdout`のみから計算され、`df_faulty`の
  内容には一切依存しない。戻り値はMeanShiftDetector版と同じ`DetectionMetrics`型だが、
  常に別個のインスタンスであり、両者の値を混同しない(design.md VarianceShiftDetector
  「Postconditions」)
"""
function evaluate_fault_detection(lam::ReactorCwLambda, window::Int, threshold::Float64,
                                   df_faulty::DataFrame, target_idvs::Vector{Int};
                                   df_normal_holdout::DataFrame)::DetectionMetrics
    for col in (:faultNumber, :simulationRun, :sample)
        if !hasproperty(df_faulty, col)
            error("evaluate_fault_detection (VarianceShiftDetector): df_faultyに必要な列 '$(col)' " *
                  "が存在しません")
        end
    end
    if window < 2
        error("evaluate_fault_detection (VarianceShiftDetector): windowは2以上の整数でなければ" *
              "なりません (window=$window)")
    end
    if hasproperty(df_normal_holdout, :faultNumber) && any(df_normal_holdout.faultNumber .!= 0)
        error("evaluate_fault_detection (VarianceShiftDetector): df_normal_holdoutに異常データ" *
              "(faultNumber != 0の行)が含まれています。Requirement 5.4は正常の検証データ(holdout)" *
              "のみからFARを決定することを要求します。")
    end

    df_sorted = sort(df_faulty, [:faultNumber, :simulationRun, :sample])

    fdr_by_idv = Dict{Int,Float64}()
    add_by_idv = Dict{Int,Float64}()

    for idv in target_idvs
        df_idv = filter(row -> row.faultNumber == idv, df_sorted)

        if nrow(df_idv) == 0
            fdr_by_idv[idv] = NaN
            add_by_idv[idv] = NaN
            continue
        end

        total_runs = 0
        detected_runs = 0
        delays = Float64[]

        for g in groupby(df_idv, :simulationRun)
            total_runs += 1
            g_df = DataFrame(g)  # SubDataFrameをbuild_design_matrix/detect_variance_shiftに
                                  # 渡せる具体的なDataFrameへ変換する(型シグネチャの整合、
                                  # タスク3.1のevaluate_fault_detectionと同じ慣用句)
            samples = g_df.sample
            flags = detect_variance_shift(lam, g_df, window, threshold)

            post_idx = findall(s -> s >= FAULT_INJECTION_SAMPLE, samples)
            detect_pos = isempty(post_idx) ? nothing : findfirst(identity, flags[post_idx])
            if detect_pos !== nothing
                detect_sample = samples[post_idx[detect_pos]]
                push!(delays, Float64(detect_sample - FAULT_INJECTION_SAMPLE))
                detected_runs += 1
            end
        end

        fdr_by_idv[idv] = detected_runs / total_runs * 100.0
        add_by_idv[idv] = isempty(delays) ? -1.0 : mean(delays)
    end

    far_flags = detect_variance_shift(lam, df_normal_holdout, window, threshold)
    far_pct = isempty(far_flags) ? NaN : (count(identity, far_flags) / length(far_flags) * 100.0)

    return DetectionMetrics(fdr_by_idv, add_by_idv, far_pct)
end

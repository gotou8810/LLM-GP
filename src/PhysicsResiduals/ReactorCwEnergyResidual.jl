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

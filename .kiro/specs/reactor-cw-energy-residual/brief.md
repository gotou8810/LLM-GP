# Brief: reactor-cw-energy-residual

反応器冷却水側のエネルギー収支残差による異常検知。Phase 2（物理収支残差ベース FDI）の最初の spec。

## Problem

Phase 1 の LLM-GP 記号回帰は 2 つの理由で行き詰まった（CLAUDE.md §0）。

1. LLM がプロンプトで与えた物理的制約に従わないことがある
2. **閉ループ制御の影響で、プロセス値（PV）だけで書いた式は物理法則に従わないように見える**

(2) は観測で定量的に裏付けられている。IDV(4)（反応器冷却水入口温度のステップ）の投入後、

| 変数 | 正常からの平均シフト（z） |
|---|:-:|
| XMEAS(9) $T_r$ | −0.00 |
| XMEAS(21) $T_{cw,out}$ | −0.00 |
| **XMV(10) 弁開度** | **+6.97** |

PV は完全に不動で、外乱の影響は操作量側にしか現れない。**PV だけの式では IDV(4) を原理的に検知できない。** 実際、Phase 1 の XMEAS(7) モデル（XMV を一切含まない）は IDV(4) の FDR が 0% だった。

## Current State

- 既存の「有効」判定モデルは反応器圧力 XMEAS(7) の 1 件のみ（Skill Score = 0.0105、差分 $R^2_\Delta$ = 2.07%）。IDV(4)/(11)/(14) はいずれも FDR 0〜0.6% で検知対象外。
- 既存の XMEAS(9)（反応器温度）モデルは 4 回連続で撤回済み。撤回理由の 1 つは「`xmv_10`（冷却水弁）は閉ループ交絡の疑い」であり、**これは CLAUDE.md §2 で逆転した論法に依拠している**。
- 現行コードは XMV を機械的に排除する実装になっている（`preprocessing.py` の `filter_reactive_variables()` が CCF 比率 2.0 以上を自動除外、`prompt_manager.py` が除外理由をハード禁止ルールとしてプロンプトに注入）。
- $\lambda$（未知パラメータ）という概念の実装は存在しない。正常データのみでの同定 → 凍結 → 診断時のみ再推定という二相構成もない。
- 評価基盤には FDR/FAR/ADD が実装済み（`VerificationHarness.jl`）だが、PCA ベースラインと 99 パーセンタイル閾値は未実装。
- **故障投入時刻の扱いにバグがある**（下記 Scope 参照）。

## Desired Outcome

- 反応器冷却水のエネルギー収支残差が、正常データ上で $\lambda$ を同定でき、物理的に妥当な $\lambda$ の値が得られている
- $\lambda$ を正常時の値に凍結した状態で、IDV(4)/(11)/(14) に対して残差スパイクが発生し、誤報を抑えた検知ができている
- 操作量 XMV(10) を外した比較式より明確に優れていることが示されている（CLAUDE.md §7 の必須比較実験）
- $\lambda$ をスライディングウィンドウで再推定したとき、どの $\lambda$ がどれだけ動いたかで故障を診断できる
- 検知できない故障については、その理由とともに正直に記録されている

## Approach

CLAUDE.md §4(b) が指定する残差式を、**$\lambda$ について線形な 2 パラメータ回帰**に変形して同定する。

### 残差式（CLAUDE.md §4(b)）

$$r = k\,u_{10}\,(T_{cw,out} - T_{cw,in}) - UA\,(T_r - T_{cw,out}) \approx 0$$

- $T_r$ = XMEAS(9)、$T_{cw,out}$ = XMEAS(21)、$u_{10}$ = XMV(10)
- $\lambda = \{k,\ UA,\ T_{cw,in}\}$（$T_{cw,in}$ は非測定）

### スケール不定性の解消と同定可能性（分析結果）

上式は全体を任意の定数倍しても同じ式なので、$k$ と $UA$ は**個別には同定できない**。CLAUDE.md §1 の「1つの変数について解いた形で扱う」に従い、両辺を $UA$ で割って $(T_r - T_{cw,out})$ について解くと:

$$T_r - T_{cw,out} = \underbrace{\frac{k}{UA}}_{a}\,(u_{10}\,T_{cw,out}) + \underbrace{\left(-\frac{k}{UA}T_{cw,in}\right)}_{b}\,u_{10}$$

- **目的変数**: $y = T_r - T_{cw,out}$ = XMEAS(9) − XMEAS(21)（正常データ平均 +25.8 °C）
- **説明変数**: $x_1 = u_{10}\,T_{cw,out}$、$x_2 = u_{10}$
- **同定する $\lambda$**: $a = k/UA$、$b = -a\,T_{cw,in}$ → $T_{cw,in} = -b/a$

**同定可能性の結論**: $k/UA$（比）と $T_{cw,in}$ は同定可能。$k$ と $UA$ は**個別には同定不可能**（この制約は正直に記録する）。

**符号・値域の事前制約**（CLAUDE.md §3・Method A の符号事前宣言）:
- $a > 0$（$k > 0$, $UA > 0$ より）
- $b < 0$（$a > 0$, $T_{cw,in} > 0$ より）
- $T_{cw,in} = -b/a$ は $T_{cw,out}$（94.6 °C）より低く、冷却水として物理的に妥当な範囲に入ること

**$\lambda$ について線形なので、既存の `linear_fit.jl` の厳密 OLS 経路がそのまま使える**（重ね合わせの原理による線形性の数値検証 → `G \ y`）。差分進化法や NN は不要。

### 準定常近似について

上式は時間微分を含まない代数式である。CLAUDE.md §1 は「サンプリング間隔（3分）より速い現象は、準定常の代数式として扱ってよい」と許可しているが、**冷却水側の熱容量による時定数が 3 分に対して十分速いかは経験的に確認すべき**。確認方法と、必要なら $d T_{cw,out}/dt$ 項を追加する判断は requirements/design で扱う。

### 検知設計上の注意（分散変化型の故障）

ラン内標準偏差の比（故障時/正常時）:

| IDV | XMEAS(9) | XMEAS(21) | XMV(10) | シグネチャの所在 |
|:-:|:-:|:-:|:-:|---|
| 4 | 1.04x | 0.94x | 0.96x | **平均シフト**（分散は不変） |
| 11 | 4.31x | 1.14x | **6.48x** | **分散増大** |
| 14 | **13.43x** | **10.59x** | **13.77x** | **分散の激増** |

→ 3 変数すべてに明確なシグネチャがあるが、**残差の絶対値に対する固定閾値は平均シフト型（IDV4）に有効で、分散変化型（IDV11/14）には窓統計量（移動分散など）の併用が必要になる可能性が高い**。この設計判断を requirements に含める。

### 必須の比較実験（CLAUDE.md §7）

「操作量の項を除いた式で残差が悪化すること」を示す。ただし $u_{10}$ を完全に削除すると式が定数項のみになり退化するため、**$u_{10}$ をその平均値 $\bar{u}$ で固定した PV のみのモデル**と比較する:

$$T_r - T_{cw,out} = c_1\,T_{cw,out} + c_2 \quad (\text{PV のみ、} u_{10} = \bar{u} \text{ 固定})$$

これにより「冷却水流量が一定と仮定した場合」との差分が、操作量を式に入れたことの寄与として定量化される。

## Scope

- **In**:
  - 残差式の実装（上記 2 パラメータ線形形式）
  - 正常データのみ（run ≤ 400）での $\lambda$ 同定、符号・値域の事前宣言と事後照合
  - $\lambda$ の不確かさ評価（ブートストラップ）と別区間（run > 400）での安定性確認
  - $\lambda$ 凍結状態での IDV(4)/(11)/(14) の検知評価（FDR・FAR・検出遅れ）
  - **故障投入時刻の修正**: 投入はサンプル 21（実測確定）であり、既存コードの `findfirst(faultNumber > 0)` は常にサンプル 1 を返すため、既報の ADD は +20 サンプル（60 分）のバイアスを持つ。本 spec の評価では正しい投入時刻を使う
  - 操作量除外アブレーション（PV のみモデルとの比較）
  - 持続性ベースライン比較（Skill Score / MASE）— Phase 1 で確立した必須チェックを維持
  - $\lambda$ のスライディングウィンドウ再推定による診断（どの $\lambda$ がどれだけ動いたか）
  - 検知できなかった故障と、その理由の正直な記録

- **Out**:
  - PCA（$T^2$/SPE）ベースラインの実装 → `fdi-evaluation-foundation`
  - 99 パーセンタイル閾値規約への移行 → `fdi-evaluation-foundation`（本 spec は暫定的に既存ハーネスの規約を使う）
  - 複数残差の統合と故障箇所の帰属性評価 → `fdi-evaluation-foundation`
  - NN / 自動微分（PINN）→ `pinn-residual-integration`
  - LLM への残差構造提案役の実装 → `llm-residual-proposer`
  - 反応側の熱収支（反応熱が組成依存で未知のため、CLAUDE.md §4(b) が明示的に除外）
  - 凝縮器側の同型残差 → `condenser-cw-energy-residual`
  - 反応器圧力モデルの改訂 → `reactor-pressure-model-revision`

## Boundary Candidates

- **残差式の定義**（物理式そのもの、$\lambda$ の物理的意味・符号・値域）
- **$\lambda$ 同定**（正常データのみ、線形 OLS、ブートストラップ、別区間での安定性）
- **検知**（$\lambda$ 凍結、残差系列の算出、閾値判定）
- **診断**（$\lambda$ のスライディングウィンドウ再推定と変化量の報告）
- **評価**（FDR/FAR/ADD、アブレーション、持続性ベースライン比較）— 本 spec では最小限に留め、`fdi-evaluation-foundation` へ一般化する

## Out of Boundary

- 評価指標の一般化・統一（PCA 比較、閾値規約、複数残差の統合）は持たない
- 他装置の残差式は持たない
- LLM による式の提案・探索は持たない（本 spec の式は CLAUDE.md §4(b) で人間が与えたものを使う）
- `teprob.f` から $\lambda$ の数値を読み取ることは禁止（下記 Constraints 参照）

## Upstream / Downstream

- **Upstream**:
  - `tep-data-loader`（既存・完了）— `.RData` のロード
  - `src/VerificationHarness.jl`（既存）— ラン境界を尊重した fit/holdout 分割、FDR/FAR/ADD、MASE、アブレーション
  - `src/NumericalEvaluator/linear_fit.jl`（既存）— 線形性の数値検証と厳密 OLS
  - CLAUDE.md §4(b)（残差式の指定）、§3（$\lambda$ の扱い）、§7（評価哲学）
- **Downstream**:
  - `fdi-evaluation-foundation` — 本 spec で必要性が確定した評価機能を一般化
  - `condenser-cw-energy-residual` — 本 spec で確立したパターンを水平展開
  - `pinn-residual-integration` — 本 spec の残差を PINN の損失項として使う
  - `llm-residual-proposer` — 本 spec を「正解例」として LLM に提案させる対象を広げる
  - `numerical-evaluator`（既存 spec の改訂）— 本 spec で判明した必要機能（生単位モード、$\lambda$ の値域制約）を仕様化

## Existing Spec Touchpoints

- **Extends**: なし（新規の物理モデル spec。既存 4 spec はインフラ寄りで物理方針に踏み込んでいない）
- **Adjacent**:
  - `numerical-evaluator` — `linear_fit.jl` を流用するが、`cli.jl` の **Z-score 正規化は使わない**（$\lambda$ に物理的意味を与えるため生単位で同定する）。この分離を侵さないよう注意
  - `tep-data-loader` — データ仕様（3分間隔、投入サンプル21）のメタデータ化は当該 spec の改訂で行う。本 spec では投入時刻を自分の評価に適用するのみ
  - `evolution-orchestrator` / `llm-interface` — 本 spec では触らない（LLM を使わない）

## Constraints

- **データ**: Rieth et al. 2017 版。正常 500 ラン × 500 サンプル、異常 20 故障 × 500 ラン × 500 サンプル、**サンプリング間隔 3 分、故障投入はサンプル 21**。testing セット（48h・投入 8h）は未取得のため、評価はラン単位分割（run ≤ 400 同定 / run > 400 検証）で行う。
- **変数と単位**（`reference/teprob.f` で確認済み・すべてガイドライン §4(b) の想定どおり）:

| 記号 | 変数 | 正式名称 | 単位 | 正常統計 |
|---|---|---|---|---|
| $T_r$ | XMEAS(9) | Reactor Temperature | Deg C | mean 120.400, std 0.0191 |
| $T_{cw,out}$ | XMEAS(21) | Reactor Cooling Water Outlet Temp | Deg C | mean 94.600, std 0.131 |
| $u_{10}$ | XMV(10) | Reactor Cooling Water Flow（実装は弁開度 %） | % | mean 41.104, std 0.541 |

  $T_r - T_{cw,out} = +25.8$ °C > 0 なので、$UA(T_r - T_{cw,out})$ 項の符号は物理的に正しい。
- **対象 IDV**（`teprob.f` の定義と一致）: IDV(4) Reactor Cooling Water Inlet Temperature **Step**、IDV(11) 同 **Random Variation**、IDV(14) Reactor Cooling Water Valve **Sticking**。CLAUDE.md §8 に従い、これらは**検証前の仮説**として扱う。
- **言語**: Julia（既存資産の再利用。新規依存なし）。実装先は `src/PhysicsResiduals/`。
- **データリーク禁止（CLAUDE.md §3）**: $\lambda$ は正常データのみで同定する。異常データを見て式・ハイパーパラメータ・閾値を選んではならない。
- **`teprob.f` の使用規律**: 本 brief 作成時に `teprob.f` を参照し、CLAUDE.md §4(b) の式が公式シミュレータの冷却水エネルギー収支 ODE（L789-790）の準定常形に厳密に対応することを**構造として**確認した（`FWR = VPOS(10)*VRNG(10)/100.0` が $k$、`QUR = UAR*(TWR-TCR)` が $UA$ 項、`TCWR` が非測定の $T_{cw,in}$）。**$UA$・$VRNG(10)$・$HWR$ 等の数値は意図的に参照していない。$\lambda$ の値を `teprob.f` から読んで埋めることは禁止する。**
  - 診断機能の反証可能な予測: `teprob.f` では IDV(4) が $T_{cw,in}$ への **+5 °C ステップ**として実装されている。$\lambda = \{T_{cw,in}\}$ の再推定は IDV(4) で約 +5 °C のシフトを示すはずであり、これは診断機能の検証に使える（**検知閾値の調整には使わない**）。
- **保全すべき Phase 1 の規律**（steering `variable-modeling-methodology.md`）:
  - 持続性ベースライン比較（MASE / Skill Score、分母は FIT で固定）
  - 「結論を出す形式」— ✅完成 / ❌撤回 / ⏸️検知対象外 を宣言する前に照合表を提示する
  - 自己参照ガード（目的変数自身の過去値の禁止、ラグ付きも含む）
  - ラン境界を尊重した fit/holdout 分割
  - アブレーション（数値的必要性）と符号の理論値照合を独立した 2 軸として両方必須とする
  - 独立審判による説明文と証拠の整合性チェック

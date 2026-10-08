# Roadmap

> **Phase 1（LLM-GP 記号回帰基盤）は完了。Phase 2（物理収支残差ベース FDI）へ移行中（2026-10-06 追加）。**
> Phase 1 の記述は履歴として保全する。現行方針は Phase 2 を参照すること。

---

# Phase 1: LLM-GP 記号回帰基盤（完了・履歴）

## Overview
テネシー・イーストマン・プロセス（TEP）データセットに対して式発見（記号回帰）を行うためのLLM-GPシステムの構築。LLMによる知的探索とJuliaによる厳密な数値評価を組み合わせたハイブリッドアーキテクチャを採用する。

## Approach Decision
- **Chosen**: LLM主導型（プロンプトメイン）＋Julia計算エンジン
- **Why**: LLMが探索戦略や式生成を主導し、Juliaを外部プロセスとして呼び出して適応度評価や係数最適化を行わせることで、LLMの推論能力とJuliaの計算速度の両方の強みを活かすことができるため。
- **Rejected alternatives**: Juliaコード内からLLM APIを直接叩く方式。LLMのコンテキスト管理やプロンプト制御が複雑になる可能性があるため。

## Scope
- **In**: Harvard DataverseからのTEPデータダウンロードと読み込み、差分進化法（DE）による定数最適化、RMSEおよびペナルティに基づく適応度評価、進化戦略（EP）に基づく数式生成とLLMフィードバックループ。
- **Out**: 実稼働プラントへのオンラインデプロイ、汎用的な（TEP以外の）データセットへの完全対応。

## Specs (Phase 1, 完了)
- [x] tep-data-loader -- TEPデータセット（.RData）のダウンロードとJulia DataFrameへの変換. Dependencies: none
- [x] numerical-evaluator -- Juliaによる係数最適化（差分進化法）と適応度（RMSE等）の計算. Dependencies: tep-data-loader
- [x] llm-interface -- プロンプトの構築、LLMへのクエリ送信、LLMからの数式やフィードバックのパース. Dependencies: none
- [x] evolution-orchestrator -- LLMの推論ループを回し、LLMとJuliaエンジンを統合して進化戦略を実行するメインループ. Dependencies: tep-data-loader, numerical-evaluator, llm-interface

## Phase 1 の到達点（移行の出発点として明記）
唯一「有効」と判定された式は反応器圧力 XMEAS(7) の 1 件のみ:
$$\Delta P(t) = 21.99712 \cdot XMEAS(10)_{lag1} - 7.41260$$
- 差分スケール $R^2_\Delta$ = **0.0207**、MASE = 0.9895 (FIT) / 0.9889 (HOLDOUT)、Skill Score = **0.0105 / 0.0111**
- F1 = 0.5234（全20故障）、FAR = 0.00%、Precision = 1.0、Recall = 0.3545
- 7 つの対象のうち XMEAS(9)/(12)/(15) は検知対象外、XMEAS(13) は未解決、XMEAS(16)/(18) は素朴予測以下で撤回

Phase 1 の行き詰まりの原因は CLAUDE.md §0 に記載の 2 点（LLM が物理的制約に従わない／閉ループ制御下では PV だけの式が物理法則に従わないように見える）であり、Phase 2 はこれを構造的に解決する。

---

# Phase 2: 物理収支残差ベース FDI（進行中）

## Overview
変数ごとの記号回帰から、**装置（単位操作）ごとの物理収支残差** $r_k(x, u; \lambda_k) = 0$ による異常検知へ移行する。物理的制約を LLM への指示で担保するのをやめ、式の構造・損失関数・正常データでの検証によって仕組みとして強制する。

第1段階は NN を用いず回帰で未知パラメータ $\lambda$ を同定するのみとし、PINN（NN + 自動微分）は段階的に導入する。最初に扱う式は反応器冷却水のエネルギー収支とする（CLAUDE.md §4(b)）。

## Approach Decision
- **Chosen**: 単一の残差式を縦に貫通させる（vertical slice）。反応器冷却水エネルギー収支残差を最初に end-to-end で成立させ、そこで確立したパターンを他装置・PINN・LLM 提案役へ水平展開する。
- **Why**:
  - 操作量（XMV）を式に含めるという方針転換が本当に機能するかは、1 本の残差式で検証できる。先に評価基盤を網羅的に作っても、方針自体が外れていれば無駄になる。
  - CLAUDE.md §4(b) が式の形・$\lambda$・対象 IDV まで具体的に指定済みであり、最初の 1 本として不確実性が最も小さい。
  - $\lambda$ について線形な残差（後述）なので、既存の `linear_fit.jl` の厳密 OLS がそのまま使える。
- **Rejected alternatives**:
  - *評価基盤を先に全部作る（horizontal first）*: PCA ベースライン・閾値規約・複数残差統合を先に整備する案。残差式が 1 本も成立していない段階で評価基盤の要件を確定できず、手戻りリスクが高いため却下。
  - *全装置の残差を同時に定義する*: 装置間の整合性（物質収支 closure）まで一度に扱う案。CLAUDE.md §2 の「1 つの式で使う変数は 3〜4 個程度」という方針と、どの式が破れたかで故障箇所を特定する設計に反するため却下。
  - *PINN を最初から導入する*: CLAUDE.md §5 が「第1段階は NN を用いず、回帰で $\lambda$ を同定するだけでよい」と明示しているため却下。

## Scope
- **In**: 装置ごとの収支残差の定義と $\lambda$ 同定（正常データのみ）、$\lambda$ 凍結による検知、$\lambda$ 再推定による診断、PCA（$T^2$/SPE）比較ベースライン、FDR/FAR/検出遅れによる評価、操作量除外アブレーション、PINN の段階的導入、LLM-GP の残差構造提案役への再配置。
- **Out**: 実稼働プラントへのオンラインデプロイ、TEP 以外のデータセットへの対応、`teprob.f` の状態空間モデル全体の再構築（全装置を整合性制約付きで同時推定する大規模再設計）。

## Constraints
- **データ**: リポジトリにあるのは `TEP_FaultFree_Training.RData` / `TEP_Faulty_Training.RData` の 2 ファイルのみ（下記「データ仕様」参照）。Rieth et al. 2017 が提供する testing 2 ファイル（48h・故障投入 8h）は**未取得**のため、評価はラン単位分割（run≤400 を同定用、run>400 を検証用）で行う。
- **言語**: $\lambda$ 同定は Julia（既存資産の再利用）、PCA ベースラインは Python（scikit-learn 既導入）、PINN は Python/PyTorch（新規依存）。詳細は「実装方針」参照。
- **環境**: Python 3.10.12 / Julia 1.10.4。`torch` は**未インストール**（PINN 着手時に追加）。
- **規律**: `reference/teprob.f` は盲検発見後の事後照合専用とする（下記「科学的誠実さに関する注意」参照）。

## Boundary Strategy
- **Why this split**:
  - 1 装置 1 収支 = 1 spec を基本単位とする。どの残差が破れたかで故障箇所を特定するという設計目標が、そのまま spec 境界になる。
  - 評価（FDR/FAR/ADD・PCA 比較・閾値規約）は全残差で共通なので、最初の残差で必要性が確定した後に独立 spec として切り出す。
  - PINN と LLM 提案役は、確立済みの残差パターンを前提とする上位レイヤなので、最後に置く。
- **Shared seams to watch**:
  - **故障投入時刻の扱い**: `reactor-cw-energy-residual` が自分の評価のために投入時刻（サンプル21）を確定・適用し、`fdi-evaluation-foundation` がそれを共通モジュールへ一般化する。二重実装にならないよう、前者では最小限の修正に留める。
  - **閾値規約**: `reactor-cw-energy-residual` は暫定的に既存ハーネスの規約（FIT 残差最大×1.25）で評価し、`fdi-evaluation-foundation` で 99 パーセンタイル規約へ移行する。移行時に前者の結果を再計算する必要がある。
  - **生単位 vs Z-score**: 既存 `cli.jl` は全数値列を Z-score 正規化するため、$\lambda$ に物理的意味を与える新方針と衝突する。生単位で $\lambda$ を同定する経路を `VerificationHarness.jl` 側に寄せ、`cli.jl` の正規化は LLM-GP 探索用として分離する。
  - **CCF フィルタの適用範囲**: 既存の `filter_reactive_variables()` は比率 2.0 以上の変数を自動ハード除外するが、閉ループ下ではこれが XMV をほぼ機械的に全排除する。`llm-residual-proposer` で「除外」から「$\lambda$ 付きで式に含めて符号・値域で検証」へスコープ変更する。

---

## 調査結果（2026-10-06 実施）

### 1. データ仕様（実測で確定）

| 項目 | 確定値 | 確認方法 |
|---|---|---|
| データ版 | **Rieth et al. 2017（Harvard Dataverse 版）** | `.RData` 内の R オブジェクト名が `fault_free_training` / `faulty_training` と一致 |
| 正常データ | 500 ラン × 500 サンプル = 250,000 行 × 55 列 | 実測 |
| 異常データ | 20 故障 × 500 ラン × 500 サンプル = 5,000,000 行 | 実測 |
| サンプリング間隔 | **3 分**（500 サンプル × 3 分 = 1500 分 = 25 時間） | 構造から確定。**従来 steering にあった「1分かもしれない／未確証」の留保は解消** |
| 故障投入時刻 | **サンプル 21**（= 20 サンプル後 = 60 分 = 1 シミュレーション時間） | 下記の実測で確定 |
| `faultNumber` 列の意味 | **ラン単位の定数ラベル**（投入時刻マーカーではない） | IDV(1) ラン1 の全 500 サンプルで値が 1 |
| 未取得データ | `fault_free_testing`（960サンプル/48h）、`faulty_testing`（故障投入 8h） | リポジトリに存在せず |

**故障投入時刻の実測証拠**（IDV(6) = A 原料供給喪失、xmeas_1 の正常平均からの z 値）:

| サンプル | 17 | 18 | 19 | 20 | **21** | 22 | 23 |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| z 値 | 0.00 | 0.00 | 0.00 | 0.00 | **9.72** | 9.70 | 9.50 |

→ サンプル 20 まで完全に正常、サンプル 21 で急変。Rieth et al. 2017 の「故障は 1 シミュレーション時間後に投入」という記述と一致。

**⚠️ これにより判明した既存評価の重大なバイアス**:
既存の `VerificationHarness.jl` / `archive/` の全スクリプトは `findfirst(v -> v > 0, fault_col)` で投入時刻を求めており、`faultNumber` が定数ラベルであるためこれは**常にサンプル 1 を返す**。結果:
1. **報告済みの全 ADD 値は +20 サンプル（60 分）のバイアスを持つ。** 例: XMEAS(7) モデルの IDV(7) の報告値 ADD=20.0 は、実際には「サンプル 21 で検知 = 遅延 0」を意味する。真の ADD = 報告値 − 20。
2. **サンプル 3〜20（実際は正常期間）での検知が真陽性として誤計上されていた。** FDR は過大、FAR は過小に評価されている可能性がある。

この修正は `reactor-cw-energy-residual` の評価に直接影響するため、同 spec のスコープに含める。

### 2. 既存コンポーネントの役割

**Python 側（LLM-GP ループ駆動）**
- `src/orchestrator/main.py`: CLI エントリ。MIC スクリーニング → 禁止変数除去 → CCF 反応変数除去 → ループ構成
- `src/orchestrator/loop.py`: 世代ループ。自己参照ガード → Julia 評価 → 符号整合チェック → Skill Score 警告 → 独立審判 LLM
- `src/orchestrator/julia_runner.py`: JSON を stdin 経由で Julia サブプロセスへ渡す
- `src/orchestrator/preprocessing.py`: トポロジー禁止規則、MIC、CCF 非対称性検定
- `src/llm_interface/*`: プロンプト構築（物理法則ライブラリ 6 カテゴリ、変数辞書）、Anthropic API、構造化パース

**Julia 側（数値評価エンジン）**
- `src/NumericalEvaluator/cli.jl`: 入力 `{formula, target_variable, dataset_path, hyperparameters}` → 出力 `{status, fitness, rmse, penalty, coefficients, naive_mae, skill_score}`。処理順は ①ラン・サンプル順ソート → ②ラン境界マスク → ③`_lag<K>` トークンの動的シフト列生成（同一ラン内のみ） → ④**全数値列の Z-score 正規化** → ⑤差分化 → ⑥係数同定
  - ⚠️ `"rmse"` キーの実体は外れ値キャップ付き **MAE**（互換性のため名前のみ維持）
  - ⚠️ ④の Z-score 正規化が、$\lambda$ に物理的意味を与える新方針と衝突する
- `src/NumericalEvaluator/linear_fit.jl`: 重ね合わせの原理 $f(c) = h + Gc$ を 3 本のランダム $c$ で数値検証し、線形なら厳密 OLS、非線形なら BlackBoxOptim にフォールバック。**$\lambda$ について線形な残差の同定にそのまま使える**
- `src/VerificationHarness.jl`: `FeatureSpec(column, shift)` を渡すと、ラン境界を尊重した fit/holdout 分割 → 生単位 OLS → 差分 $R^2$ → MASE/Skill（分母は FIT で固定）→ FAR（サンプル単位・ラン単位）→ IDV ごとの FDR/**ADD** → Precision/Recall/F1 → アブレーション を一括実行
  - **未実装**: PCA ベースライン（$T^2$/SPE）、パーセンタイルによる閾値決定（現状は FIT 残差最大×1.25 という外れ値 1 点依存の脆い規約）、複数残差の統合、$\lambda$ のブートストラップ・スライディングウィンドウ再推定

### 3. ガイドライン §4(b) の変数検証（単位含む・すべて想定どおり）

| ガイドライン記号 | 変数 | 正式名称（`teprob.f`） | 単位 | 正常データ統計 |
|---|---|---|---|---|
| $T_r$ | XMEAS(9) | Reactor Temperature | **Deg C** (L119) | mean 120.400, std 0.0191 |
| $T_{cw,out}$ | XMEAS(21) | Reactor Cooling Water Outlet Temp | **Deg C** (L131) | mean 94.600, std 0.131 |
| $u_{10}$ | XMV(10) | Reactor Cooling Water Flow | **弁開度 %**（実装は `FWR = VPOS(10)*VRNG(10)/100.0`, L573） | mean 41.104, std 0.541, 範囲 38.6–43.9 |

- $T_r - T_{cw,out}$ = **+25.8 °C** > 0 → 熱は反応器から冷却水へ流れる。$UA(T_r - T_{cw,out})$ 項の符号は物理的に正しい。
- XMEAS(9) の std が 0.019 °C と極端に小さい（PI 制御で強く固定）。**PV 単独の式では情報がほぼ無い**ことを裏付ける。
- 対象 IDV も `teprob.f` の定義と完全一致: IDV(4) Reactor Cooling Water Inlet Temperature **Step** (L175)、IDV(11) 同 **Random Variation** (L182)、IDV(14) Reactor Cooling Water Valve **Sticking** (L185)。

### 4. 操作量（XMV）が必須であることの定量的証拠

故障投入後（サンプル ≥ 21）の平均が正常からどれだけ動くか（z 単位）:

| IDV | xmeas_9 ($T_r$) | xmeas_21 ($T_{cw,out}$) | **xmv_10 (弁)** |
|:-:|:-:|:-:|:-:|
| 4 | −0.00 | −0.00 | **+6.97** |
| 11 | −0.00 | −0.00 | +0.54 |
| 14 | −0.00 | +0.00 | +0.11 |

→ **IDV(4) では PV（$T_r$, $T_{cw,out}$）が完全に不動のまま、操作量だけが 7σ 動く。** PV だけで書いた式は IDV(4) を原理的に検知できない。CLAUDE.md §2 の「操作量を欠いた式は正常時にも成り立たない／むしろ必須である」という方針転換の、定量的な裏付けである。

ラン内標準偏差の比（故障時/正常時）:

| IDV | xmeas_9 | xmeas_21 | xmv_10 | 故障シグネチャの所在 |
|:-:|:-:|:-:|:-:|---|
| 4 | 1.04x | 0.94x | 0.96x | **平均シフト**（分散は不変） |
| 11 | 4.31x | 1.14x | **6.48x** | **分散増大**（ランダム変動のため平均は動かない） |
| 14 | **13.43x** | **10.59x** | **13.77x** | **分散の激増**（弁固着） |

→ 3 変数すべてに明確なシグネチャがある。ただし**検知設計は平均シフト型（IDV4）と分散変化型（IDV11/14）の両方を扱う必要がある**。残差の絶対値に対する固定閾値は前者に有効だが、後者には窓統計量（移動分散など）の併用が必要になる可能性が高い。

### 5. 既存の反応器圧力モデルの物理的な見直し点（ガイドライン §4(a)）

現行式 $\Delta P(t) = 21.99712 \cdot XMEAS(10)_{lag1} - 7.41260$ について:

| ガイドライン §4(a) の論点 | 現状の実装がどう扱っているか |
|---|---|
| **操作量が式に含まれていない** | XMV は現行 3 スクリプトに 1 件も出現しない（grep 確認済み）。アーカイブの XMEAS(7) 系も全て XMV 不使用。むしろ CCF 検定が XMV を反応変数として排除する運用だった（`xmv_5` 比率 7.71 で除外の記録）。**§2 の方針転換と正面から対立する既存実装**であり、改訂の核心。 |
| **stream 7（反応器→凝縮器）が非測定** | 対処は「下流の `xmeas_10`（分離器パージ）で代理する」のみ。steering に「多段階の遅れ・交絡（CCF 比率 1.33、境界線に近い）を持ち込む一因」と記録済み。`STATUS_SUMMARY.md` では**未解決として打ち切り決定**されていた。 |
| **XMEAS(10) は反応器ではなく分離器のパージ** | 文書上は認識済みだが**コード上の補正は一切ない**。ラグ 1 サンプルが「反応器→凝縮器→分離器→パージ」の多段輸送遅れを代表するという暗黙の仮定のみ。さらに `teprob.f` では分離器の流出が 3 系統（`xmeas_5` リサイクル / `xmeas_10` パージ / `xmeas_14` 液相アンダーフロー）であり、`xmeas_10` 単独はパージ系の一部ですらない。 |
| **反応による総ガスモル数の変化** | **完全に無視**。根拠式 $\frac{dP}{dt} \approx \frac{RT}{V}(F_{in} - F_{out})$ に反応消費項がなく、切片 −7.41260 が定常的なズレを吸収するだけ。`teprob.f` の真の収支は `YP(I) = FCM(I,7) - FCM(I,8) + CRXR(I)` で、`CRXR` が Arrhenius 由来の反応消費項。 |
| 文書化済みの限界 | マスキング（IDV(17) で素朴予想 6.8% → 本モデル 1.4% と**悪化**）、ドリフト型異常への感度不足（IDV13 で ADD 204 サンプル）、検知対象外 12 種（FDR 5% 未満）。 |

→ `reactor-pressure-model-revision` では、(1) 操作量の導入、(2) 収支をとる範囲の見直し（反応器単独か、反応器＋凝縮器＋分離器を 1 境界とするか）、(3) 反応消費項を $\lambda$ 付き補正項として入れるか、の 3 点を明示的に設計判断する。

### 6. 実装方針

#### 言語選択

| 段階 | 言語 | 理由 |
|---|---|---|
| **第1段階: $\lambda$ 同定（NN なし）** | **Julia** | ① 残差が $\lambda$ について線形なので `linear_fit.jl` の厳密 OLS がそのまま使える。② `VerificationHarness.jl` が FDR/FAR/ADD/MASE/アブレーションをラン境界を尊重して既に計算できる。③ `.RData` ロードが既に動く。④ 新規依存ゼロ。 |
| **第2段階: PCA 比較ベースライン** | **Python** | scikit-learn・pyreadr・pandas が既に `requirements.txt` にあり追加依存ゼロ。PCA の $T^2$/SPE は scikit-learn で簡潔に書ける。Julia で書く利点がない。 |
| **第3段階: PINN** | **Python / PyTorch** | 自動微分の成熟度とエコシステム。Julia の Flux.jl/Lux.jl + Zygote でも可能だが、現状リポジトリに NN コードは Julia にも Python にも無く、新規依存の重さは同等。PyTorch の方が参照実装・デバッグ情報が多い。**`torch` は未インストールなので着手時に追加**。 |

- **言語をまたぐ境界はファイル/JSON とする。** 既存の `julia_runner.py` が確立したパターン（JSON を stdin/stdout で受け渡す）を踏襲し、Julia 側の $\lambda$ 同定結果（係数・残差系列）を JSON で出力して Python 側（PCA 比較・PINN）が読む。言語間でモデルを共有しない。

#### ディレクトリ構成（新規分のみ）

```
src/
  PhysicsResiduals/                 # 【新規・Julia】装置ごとの残差定義と λ 同定
    PhysicsResiduals.jl             #   モジュール定義
    residuals.jl                    #   残差式の定義（装置単位、λ の符号・値域制約つき）
    lambda_identification.jl        #   λ 同定（線形→厳密OLS / 非線形→NLS）、ブートストラップ
    diagnostics.jl                  #   λ のスライディングウィンドウ再推定（診断用）
  VerificationHarness.jl            # 【既存・拡張】残差形式に対応、故障投入時刻の修正
  NumericalEvaluator/               # 【既存・流用】LLM-GP 候補式の λ 同定に使う
  orchestrator/, llm_interface/     # 【既存・改修】残差構造の提案役へ

baselines/                          # 【新規・Python】比較手法
  pca_baseline.py                   #   PCA の T² / SPE 統計量
  metrics.py                        #   FDR / FAR / 検出遅れ、閾値（99パーセンタイル）

pinn/                               # 【新規・Python/PyTorch】Phase 3 で着手
  model.py  train.py  residual_loss.py

docs/
  dataset_spec.md                   # 【新規】データ仕様の単一の情報源（版・3分間隔・投入サンプル21）
```

### 7. 科学的誠実さに関する注意（$\lambda$ 同定の盲検性）

本調査では `reference/teprob.f` を参照し、CLAUDE.md §4(b) の式が公式シミュレータの冷却水エネルギー収支 ODE（L789-790）の準定常形に厳密に対応することを確認した（`FWR = VPOS(10)*VRNG(10)/100.0` L573 が $k$、`QUR = UAR*(TWR-TCR)` L672 が $UA$ 項、`TCWR` L413 が非測定の $T_{cw,in}$ に対応）。

**ただし、式の構造のみを確認し、$UA$・$VRNG(10)$・$HWR$ 等の数値は意図的に参照していない。** $\lambda$ は CLAUDE.md §3 の規定どおり正常データのみから同定し、`teprob.f` の定数値を読んで埋めることは禁止する（データリーク）。

- 式の構造自体はユーザーが CLAUDE.md §4(b) で与えたものであり、本調査はその妥当性確認に留まる。
- **今後、新しい残差式を自分で考案する場合は、`teprob.f` は盲検発見後の事後照合専用とする規律を維持する。**
- 診断についての反証可能な予測: `teprob.f` L413 で IDV(4) は $T_{cw,in}$ への +5 °C ステップとして実装されている。したがって $\lambda = \{T_{cw,in}\}$ の再推定は IDV(4) で約 +5 °C のシフトを示すはずである。これは診断機能の検証に使える（ただし検知性能の閾値調整には使わない）。

---

## Existing Spec Updates
- [ ] tep-data-loader -- データ仕様メタデータ（3分間隔、故障投入サンプル21、ラン境界 `simulationRun` の扱い）を仕様に明記. Dependencies: none
- [ ] numerical-evaluator -- 残差形式 $r_k = 0$ への対応、$\lambda$ ごとの符号・値域制約、生単位モード（Z-score 正規化のバイパス）、RMSE 単独 fitness の見直し. Dependencies: reactor-cw-energy-residual
- [ ] llm-interface -- プロンプト契約に「XMV 必須」「制御則の残差への混入禁止」「$\lambda$ 宣言の要求」を追加、CCF 比率による XMV ハード禁止（`reactive_exclusions_section`）の撤回. Dependencies: llm-residual-proposer
- [ ] evolution-orchestrator -- 収束判定を RMSE 単独から残差・$\lambda$ 妥当性へ変更、`GenerationRecord` に $\lambda$（物理名・値域）と残差 ID を追加. Dependencies: llm-residual-proposer

## Direct Implementation Candidates
- [ ] steering `variable-modeling-methodology.md` の矛盾箇所の改訂 -- 制御則カテゴリの扱い（6カテゴリ→検知残差では禁止）、XMV 排除記述 4 箇所の撤回、サンプリング間隔 3 分の確定、旧見出し「TEP Dynamic Modeling Guidelines」への切れた参照の差し替え。ドキュメント編集のみで spec 不要
- [ ] 旧見出し参照の一括修正 -- `TEP_FLOW_DIAGRAM.md:64,187`、`src/VerificationHarness.jl:45`、`verify_xmeas7_no_ar.jl:5` の 4 箇所。機械的な置換のみ
- [ ] `CLAUDE.md` L66 の TEP_FLOW_DIAGRAM 更新規則から「P制御ループ方程式の逆解き」の例示を削除または注記追加 -- §2 が検知残差から排除した手法を導出根拠の代表例として挙げており、旧パターンを誘発する
- [ ] XMEAS(9)/(12)/(15) の「検知対象外」ステータスの**再判定フラグ立て** -- これらの撤回理由は「XMV は制御器応答だから独立な駆動力ではない」という、§2 で逆転した論法に依拠している。再探索するかの判断は `reactor-cw-energy-residual` の結果を見てから行うため、現時点では「要再判定」と記録するのみ

## Specs (dependency order)
- [ ] reactor-cw-energy-residual -- 反応器冷却水エネルギー収支残差。$\lambda = \{k/UA, T_{cw,in}\}$ を正常データのみで同定し凍結、IDV(4)/(11)/(14) を評価、XMV(10) 除外アブレーション、$\lambda$ 再推定による診断. Dependencies: none
- [ ] fdi-evaluation-foundation -- 評価基盤。PCA（$T^2$/SPE）ベースライン、FDR/FAR/検出遅れの統一算出、閾値=正常検証データの 99 パーセンタイル、複数残差の統合評価と故障箇所の帰属性. Dependencies: reactor-cw-energy-residual
- [ ] reactor-pressure-model-revision -- 既存 $\Delta P$ モデルの改訂。操作量の導入、stream 7 非測定／パージ代理／反応モル数変化の扱いを $\lambda$・補正項・収支範囲の見直しとして明示的に設計. Dependencies: fdi-evaluation-foundation
- [ ] condenser-cw-energy-residual -- 凝縮器冷却水エネルギー収支残差。IDV(5)/(12)/(15) を評価（IDV(15) は検知できない可能性を前提に検証）. Dependencies: reactor-cw-energy-residual, fdi-evaluation-foundation
- [ ] pinn-residual-integration -- PINN の段階的導入。(a) ノイズのある測定値からのなめらかな時間微分推定、(b) 次時刻予測モデル $\hat{x}_{n+1} = F(x_n, u_n)$、(c) 収支式で書けない部分を補う小さな NN $\delta$. Dependencies: reactor-cw-energy-residual, fdi-evaluation-foundation
- [ ] llm-residual-proposer -- LLM-GP を収支式の構造候補提案役へ再配置。候補の採否は正常データでの残差・$\lambda$ の妥当性・比較実験で判定. Dependencies: reactor-cw-energy-residual, fdi-evaluation-foundation

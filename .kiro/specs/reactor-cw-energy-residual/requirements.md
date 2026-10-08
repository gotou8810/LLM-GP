# Requirements Document

## Project Description (Input)

LLM-GPによる変数ごとの記号回帰は、閉ループ制御下でプロセス値（PV）だけでは外乱の影響が見えないという限界に行き詰まった。反応器冷却水のエネルギー収支について、操作量（XMV）を含む物理収支残差 $r = k\,u_{10}(T_{cw,out}-T_{cw,in}) - UA(T_r-T_{cw,out}) \approx 0$ を確立し、未知パラメータ $\lambda=\{k/UA,\ T_{cw,in}\}$ を正常データのみで同定・凍結したうえで、IDV(4)（冷却水入口温度ステップ）・IDV(11)（同ランダム変動）・IDV(14)（冷却水弁固着）を検知できる異常検知残差モデルを構築する。IDV(4)はPVが完全に不動のまま操作量だけが7σ変動する実測証拠があり、操作量の導入が不可欠であることは確認済み。IDV(11)/(14)はラン内標準偏差が正常時の6.5〜13.8倍になる分散変化型の故障であり、平均シフト型（IDV4）向けの検知だけでは不十分なため、分散に感度のある第2の統計量を必須とする。

## Boundary Context

- **In scope**: 残差式の構造定義と $\lambda$ の物理的妥当性制約、正常データのみでの $\lambda$ 同定と不確かさ・安定性の検証、$\lambda$ を凍結した状態での異常検知（平均シフト型・分散変化型の両方）、検知後の $\lambda$ 再推定による診断、操作量の寄与を検証する比較実験（操作量を外した場合との比較）、持続性ベースラインとの比較、故障投入時刻の正しい扱いとラン境界を尊重したデータ処理、検知できない場合の誠実な記録。
- **Out of scope**: PCA（$T^2$/SPE）ベースラインとパーセンタイルに基づく閾値決定方針の確立（`fdi-evaluation-foundation`が担当）、複数残差の統合評価と故障箇所の帰属性判定（`fdi-evaluation-foundation`が担当）、ニューラルネットワーク/PINNの導入（`pinn-residual-integration`が担当）、LLMによる新しい残差構造の提案（`llm-residual-proposer`が担当）、反応側の熱収支（組成依存の反応熱が未知のため対象外）、凝縮器側の同型残差（`condenser-cw-energy-residual`が担当）、既存の反応器圧力モデルの改訂（`reactor-pressure-model-revision`が担当）。
- **Adjacent expectations**: 正常運転データ（500ラン×500サンプル、3分間隔）および異常運転データ（20故障×500ラン×500サンプル）が、ドキュメント化されたサンプリング構造で利用可能であること。本specは、既存プロジェクトで確立済みの運用規律（持続性ベースライン/Skill Scoreによる比較、法則・符号の事前宣言と事後照合、ラン境界を尊重したデータ分割）に従う。

## Requirements

### Requirement 1: 残差式の構造と物理的妥当性制約

**Objective:** As a researcher building the reactor cooling-water energy-balance residual, I want the residual expressed in an identifiable form with physically constrained parameters, so that the identified parameters can be trusted as representing real physical quantities rather than arbitrary curve-fit coefficients.

#### Acceptance Criteria

1. The [反応器冷却水残差モデル] shall [反応器温度と冷却水出口温度の差を、冷却水流量操作量に関する線形な関係として表現し、同定可能な未知パラメータの組($\lambda$)として扱う].
2. The [反応器冷却水残差モデル] shall [各未知パラメータについて、同定前に期待される符号と物理的に妥当な値域を宣言する].
3. If [同定された未知パラメータの符号が、事前に宣言した符号と一致しない場合], then the [反応器冷却水残差モデル] shall [その残差式を無効なものとしてフラグし、妥当な式として受理しない].
4. If [未知パラメータから導出される非測定の冷却水入口温度が、冷却水出口温度以上であるか、工業用冷却水として物理的に妥当な範囲の外にある場合], then the [反応器冷却水残差モデル] shall [導出結果を物理的に不整合であるとフラグする].
5. If [準定常(代数式)の仮定のもとでの残差が、正常データの挙動を十分に説明できないと判定された場合], then the [反応器冷却水残差モデル] shall [冷却水出口温度の時間変化率を表す項を残差式に追加する].
6. The [反応器冷却水残差モデル] shall [伝熱係数と弁流量係数が個別には同定不可能であり、その比のみが同定可能であることを明記する].

### Requirement 2: 正常データのみでの未知パラメータ同定

**Objective:** As a researcher, I want the unknown parameters identified using only normal-operation data, so that fault data cannot leak into model calibration and bias the detection evaluation.

#### Acceptance Criteria

1. When [正常運転データが未知パラメータの同定に用いられる場合], the [反応器冷却水残差モデル] shall [異常運転データを一切参照せずに未知パラメータを推定する].
2. The [反応器冷却水残差モデル] shall [正常運転データを、同定に用いる部分集合と、同定には使わない保留部分集合に分割し、両者が重複しないようにする].
3. While [未知パラメータの同定が行われている間], the [反応器冷却水残差モデル] shall [検知や閾値決定に用いるハイパーパラメータの選定に異常運転データを参照しない].

### Requirement 3: 未知パラメータの不確かさと安定性の検証

**Objective:** As a researcher, I want to know how uncertain and stable the identified parameters are, so that later diagnostic conclusions drawn from parameter changes can be trusted.

#### Acceptance Criteria

1. When [未知パラメータの同定が完了した場合], the [反応器冷却水残差モデル] shall [各未知パラメータについて不確かさの推定値を報告する].
2. When [保留部分集合のデータを用いて未知パラメータを再評価した場合], the [反応器冷却水残差モデル] shall [再評価結果が同定時の不確かさの範囲内にあるかどうかを報告する].
3. If [保留部分集合での再評価結果が同定時の不確かさの範囲から外れる場合], then the [反応器冷却水残差モデル] shall [未知パラメータを不安定であるとフラグし、検知用途にはまだ採用できないことを示す].

### Requirement 4: 平均シフト型故障の検知（IDV4）

**Objective:** As a researcher, I want the frozen-parameter residual to flag a step-change fault in cooling water inlet temperature while controlling false alarms, so that this fault can be reliably detected without false positives on normal data.

#### Acceptance Criteria

1. While [未知パラメータが正常データでの同定値に凍結されている間], the [反応器冷却水残差モデル] shall [新たに与えられたデータに対して残差を継続的に算出する].
2. When [残差の大きさが検知しきい値を超えた場合], the [反応器冷却水残差モデル] shall [検知フラグを発する].
3. The [反応器冷却水残差モデル] shall [検知しきい値を、異常データを参照せず正常の検証データのみから決定する].
4. When [IDV(4)の異常データに対して評価が行われる場合], the [反応器冷却水残差モデル] shall [故障検知率と、故障投入時刻を基準とした検知遅れを報告する].
5. The [反応器冷却水残差モデル] shall [正常の検証データに対する誤報率を、故障検知の指標とは区別して報告する].

### Requirement 5: 分散変化型故障の検知（IDV11・IDV14）

**Objective:** As a researcher, I want a second detection statistic sensitive to changes in the residual's variability, so that variance-type faults that do not produce a mean shift can still be detected.

#### Acceptance Criteria

1. While [未知パラメータが正常データでの同定値に凍結されている間], the [反応器冷却水残差モデル] shall [残差の平均的な大きさに基づく検知とは別に、一定時間窓内での残差の変動性を表す第2の統計量を算出する].
2. When [第2の統計量が自身のしきい値を超えた場合], the [反応器冷却水残差モデル] shall [平均ベースの検知が発火しているかどうかに関わらず、独立に検知フラグを発する].
3. The [反応器冷却水残差モデル] shall [第2の統計量のしきい値を、異常データを参照せず正常の検証データのみから決定する].
4. When [IDV(11)またはIDV(14)の異常データに対して評価が行われる場合], the [反応器冷却水残差モデル] shall [第2の統計量による故障検知率と検知遅れを、平均ベースの検知結果とは区別して報告する].

### Requirement 6: 診断のための未知パラメータ再推定

**Objective:** As a researcher, I want the unknown parameters re-estimated over a recent time window after a detection, so that I can see which physical quantity changed and use that to infer a likely cause.

#### Acceptance Criteria

1. The [反応器冷却水残差モデル] shall [検知用に凍結された未知パラメータとは別に、直近の時間窓データから未知パラメータを再推定する診断機能を提供する].
2. When [診断のための未知パラメータ再推定が行われた場合], the [反応器冷却水残差モデル] shall [各パラメータが凍結時の値からどの方向・どれだけ変化したかを報告する].
3. The [反応器冷却水残差モデル] shall [診断用の再推定によって、検知に用いる凍結された未知パラメータの値が上書きされないようにする].

### Requirement 7: 操作量の寄与を検証する比較実験

**Objective:** As a researcher, I want a direct comparison between the full residual and a variant without the time-varying manipulated variable, so that I can confirm including the manipulated variable materially improves fault detection.

#### Acceptance Criteria

1. The [反応器冷却水残差モデル] shall [主要な残差式に加えて、冷却水流量操作量をその平均値に固定した比較用の残差式を提供する].
2. When [IDV(4)・IDV(11)・IDV(14)の異常データに対して評価が行われる場合], the [反応器冷却水残差モデル] shall [比較用の残差式についても主要な残差式と同じ指標（検知率・誤報率・検知遅れ）を報告し、両者を直接比較できるようにする].
3. The [反応器冷却水残差モデル] shall [直前の値をそのまま用いる素朴な予測（持続性ベースライン）との比較指標を、同じ故障データに対して報告する].

### Requirement 8: 故障投入時刻とラン境界を尊重したデータ処理

**Objective:** As a researcher, I want fault evaluation to use the correct fault-injection timing and to respect simulation-run boundaries, so that detection-delay and false-alarm metrics are not biased by data-handling errors.

#### Acceptance Criteria

1. The [反応器冷却水残差モデル] shall [故障ラベル列がラン全体に付与された定数ラベルであり投入時刻そのものではないことを前提に、実際の故障投入時点を別途特定したうえで評価に用いる].
2. When [検知遅れを計算する場合], the [反応器冷却水残差モデル] shall [各ランの先頭からではなく、特定された故障投入時点からの経過を計測する].
3. The [反応器冷却水残差モデル] shall [異なるシミュレーションランの境界をまたいで残差や未知パラメータの推定値を計算しない].

### Requirement 9: 学術的誠実さと限界の記録

**Objective:** As a researcher, I want any fault or limitation the residual cannot reliably handle to be explicitly recorded, so that claims about this model's capability remain scientifically defensible.

#### Acceptance Criteria

1. If [対象故障（IDV4・IDV11・IDV14のいずれか）が十分な性能で検知できないと判断される場合], then the [反応器冷却水残差モデル] shall [その結果を省略せず、限界として明示的に記録する].
2. The [反応器冷却水残差モデル] shall [操作量そのものが対象3故障以外の異常によって影響を受け、検知を隠蔽する可能性（マスキング）を確認し、確認結果を記録する].
3. The [反応器冷却水残差モデル] shall [IDV(4)・IDV(11)・IDV(14)以外の故障に対する検知能力を主張しない].

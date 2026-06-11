# TEP Variable Mapping & Plant Flow (Physical Context)

## 1. Plant Overview
TEP (Tennessee Eastman Process) は、以下の5つの主要ユニットで構成される化学プラントのシミュレーションである。
1. **Reactor (反応器)**: 4つのエキソサーミック（発熱）反応が発生。
2. **Condenser (凝縮器)**: 反応生成物（ガス）を冷却・部分凝縮。
3. **Vapor-Liquid Separator (気液分離器)**: 気相（未反応ガス・リサイクルへ）と液相（ストリッパーへ）に分離。
4. **Compressor (コンプレッサー)**: 未反応リサイクルガスを反応器へ再循環。
5. **Stripper (ストリッパー)**: 軽質分をストリップ（塔頂回収）し、高純度の最終製品液体を塔底から分離。

---

## 2. Complete Variable Map (53 Variables)

### A. Process Measurements (XMEAS 1 to 22)
プラント内で連続的に測定されるプロセスデータ（物理単位）。

| ID | 変数名 (和訳) | 物理的な位置 / 対象ストリーム | 既存ツイン構築状況 / 役割 |
| :--- | :--- | :--- | :--- |
| **XMEAS(1)** | A Feed Flow (原料A流量) | Stream 1 (原料A供給ライン) | - |
| **XMEAS(2)** | D Feed Flow (原料D流量) | Stream 2 (原料D供給ライン) | - |
| **XMEAS(3)** | E Feed Flow (原料E流量) | Stream 3 (原料E供給ライン) | - |
| **XMEAS(4)** | A & C Feed Flow (原料A/C/B流量) | Stream 4 (混合原料供給ライン) | - |
| **XMEAS(5)** | Recycle Flow (リサイクルガス流量) | Stream 8 (Separator気相からCompressor) | - |
| **XMEAS(6)** | Reactor Feed Rate (反応器総フィード流量) | Stream 6 (全供給・リサイクル合流後) | **因果ラグ変数** (XMEAS 7モデルで使用) |
| **XMEAS(7)** | Reactor Pressure (反応器圧力) | Reactor 気相部 | ✅ **デジタルツイン完了 ($R^2 = 0.9948$)** |
| **XMEAS(8)** | Reactor Level (反応器液位) | Reactor 液相ホールドアップ部 | - |
| **XMEAS(9)** | Reactor Temperature (反応器温度) | Reactor 内部混合液温度 | ✅ **極限デジタルツイン完了 ($R^2 = 0.4472$)** |
| **XMEAS(10)**| Purge Rate (パージ排気流量) | Stream 9 (リサイクルループからの系外排気) | **物理相関変数** (XMEAS 13モデル等で使用) |
| **XMEAS(11)**| Separator Temperature (分離器温度) | Product Separator 内部 | **物理相関変数** |
| **XMEAS(12)**| Separator Level (分離器液位) | Product Separator 下部液相 | ✅ **完全デジタルツイン完了 ($R^2 = 0.9999$)** |
| **XMEAS(13)**| Separator Pressure (分離器圧力) | Product Separator 気相部 | ✅ **デジタルツイン完了 ($R^2 = 0.9736$)** |
| **XMEAS(14)**| Separator Underflow (分離器底抜き液量) | Stream 10 (SeparatorからStripperへのフィード) | - |
| **XMEAS(15)**| Stripper Level (ストリッパー液位) | Stripper 塔底液相部 | - |
| **XMEAS(16)**| Stripper Pressure (ストリッパー圧力) | Stripper 塔頂部 | - |
| **XMEAS(17)**| Stripper Underflow (製品抜き出し流量) | Stream 11 (最終製品出荷ライン) | - |
| **XMEAS(18)**| Stripper Temperature (ストリッパー温度) | Stripper 塔底加熱部温度 | - |
| **XMEAS(19)**| Stripper Steam Flow (スチーム供給流量) | Stripper 再沸騰用スチームライン | - |
| **XMEAS(20)**| Compressor Work (コンプレッサー仕事率) | Compressor モーター消費電力 | - |
| **XMEAS(21)**| Reactor Cooling Water Outlet Temp (反応器冷却水出口温度) | Reactor 冷却水ジャケット排熱ライン | **5分移送ラグ変数** (XMEAS 9モデルで使用) |
| **XMEAS(22)**| Separator Cooling Water Outlet Temp (分離器冷却水出口温度) | Condenser 冷却水排熱ライン | - |

---

### B. Sampled Composition Measurements (XMEAS 23 to 41)
クロマトグラフ分析計によって取得される組成データ（モル分率％）。
*※注意: 実際のプロセスでは分析周期に起因するサンプリング遅延（タイムディレイ）を考慮する必要があります。*

#### 1. Reactor Feed Analysis (Stream 6 / 反応器総フィード組成)
*   **XMEAS(23)**: Component A (原料A)
*   **XMEAS(24)**: Component B (不活性ガスB)
*   **XMEAS(25)**: Component C (中間原料C)
*   **XMEAS(26)**: Component D (主原料D)
*   **XMEAS(27)**: Component E (副原料E)
*   **XMEAS(28)**: Component F (不純物F)

#### 2. Purge Gas Analysis (Stream 9 / パージガス組成)
*   **XMEAS(29)**: Component A
*   **XMEAS(30)**: Component B
*   **XMEAS(31)**: Component C
*   **XMEAS(32)**: Component D
*   **XMEAS(33)**: Component E
*   **XMEAS(34)**: Component F
*   **XMEAS(35)**: Component G (製品副生成物G)
*   **XMEAS(36)**: Component H (副生成物H)

#### 3. Stripper Underflow / Product Analysis (Stream 11 / 最終製品組成)
*   **XMEAS(37)**: Component D (混入原料D)
*   **XMEAS(38)**: Component E (混入副原料E)
*   **XMEAS(39)**: Component F (不純物F)
*   **XMEAS(40)**: Component G (製品副生成物G)
*   **XMEAS(41)**: Component H (目的主製品H)

---

### C. Manipulated Variables (XMV 1 to 12)
プラント制御のために調節する操作端（バルブ開度％ / モーター指令値）。

| ID | バルブ/操作対象名 | 支配する直接物理プロセス | 既存ツインでの役割 |
| :--- | :--- | :--- | :--- |
| **XMV(1)** | D Feed Flow Valve (原料D供給バルブ) | Stream 2 流量調節 | - |
| **XMV(2)** | E Feed Flow Valve (原料E供給バルブ) | Stream 3 流量調節 | - |
| **XMV(3)** | A Feed Flow Valve (原料A供給バルブ) | Stream 1 流量調節 | - |
| **XMV(4)** | A & C Feed Flow Valve (混合原料供給バルブ) | Stream 4 流量調節 | - |
| **XMV(5)** | Compressor Recycle Valve (バイパスバルブ) | コンプレッサーのリサイクル流量制御 | - |
| **XMV(6)** | Purge Valve (パージ排気バルブ) | Stream 9 排気量（系内の全不活性Bの蓄積制御） | **物理相関変数** |
| **XMV(7)** | Separator Underflow Valve (分離器液引き抜きバルブ) | Stream 10 抜き出し（液位12の調整） | **ツイン構築の決定打** (逆解き比例制御) |
| **XMV(8)** | Stripper Underflow Valve (製品出荷バルブ) | Stream 11 抜き出し（ Stripper 液位の調整） | - |
| **XMV(9)** | Stripper Steam Valve (スチーム供給バルブ) | スチーム流量（ Stripper 塔底温度加熱） | - |
| **XMV(10)**| Reactor CW Flow Valve (反応器冷却水バルブ) | 反応器除熱量（温度9の制御） | **伝熱非線形変数** (XMEAS 9モデルで使用) |
| **XMV(11)**| Condenser CW Flow Valve (凝縮器冷却水バルブ) | 凝縮器除熱量（気液平衡・分離器温度11の制御）| - |
| **XMV(12)**| Agitator Speed (反応器攪拌機回転数) | 反応器内の混合・除熱（多くは固定値）| - |

---

## 3. Physical Model Guidelines (No Auto-Regression)
ユーザーの方針変更に基づき、以下の制約をモデル構築に適用する。

1. **自己回帰項 (AR) の禁止**:
   - `xmeas_7_lag1` のような、ターゲット変数の過去値を用いた回帰は「物理的な因果関係の説明」にならないため使用しない。
2. **時間遅れ (Time Delay) の活用**:
   - 流体の移動や反応時間により、上流の変数は数ステップ（〜数十分）遅れて下流に影響する。
   - `xmeas_n_lagK` (K=5, 10, 20...) のようなラグ変数を探索範囲に含める。
3. **保存則・物理法則の考慮**:
   - 物質収支: (Feed - Purge - Product) = ΔInventory
   - 状態方程式: P ∝ nT/V
   - 反応速度: Rate ∝ exp(-E/RT)

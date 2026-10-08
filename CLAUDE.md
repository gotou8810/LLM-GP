# Agentic SDLC and Spec-Driven Development

Kiro-style Spec-Driven Development on an agentic SDLC

## Project Memory
Project memory keeps persistent guidance (steering, specs notes, component docs) so Claude Code honors your standards each run. Treat it as the long-lived source of truth for patterns, conventions, and decisions.

- Use `.kiro/steering/` for project-wide policies: architecture principles, naming schemes, security constraints, tech stack decisions, api standards, etc.
- Use local `CLAUDE.md` files for feature or library context (e.g. `src/lib/payments/CLAUDE.md`): describe domain assumptions, API contracts, or testing conventions specific to that folder. Claude Code auto-loads these when working in the matching path.
- Specs notes stay with each spec (under `.kiro/specs/`) to guide specification-level workflows.

## Project Context

### Paths
- Steering: `.kiro/steering/`
- Specs: `.kiro/specs/`

### Steering vs Specification

**Steering** (`.kiro/steering/`) - Guide AI with project-wide rules and context
**Specs** (`.kiro/specs/`) - Formalize development process for individual features

### Active Specifications
- Check `.kiro/specs/` for active specifications
- Use `/kiro-spec-status [feature-name]` to check progress

## Development Guidelines
- Think in English, generate responses in Japanese. All Markdown content written to project files (e.g., requirements.md, design.md, tasks.md, research.md, validation reports) MUST be written in the target language configured for this specification (see spec.json.language).

## Minimal Workflow
- Phase 0 (optional): `/kiro-steering`, `/kiro-steering-custom`
- Discovery: `/kiro-discovery "idea"` — determines action path, writes brief.md + roadmap.md for multi-spec projects
- Phase 1 (Specification):
  - Single spec: `/kiro-spec-quick {feature} [--auto]` or step by step:
    - `/kiro-spec-init "description"`
    - `/kiro-spec-requirements {feature}`
    - `/kiro-validate-gap {feature}` (optional: for existing codebase)
    - `/kiro-spec-design {feature} [-y]`
    - `/kiro-validate-design {feature}` (optional: design review)
    - `/kiro-spec-tasks {feature} [-y]`
  - Multi-spec: `/kiro-spec-batch` — creates all specs from roadmap.md in parallel by dependency wave
- Phase 2 (Implementation): `/kiro-impl {feature} [tasks]`
  - Without task numbers: autonomous mode (subagent per task + independent review + final validation)
  - With task numbers: manual mode (selected tasks in main context, still reviewer-gated before completion)
  - `/kiro-validate-impl {feature}` (standalone re-validation)
- Progress check: `/kiro-spec-status {feature}` (use anytime)

## Skills Structure
Skills are located in `.claude/skills/kiro-*/SKILL.md`
- Each skill is a directory with a `SKILL.md` file
- Skills matching the current task appear in the available-skills listing; invoke one with the Skill tool, or directly with `/kiro-<skill-name>`
- **If there is even a 1% chance a skill applies to the current task, invoke it.** Do not skip skills because the task seems simple.
- `kiro-review` — task-local adversarial review protocol used by reviewer subagents
- `kiro-debug` — root-cause-first debug protocol used by debugger subagents
- `kiro-verify-completion` — fresh-evidence gate before success or completion claims

## Multi-Agent
Claude Code supports the Agent tool for sub-agent dispatch (e.g. `general-purpose` for fresh subagents, `fork` to inherit context). Skills with "Parallel Research" sections list independent work items that benefit from sub-agent spawning.

## Development Rules
- 3-phase approval workflow: Requirements → Design → Tasks → Implementation
- Human review required each phase; use `-y` only for intentional fast-track
- Keep steering current and verify alignment with `/kiro-spec-status`
- Follow the user's instructions precisely, and within that scope act autonomously: gather the necessary context and complete the requested work end-to-end in this run, asking questions only when essential information is missing or the instructions are critically ambiguous.
- **TEP_FLOW_DIAGRAM 更新規則**:
  - 今後 `TEP_FLOW_DIAGRAM.md` を更新または新たなデジタルツインターゲットを追加・修正する際は、必ずその数式が導出された根拠となる学術的・化学工学的・制御工学的な方程式（例：理想気体の状態方程式、ニュートンの冷却法則、Clausius-Clapeyron/Antoine式、P制御ループ方程式の逆解きなど）を LaTeX 形式（`$$...$$` や `$...$`）で明記し、科学的な因果関係と物理的整合性を詳細に説明すること。

## Steering Configuration
- Load entire `.kiro/steering/` as project memory
- Default files: `product.md`, `tech.md`, `structure.md`
- Custom files are supported (managed via `/kiro-steering-custom`)

## TEP 物理ベース異常検知ガイドライン（PINNs 導入版）

化学プラントのプロセスダイナミクス、制御工学、およびモデルベース異常検知（FDI）の専門家としての知見に基づき、以下の物理的制約と評価哲学を厳守すること。

### 0. 研究方針の転換（背景）
- 従来は LLM-GP（LLM + Julia 差分進化法）で、変数ごとに回帰式を探索していた。
- 次の2つの問題で行き詰まったため、PINNs の考え方を取り入れた**装置（単位操作）ごとの物理収支残差**による異常検知へ移行する。
  1. LLM がプロンプトで与えた物理的制約に従わないことがある
  2. 閉ループ制御の影響で、プロセス値（PV）だけで書いた式は物理法則に従わないように見える
- 物理的制約は、LLM への指示ではなく、式の構造・損失関数・正常データでの検証によって**仕組みとして強制する**。

### 1. 式の基本形：装置ごとの収支残差
- 物理法則は、装置ごとの収支式の残差として与える：
  $$r_k(x, u; \lambda_k) = 0$$
  ここで $x$ は測定値（XMEAS）、$u$ は操作量（XMV）、$\lambda_k$ は未知パラメータ。
- 推定時は、スケール不定性を避けるため、1つの変数について解いた形で扱う。従来の反応器圧力モデルの目的変数 $\Delta P(t) = P(t+1) - P(t)$ は、この特殊形として引き続き有効とする。
- 静的相関ではなく、物理的な因果（収支・駆動力）に基づく式のみを用いる。サンプリング間隔（3分）より速い現象は、準定常の代数式として扱ってよい。

### 2. 使用変数の規則
- 式は**測定値と操作量だけで閉じる**ように構成する。1つの式で使う変数は3〜4個程度に絞る（どの式が破れたかで故障箇所を特定するため）。
- **操作量（XMV）は、プラントへの入力（流量などの代理変数）として式に含めてよい。むしろ必須である。** 閉ループでは外乱の影響が操作量側に現れるため、操作量を欠いた式は正常時にも成り立たない。
- **制御則（PV・設定値・MV の関係、PID 式、P制御ループの逆解きによる MV の推定式など）を、検知用の残差式に含めてはならない。** 制御器の挙動を学習すると、制御による異常の補償まで「正常」と判定してしまう。
  （TEP_FLOW_DIAGRAM.md での解説目的で制御ループ方程式を記述することは妨げない。）
- 流量が測定されている場合は、操作量より測定値を優先する（例：A原料は XMV(3) より XMEAS(1)）。
- **使用禁止変数（従来規則を一般化）**：
  - 目的変数自身の過去値（自己回帰項）
  - 目的変数と同時に動くだけで、式の中で因果的な役割を持たない追従変数（例：反応器圧力モデルにおける下流の分離器圧力 XMEAS(13)）
  - 例外：流出流量の駆動力（圧力差など）として物理法則に明示的に現れる場合に限り、根拠を LaTeX で示し、私の承認を得たうえで使用を検討できる。

### 3. 未知パラメータ λ の扱い
- $\lambda$ は、式の中で値の分からない定数の総称とする（伝熱係数 $UA$、弁開度から流量への換算係数、非測定の冷却水入口温度、容器断面積、単位換算係数など）。
- 各要素に物理的な意味と名前を与え、符号・値域に物理的な制約を課す。
- 推定は**正常データのみ**で行う。異常データを見て式・ハイパーパラメータ・閾値を選んではならない（データリーク禁止）。
- 推定後は、物理的妥当性、別区間での安定性、不確かさ（ブートストラップ等）を確認する。
- 検知時は $\lambda$ を正常時の値に**固定**する（非追従性の確保）。診断時のみ、スライディングウィンドウで再推定し、どの $\lambda$ がどれだけ動いたかを報告する。

### 4. 物理的因果律の例
**(a) 反応器圧力（質量収支・従来モデル）**
$$\frac{dP}{dt} \propto F_{in} - F_{out}$$
- 流入候補：XMEAS(6)（反応器フィード流量）
- 注意：反応器から凝縮器への流出（stream 7）は非測定である。XMEAS(10) は分離器からのパージ流量で、反応器の直接の流出ではない。また、反応によってガスのモル数が変化する。これらの扱い（$\lambda$、補正項、収支をとる範囲の見直し）を明示的に検討すること。

**(b) 反応器の冷却水側エネルギー収支（新規・最初に扱う式）**
$$k\,u_{10}\,(T_{cw,out} - T_{cw,in}) - UA\,(T_r - T_{cw,out}) \approx 0$$
- $T_r$ = XMEAS(9), $T_{cw,out}$ = XMEAS(21), $u_{10}$ = XMV(10)（反応器冷却水弁開度）
- $\lambda = \{k, UA, T_{cw,in}\}$（$T_{cw,in}$ は非測定）
- 反応側の熱収支は反応熱（組成依存で未知）を含むため用いない。
- 関係が期待される故障（仮説）：IDV(4), IDV(11)（冷却水入口温度）、IDV(14)（反応器冷却水弁の固着）
- 変数の対応と単位は、必ずデータの説明資料で確認すること。

### 5. PINNs の位置づけ
- 第1段階は NN を用いず、回帰で $\lambda$ を同定するだけでよい。
- PINN（NN + 自動微分）は、次の目的で段階的に導入する：
  - (a) ノイズのある測定値から、なめらかな時間微分を推定する（連続時間型・オフライン解析用）
  - (b) 次時刻の予測モデル $\hat{x}_{n+1} = F(x_n, u_n)$ を作る（離散時間型の考え方・監視用）
    $$\mathcal{L} = \|\hat{x}_{n+1} - x_{n+1}\|^2 + \alpha \sum_k \|r_k\|^2 + \beta \|\delta\|^2$$
  - (c) 収支式で書けない部分を、小さな NN $\delta$ で補う（正常データのみで学習し、強く正則化する）
- 論文（Raissi et al., 2017）の連続時間モデルは $(t, x)$ から1本の解を学習するもので、そのままではオンライン監視に使えない点に留意する。

### 6. LLM-GP の位置づけ
- LLM は「収支式の構造候補を提案する役」に限定する。候補の採否は、正常データでの残差・$\lambda$ の妥当性・比較実験で判定する。
- 既存の Julia 評価エンジンは、候補式の $\lambda$ 同定に流用する。
- 検知後の自然言語による説明（どの残差がずれ、どの $\lambda$ が動いたか）にも LLM を用いてよい。

### 7. 評価哲学とペナルティ
- 目標は「正常データへの適合」と「異常発生時の非追従性の最大化」の両立である。異常時に正常の物理を予測し続けることで、残差スパイク（解析的冗長性）を発生させる。
- 表面上の $R^2$ を稼ぐための非物理的な項、カンニング変数、高次の疑似相関項には厳格にペナルティを課す。
- 必須の比較実験：操作量の項を除いた式で残差が悪化することを示す（閉ループ対策の有効性の検証）。
- 比較手法：PCA（$T^2$ 統計量、SPE/Q 統計量）。正常の学習データのみで学習する。
- 指標：故障ごとの検出率（FDR）、正常データでの誤報率（FAR）、検出遅れ。閾値は正常の検証データから決める（例：99パーセンタイル）。
- 解釈性：どの残差がずれたか（故障箇所との一致）と、$\lambda$ の変化量（例：IDV(4) における $T_{cw,in}$ の推定変化）。

### 8. 学術的誠実さと主張の制限
- **主張のスコープ制限**：各残差モデルの検知対象は、その収支（質量・エネルギー）を直接破壊する物理的異常に限定される。「TEP の全故障を検知できる」という誇大表現を禁止する。
  - 質量収支モデル：バルブ喪失（IDV(6), IDV(7)）や未測定リークなど
  - 冷却系エネルギー収支モデル：冷却水の入口温度変化や弁の固着（IDV(4), (5), (11), (12), (14), (15)）。ただし、これは検証前の仮説として扱う
- **限界の明記**：微小な組成変化、反応速度の緩やかなドリフトなど、収支に直接影響しない異常は検知対象外であることを明記する。IDV(3), IDV(9) は効果が微小で、物理残差でも検知は極めて困難であることを率直に認める。IDV(15) をエネルギー収支で扱う場合も、検知できない可能性を前提に検証する。
- **むだ時間の考慮**：物理的な輸送遅れや熱伝達の遅れにより、検知遅延が生じるのは自然である。「0分で即時検知」のような因果律を無視した主張はしない。
- **トーン**：万能ツールとしてではなく、「特定の物理的異常を、誤報を抑えて確実に見抜く、ロバストな特化型モデル」として、査読者が納得する抑制的・学術的なトーンで記述する。
- **新しい残差式を追加したときは**、TEP_FLOW_DIAGRAM 更新規則に従い、根拠となる方程式を LaTeX で TEP_FLOW_DIAGRAM.md に記載する。
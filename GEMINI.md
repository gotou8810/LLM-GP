# Agentic SDLC and Spec-Driven Development

Kiro-style Spec-Driven Development on an agentic SDLC

## Project Memory
Project memory keeps persistent guidance (steering, specs notes, component docs) so Gemini CLI honors your standards each run. Treat it as the long-lived source of truth for patterns, conventions, and decisions.

- Use `.kiro/steering/` for project-wide policies: architecture principles, naming schemes, security constraints, tech stack decisions, api standards, etc.
- Use local `GEMINI.md` files for feature or library context (e.g. `src/lib/payments/GEMINI.md`): describe domain assumptions, API contracts, or testing conventions specific to that folder. Gemini CLI auto-loads these when working in the matching path.
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
Skills are located in `.gemini/skills/kiro-*/SKILL.md`
- Each skill is a directory with a `SKILL.md` file
- Use `/skills` to inspect currently available skills
- Invoke a skill directly with `/kiro-<skill-name>`
- **If there is even a 1% chance a skill applies to the current task, invoke it.** Do not skip skills because the task seems simple.
- `kiro-review` — task-local adversarial review protocol used by reviewer subagents
- `kiro-debug` — root-cause-first debug protocol used by debugger subagents
- `kiro-verify-completion` — fresh-evidence gate before success or completion claims

## Multi-Agent
Gemini CLI supports agent-as-tool for sub-agent dispatch. Skills with "Parallel Research" sections list independent work items that benefit from sub-agent spawning.

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

## TEP Dynamic Modeling Guidelines (圧力変化モデル数式生成指標)

化学プラントのプロセスダイナミクス、制御工学、およびモデルベース異常検知（FDI）の第一人者としての知見に基づき、テネシー・イーストマン・プロセス（TEP）のセンサーデータから純粋な「動的因果モデル（支配方程式）」を発見するための代数式（Symbolic Regression）を構築する際は、以下の厳格な物理的制約と評価哲学を絶対に遵守すること。

### 1. 予測対象（Target）の厳格な定式化
- 予測対象は、反応器絶対圧力 $P(t)$（XMEAS(7)）の生の値ではなく、1ステップ先の**圧力変化量**である $\Delta P(t) = P(t+1) - P(t)$ とする。
- 静的な釣り合い関係（静的相関）ではなく、ダイナミクス（状態変化を促す駆動力）そのものを定式化しなければならない。

### 2. 使用禁止変数（Forbidden Variables）の徹底
- 反応器圧力 XMEAS(7) と連動する「下流の分離器圧力 XMEAS(13)」や、自身の過去値である「自己回帰項（$XMEAS(7)_{lag}$ 等）」は、正常フィッティング値をカンニングする変数であるため、**使用を一切禁止する**。
- これらを使用すると、異常発生時（例：リーク）に実測値の低下にモデルの予測値が追従してしまい、異常を隠蔽するため、FDIロバスト性がゼロになる（「相関の罠」）。

### 3. 物理的因果律（Physics-Based Causality）の遵守
- 反応器圧力の変化 $\Delta P(t)$ は、質量保存則（アキュムレーション）に基づき、系内に流入するガスモル数 $F_{in}$ と系外へ流出するガスモル数 $F_{out}$ の差によってのみ本質的に決定される：
  $$\frac{dP}{dt} \propto F_{in} - F_{out}$$
- したがって、数式を構成する特徴量は、主に以下の変数群の差分・積・遅れ（lag）による因果関係のみで構成すること。
  - **流入流量候補**: XMEAS(6)（反応器フィード流量）など
  - **流出流量候補**: XMEAS(10)（反応器パージ流量）など

### 4. 評価哲学（Evaluation Philosophy）とペナルティ
- モデルの究極の目標は、「正常データへのフィッティング」と「異常発生時（特に未測定リーク等）における非追従性の最大化」の両立である。
- 異常発生時に、モデルが正常状態の物理ダイナミクスを予測し続けることで、実測値との間に「巨大な残差スパイク（解析的冗長性）」を発生させなければならない。
- 表面上の決定係数（$R^2$）のみを稼ぐための非物理的な項、カンニング変数、高次の疑似相関項の追加は厳格にペナルティを課す。

### 5. 学術的誠実さと主張の制限（物理限界と弱点の明記）
異常検知モデルの性能評価や結果解釈を行う際、AI特有の過大評価や全知全能の主張を厳格に禁止し、化学工学・プロセス制御の査読者レベルとしての学術的誠実さを徹底すること。

- **主張のスコープ制限（全異常100%検知の誇張禁止）**:
  - 本モデルはマスバランス（質量収支）に特化したデジタルツインである。
  - したがって、検知可能範囲は「バルブ喪失（IDV 6, 7）や未測定リークなど、質量流入・流出バランスを直接かつ急激に破壊する特定の物理的異常」に厳格に限定される。
  - 「TEPデータセットの全20種類の故障をすべて完璧に検知できる」という誇大表現は、厳にこれを禁止する。
- **限界と「検知対象外」の正直な記述**:
  - マスバランスに即座に、または直接的に影響を与えない微小な組成変化、反応速度の緩やかな経時ドリフト、下流分離器の局所的な温度異常などは、本モデルの「検知対象外」であることを明記すること。
  - 特に、TEPにおける難検知故障として悪名高い「IDV(3), IDV(9), IDV(15)」については、シンプルな質量保存モデルでは早期検知が物理的に極めて困難であることを率直に認めること。
- **物理的「むだ時間（Dead Time）」の考慮**:
  - 配管内の流体移送や熱伝導には必ず物理的なむだ時間（Transport Delay）が存在する。
  - したがって、異常が発生してから残差が実際に閾値を突破するまでには、物理的なタイムラグ（検知遅延）が生じるのが自然な動的挙動であり、「発生から0分で完璧に即時検知した」などの因果律を無視した全知全能の主張は絶対に行わないこと。
- **客観的かつ抑制の効いたトーンの維持**:
  - 魔法のような万能ツールとして記述するのではなく、「特定の物理的異常に対して、誤報を出さずに確実に見抜く、ロバストな特化型モデル」として、専門家が納得する冷徹で学術的なトーンで論述を展開すること。


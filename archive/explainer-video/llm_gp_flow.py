"""
LLM-GPループの全体フローを説明するManimアニメーション。
日本語フォントはNoto Sans CJK系を想定(Text()のfontオプションで指定)。
"""

from manim import *

# 日本語が使える環境のフォント名(無ければ自動フォールバックされる)
JP_FONT = "Noto Sans CJK JP"


def jtext(s, **kwargs):
    kwargs.setdefault("font", JP_FONT)
    return Text(s, **kwargs)


class LLMGPFlow(Scene):
    def construct(self):
        self.camera.background_color = "#1e1e2e"

        # ===== タイトル =====
        title = jtext("LLM-GP の仕組み", font_size=52, color=WHITE)
        subtitle = jtext(
            "データ読み込み → 式の提案 → Julia評価 → 結果保存",
            font_size=28, color=GRAY_B
        )
        subtitle.next_to(title, DOWN, buff=0.4)

        self.play(Write(title))
        self.play(FadeIn(subtitle, shift=UP * 0.3))
        self.wait(1.2)
        self.play(FadeOut(title), FadeOut(subtitle))

        # ===== フェーズ1: データ準備 =====
        self.show_phase1()

        # ===== フェーズ2: 世代ループ(LLM提案 -> Julia評価) =====
        self.show_phase2()

        # ===== フェーズ3: 判定と履歴保存 =====
        self.show_phase3()

        # ===== まとめ =====
        self.show_summary()

    # ------------------------------------------------------------------
    def make_box(self, label, sub, color=BLUE_D, width=4.2, height=1.3):
        box = RoundedRectangle(
            width=width, height=height, corner_radius=0.15,
            color=color, fill_color=color, fill_opacity=0.25
        )
        t1 = jtext(label, font_size=26, color=WHITE)
        t2 = jtext(sub, font_size=18, color=GRAY_B)
        t2.next_to(t1, DOWN, buff=0.12)
        group = VGroup(t1, t2)
        group.move_to(box.get_center())
        return VGroup(box, group)

    def phase_label(self, text):
        label = jtext(text, font_size=34, color=YELLOW)
        label.to_edge(UP, buff=0.5)
        return label

    # ------------------------------------------------------------------
    def show_phase1(self):
        label = self.phase_label("フェーズ1: データ準備  (main.py)")
        self.play(FadeIn(label, shift=DOWN * 0.3))

        box_data = self.make_box("TEPデータ読み込み", "TEP_FaultFree_Training.RData", color=TEAL_D)
        box_mic = self.make_box("MICスクリーニング", "calculate_mic_scores()", color=BLUE_D)
        box_forbid = self.make_box("禁止変数の除外", "compute_forbidden_variables()\nfilter_reactive_variables()", color=BLUE_D)

        boxes = VGroup(box_data, box_mic, box_forbid).arrange(RIGHT, buff=1.0)
        boxes.move_to(ORIGIN)

        arrow1 = Arrow(box_data.get_right(), box_mic.get_left(), buff=0.1, color=WHITE)
        arrow2 = Arrow(box_mic.get_right(), box_forbid.get_left(), buff=0.1, color=WHITE)

        self.play(FadeIn(box_data, shift=RIGHT * 0.3))
        self.wait(0.3)
        self.play(GrowArrow(arrow1), FadeIn(box_mic, shift=RIGHT * 0.3))
        self.wait(0.3)
        self.play(GrowArrow(arrow2), FadeIn(box_forbid, shift=RIGHT * 0.3))
        self.wait(1.0)

        note = jtext("→ EvolutionLoop を構築して run() を呼ぶ", font_size=22, color=GRAY_A)
        note.next_to(boxes, DOWN, buff=0.8)
        self.play(FadeIn(note, shift=UP * 0.2))
        self.wait(1.2)

        self.play(FadeOut(VGroup(label, boxes, arrow1, arrow2, note)))

    # ------------------------------------------------------------------
    def show_phase2(self):
        label = self.phase_label("フェーズ2: 世代ループ  (loop.py: EvolutionLoop.run)")
        self.play(FadeIn(label, shift=DOWN * 0.3))

        # LLM提案パイプライン(左側)
        box_prompt = self.make_box("プロンプト生成", "prompt_manager.py", color=PURPLE_D, width=3.6, height=1.1)
        box_llm = self.make_box("LLM呼び出し", "client.py / Anthropic API", color=PURPLE_D, width=3.6, height=1.1)
        box_parse = self.make_box("応答パース", "parser.py: ResponseParser", color=PURPLE_D, width=3.6, height=1.1)

        left_group = VGroup(box_prompt, box_llm, box_parse).arrange(DOWN, buff=0.35)
        left_group.to_edge(LEFT, buff=0.8).shift(DOWN * 0.3)

        arrow_l1 = Arrow(box_prompt.get_bottom(), box_llm.get_top(), buff=0.08, color=WHITE)
        arrow_l2 = Arrow(box_llm.get_bottom(), box_parse.get_top(), buff=0.08, color=WHITE)

        self.play(FadeIn(box_prompt, shift=DOWN * 0.2))
        self.play(GrowArrow(arrow_l1), FadeIn(box_llm, shift=DOWN * 0.2))
        self.play(GrowArrow(arrow_l2), FadeIn(box_parse, shift=DOWN * 0.2))
        self.wait(0.5)

        # 中央: ガード
        box_guard = self.make_box("自己回帰ガード", "contains_target_variable()", color=RED_D, width=3.0, height=1.0)
        box_guard.next_to(box_parse, RIGHT, buff=0.6)
        arrow_mid = Arrow(box_parse.get_right(), box_guard.get_left(), buff=0.1, color=WHITE)

        self.play(GrowArrow(arrow_mid), FadeIn(box_guard, shift=RIGHT * 0.2))
        self.wait(0.5)

        # 右側: Julia評価
        box_julia = self.make_box("Julia評価エンジン", "cli.jl: 正規化→差分化→OLS/BBO", color=ORANGE, width=3.3, height=1.3)
        box_julia.next_to(box_guard, RIGHT, buff=0.6)
        arrow_right = Arrow(box_guard.get_right(), box_julia.get_left(), buff=0.1, color=WHITE)

        self.play(GrowArrow(arrow_right), FadeIn(box_julia, shift=RIGHT * 0.2))
        self.wait(1.0)

        julia_sub = jtext(
            "fitness / rmse / coefficients / skill_score を JSON で返す",
            font_size=20, color=GRAY_A
        )
        julia_sub.next_to(box_julia, DOWN, buff=0.6)
        self.play(FadeIn(julia_sub, shift=UP * 0.2))
        self.wait(1.5)

        all_group = VGroup(
            label, left_group, box_guard, box_julia,
            arrow_l1, arrow_l2, arrow_mid, arrow_right, julia_sub
        )
        self.play(FadeOut(all_group))

    # ------------------------------------------------------------------
    def show_phase3(self):
        label = self.phase_label("フェーズ3: 判定と記録")
        self.play(FadeIn(label, shift=DOWN * 0.3))

        box_sign = self.make_box("符号チェック", "check_sign_consistency()", color=GREEN_D, width=4.0)
        box_judge = self.make_box("審判LLM", "judge_candidate() (独立呼び出し)", color=GREEN_D, width=4.0)
        box_history = self.make_box("履歴に記録", "HistoryManager.add_record()", color=GREEN_D, width=4.0)

        col = VGroup(box_sign, box_judge, box_history).arrange(DOWN, buff=0.45)
        col.move_to(ORIGIN).shift(DOWN * 0.2)

        arrow1 = Arrow(box_sign.get_bottom(), box_judge.get_top(), buff=0.08, color=WHITE)
        arrow2 = Arrow(box_judge.get_bottom(), box_history.get_top(), buff=0.08, color=WHITE)

        self.play(FadeIn(box_sign, shift=UP * 0.2))
        self.play(GrowArrow(arrow1), FadeIn(box_judge, shift=UP * 0.2))
        self.play(GrowArrow(arrow2), FadeIn(box_history, shift=UP * 0.2))
        self.wait(0.8)

        note = jtext(
            "sign_valid かつ judge_verdict≠FLAG のものを優先してベスト更新",
            font_size=20, color=GRAY_A
        )
        note.next_to(col, RIGHT, buff=0.6)
        self.play(FadeIn(note, shift=LEFT * 0.2))
        self.wait(1.5)

        loop_note = jtext("↻ これを世代数だけ繰り返す", font_size=24, color=YELLOW)
        loop_note.next_to(col, DOWN, buff=0.7)
        self.play(FadeIn(loop_note))
        self.wait(1.2)

        self.play(FadeOut(VGroup(label, col, arrow1, arrow2, note, loop_note)))

    # ------------------------------------------------------------------
    def show_summary(self):
        label = self.phase_label("最後に: 結果の保存  (main.py)")
        self.play(FadeIn(label, shift=DOWN * 0.3))

        box_save = self.make_box(
            "history.save_to_json()",
            "results/history_<target>.json に全履歴とベスト式",
            color=TEAL_D, width=6.5, height=1.5
        )
        box_save.move_to(ORIGIN)
        self.play(FadeIn(box_save, scale=0.8))
        self.wait(1.5)

        self.play(FadeOut(VGroup(label, box_save)))

        final = jtext("LLM-GP = 「LLMが式を提案し、Juliaが厳密に採点する」進化ループ", font_size=30, color=WHITE)
        final.move_to(ORIGIN)
        self.play(Write(final))
        self.wait(2.5)
        self.play(FadeOut(final))

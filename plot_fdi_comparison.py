import json
import os
import matplotlib.pyplot as plt

def main():
    json_path = "plot_data_xmeas7_fdi.json"
    if not os.path.exists(json_path):
        print(f"Error: {json_path} not found.")
        return
        
    print(f"Loading plot data from {json_path}...")
    with open(json_path, "r") as f:
        data = json.load(f)
        
    formula = data.get("formula", "")
    normal_max = data.get("normal_max_residual", 0.0)
    faulty_max = data.get("faulty_max_residual", 0.0)
    ratio = faulty_max / normal_max if normal_max > 0 else 0.0
    
    # 正常データの抽出
    h_time = data["healthy"]["time"]
    h_actual = data["healthy"]["actual"]
    h_pred = data["healthy"]["predicted"]
    h_res = data["healthy"]["residual"]
    
    # 異常データの抽出
    f_time = data["faulty"]["time"]
    f_actual = data["faulty"]["actual"]
    f_pred = data["faulty"]["predicted"]
    f_res = data["faulty"]["residual"]
    
    # プロットの作成 (2×2構成)
    # 左：正常データ、右：異常データ
    # 上：実測値 vs 予測値、下：予測残差
    fig, axs = plt.subplots(2, 2, figsize=(14, 8), sharex='col')
    
    # ----------------------------------------------------
    # 左上：正常データ (実測 vs 予測)
    # ----------------------------------------------------
    axs[0, 0].plot(h_time, h_actual, label="Actual $P_{meas}$", color="#1e40af", alpha=0.8, linewidth=1.5)
    axs[0, 0].plot(h_time, h_pred, label="Predicted $P_{pred}$", color="#ea580c", alpha=0.9, linestyle="--", linewidth=1.2)
    axs[0, 0].set_title("Normal Data: Actual vs Predicted Pressure", fontsize=12, fontweight="bold", color="#1e3a8a")
    axs[0, 0].set_ylabel("Reactor Pressure [kPa]", fontsize=10)
    axs[0, 0].grid(True, linestyle=":", alpha=0.6)
    axs[0, 0].legend(loc="upper right")
    
    # ----------------------------------------------------
    # 左下：正常データ (残差)
    # ----------------------------------------------------
    axs[1, 0].plot(h_time, h_res, color="#16a34a", alpha=0.8, label="Residual $R(t)$")
    axs[1, 0].axhline(y=normal_max, color="red", linestyle=":", alpha=0.7, label=f"Max Normal Res: {normal_max:.2f} kPa")
    axs[1, 0].axhline(y=-normal_max, color="red", linestyle=":", alpha=0.7)
    axs[1, 0].set_title("Normal Data: Prediction Residual", fontsize=11, fontweight="bold", color="#1e3a8a")
    axs[1, 0].set_ylabel("Residual [kPa]", fontsize=10)
    axs[1, 0].set_xlabel("Time Step [min]", fontsize=10)
    axs[1, 0].grid(True, linestyle=":", alpha=0.6)
    axs[1, 0].legend(loc="upper right")
    axs[1, 0].set_ylim([-max(30.0, normal_max*1.5), max(30.0, normal_max*1.5)])
    
    # ----------------------------------------------------
    # 右上：異常データ (実測 vs 予測)
    # ----------------------------------------------------
    axs[0, 1].plot(f_time, f_actual, label="Actual $P_{meas}$", color="#1e40af", alpha=0.8, linewidth=1.5)
    axs[0, 1].plot(f_time, f_pred, label="Predicted $P_{pred}$", color="#ea580c", alpha=0.9, linestyle="--", linewidth=1.2)
    axs[0, 1].set_title("Faulty Data: Actual vs Predicted Pressure (Leakage)", fontsize=12, fontweight="bold", color="#b91c1c")
    axs[0, 1].grid(True, linestyle=":", alpha=0.6)
    axs[0, 1].legend(loc="upper right")
    
    # ----------------------------------------------------
    # 右下：異常データ (残差)
    # ----------------------------------------------------
    axs[1, 1].plot(f_time, f_res, color="#b91c1c", alpha=0.8, label="Residual $R(t)$")
    axs[1, 1].axhline(y=normal_max, color="green", linestyle=":", alpha=0.7, label=f"Normal Res Threshold: {normal_max:.2f} kPa")
    axs[1, 1].axhline(y=-normal_max, color="green", linestyle=":", alpha=0.7)
    axs[1, 1].set_title(f"Faulty Data: Giant Residual Spike ({ratio:.2f}x Normal)", fontsize=11, fontweight="bold", color="#b91c1c")
    axs[1, 1].set_xlabel("Time Step [min]", fontsize=10)
    axs[1, 1].grid(True, linestyle=":", alpha=0.6)
    axs[1, 1].legend(loc="upper right")
    axs[1, 1].set_ylim([-max(300.0, faulty_max*1.2), max(300.0, faulty_max*1.2)])
    
    # 全体調整 (LaTeX 構文の衝突を避けるためプレーンテキストで表示)
    plt.suptitle(
        f"TEP Reactor Pressure [XMEAS(7)] FDI Robustness Verification\n"
        f"Formula: dP(t) = {formula}",
        fontsize=12, fontweight="bold", y=0.98, color="#0f172a"
    )
    plt.tight_layout()
    
    save_path = "xmeas7_fdi_comparison.png"
    plt.savefig(save_path, dpi=150)
    print(f"Plot successfully saved to {save_path}!")

if __name__ == "__main__":
    main()

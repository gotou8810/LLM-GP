import json
import matplotlib.pyplot as plt
import sys

def plot_comparison(json_path, output_path):
    with open(json_path, 'r') as f:
        data = json.load(f)
    
    actual = data['actual']
    predicted = data['predicted']
    formula = data['formula']
    r2 = data.get('r2', 'N/A')
    
    plt.figure(figsize=(12, 6))
    plt.plot(actual, label='Actual (TEP Data)', alpha=0.7)
    plt.plot(predicted, label='Formula (Calculated)', alpha=0.7)
    
    # Dynamically determine the target variable
    target = data.get('target', 'XMEAS(7)')
    if 'xmeas_13' in formula or 'xmeas_7_lag5' in formula or 'xmeas_10' in formula:
        target = 'XMEAS(13)'
    elif 'xmeas_7' in formula or 'xmeas_6_lag5' in formula:
        target = 'XMEAS(7)'
    
    plt.title(f'Comparison for {target}\nFormula: {formula}\nR2: {r2}')
    plt.xlabel('Sample Index')
    plt.ylabel('Physical Value')
    plt.legend()
    plt.grid(True)
    
    plt.tight_layout()
    plt.savefig(output_path)
    print(f"Graph saved as {output_path}")

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else 'plot_data.json'
    out = sys.argv[2] if len(sys.argv) > 2 else 'xmeas7_comparison.png'
    plot_comparison(path, out)

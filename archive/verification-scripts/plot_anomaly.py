import json
import matplotlib.pyplot as plt
import numpy as np
import glob
import os

def plot_anomaly(json_path):
    with open(json_path, 'r') as f:
        data = json.load(f)
    
    actual = np.array(data['actual'])
    predicted = np.array(data['predicted'])
    residuals = np.array(data['residuals'])
    fault_start = data['fault_start']
    fault_no = data.get('fault_no', 'Unknown')
    
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    
    ax1.plot(actual, label='Actual', alpha=0.7)
    ax1.plot(predicted, label='Predicted', linestyle='--', alpha=0.8)
    ax1.axvline(x=fault_start, color='red', linestyle=':', label='Fault Start')
    ax1.set_title(f'Fault {fault_no} Analysis')
    ax1.set_ylabel('Pressure')
    ax1.legend()
    
    ax2.plot(residuals, label='Residuals', color='red', alpha=0.7)
    ax2.axvline(x=fault_start, color='red', linestyle=':', label='Fault Start')
    
    # Threshold based on normal period
    normal_max = np.max(residuals[:fault_start-10])
    threshold = normal_max * 5 # Increase to 5x to be conservative
    ax2.axhline(y=threshold, color='green', linestyle='--', label='Threshold')
    
    ax2.set_ylabel('Error')
    ax2.legend()
    
    output_path = json_path.replace('.json', '.png')
    plt.tight_layout()
    plt.savefig(output_path)
    plt.close()
    
    # Check detection
    detect_idx = np.where(residuals[fault_start:] > threshold)[0]
    if len(detect_idx) > 0:
        print(f"FAULT {fault_no}: DETECTED at index {detect_idx[0] + fault_start}")
    else:
        print(f"FAULT {fault_no}: NOT DETECTED")

if __name__ == "__main__":
    for f in glob.glob("anomaly_results_fault*.json"):
        plot_anomaly(f)

import ctypes
import time
import pandas as pd
import matplotlib.pyplot as plt
import os

# --- 1. Load the Library ---
dll_path = os.path.join(os.getcwd(), "WaveCatcher64Ch.dll")
wc = ctypes.CDLL(dll_path)

# --- 2. Configuration ---
START_THR_MV = 5     # Starting low to catch the "noise wall"
END_THR_MV = 300    
STEP_MV = 2          # 2mV steps are usually enough and faster
GATE_TIME_SEC = 2.0  # Integration time for rate accuracy
CHANNELS = [0, 1]    # Channels 0 and 1 are the Si-Bar ends

def run_sweep():
    handle = wc.WAVECAT64CH_OpenDevice(0)
    if handle < 0:
        print("Error: Could not connect to WaveCatcher.")
        return

    data_log = []

    try:
        for thr in range(START_THR_MV, END_THR_MV + 1, STEP_MV):
            # Set threshold for both channels
            for ch in CHANNELS:
                wc.WAVECAT64CH_SetTriggerThreshold(handle, ch, ctypes.c_float(float(thr)))
            
            time.sleep(0.1) # Hardware stabilization

            # Start and wait for integration
            wc.WAVECAT64CH_StartRateCounters(handle)
            time.sleep(GATE_TIME_SEC)
            
            # Read Individual Rates
            rates_array = (ctypes.c_double * 64)()
            wc.WAVECAT64CH_ReadRateCounters(handle, rates_array)
            
            # Read Coincidence Rate (assuming handle, pointer to double)
            coinc_rate = ctypes.c_double(0.0)
            wc.WAVECAT64CH_ReadCoincidenceRate(handle, ctypes.byref(coinc_rate))

            entry = {
                "Threshold_mV": thr,
                "Ch0_Hz": rates_array[CHANNELS[0]],
                "Ch1_Hz": rates_array[CHANNELS[1]],
                "Coinc_Hz": coinc_rate.value
            }
            data_log.append(entry)
            print(f"Thr: {thr}mV | Coinc: {coinc_rate.value:.2f} Hz")

    finally:
        wc.WAVECAT64CH_CloseDevice(handle)
        
        # --- 3. Data Processing & Plotting ---
        df = pd.DataFrame(data_log)
        df.to_csv("muon_data_sweep.csv", index=False)
        
        plt.figure(figsize=(10, 6))
        
        # Plot individual channels (Noise + Signal)
        plt.step(df['Threshold_mV'], df['Ch0_Hz'], label='Ch 0 (Raw)', alpha=0.5)
        plt.step(df['Threshold_mV'], df['Ch1_Hz'], label='Ch 1 (Raw)', alpha=0.5)
        
        # Plot coincidence (Pure Muon Signal)
        plt.step(df['Threshold_mV'], df['Coinc_Hz'], label='Coincidence (Muons)', color='black', linewidth=2)
        
        plt.yscale('log') # Log scale is essential for SiPM data
        plt.xlabel('Threshold Voltage (mV)')
        plt.ylabel('Rate (Hz)')
        plt.title('SiPM Muon Detector: Rate vs. Threshold')
        plt.grid(True, which="both", ls="-", alpha=0.2)
        plt.legend()
        
        plt.savefig("muon_sweep_plot.png")
        plt.show()
        print("Sweep complete. Results saved to CSV and PNG.")

if __name__ == "__main__":
    run_sweep()
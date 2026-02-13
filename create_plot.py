# file: wiener_plot_analysis.py
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec

# ---------- IO ----------
def read_signal(path):
    vals = []
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if s.startswith('Error:'):
                raise RuntimeError(s)
            if s.startswith('Filtered output:'):
                s = s.replace('Filtered output:', '')
            if s.startswith('MMSE:'):
                continue
            for tok in s.split():
                try:
                    vals.append(float(tok))
                except ValueError:
                    pass
    return np.asarray(vals, dtype=float)

def read_mmse(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip().startswith('MMSE:'):
                    return float(line.split(':', 1)[1])
    except Exception:
        pass
    return None

# ---------- Metrics ----------
def snr_db(sig, noise):
    Ps = np.mean(sig**2)
    Pn = np.mean(noise**2)
    return 10*np.log10(Ps/Pn) if (Ps > 0 and Pn > 0) else float('nan')

# root mean square error
def rmse(a, b):
    d = a - b
    return float(np.sqrt(np.mean(d**2)))

# correlation coefficient: Hệ số tương quan Pearson giữa tín hiệu mong muốn và tín hiệu sau lọc.
def corr(a, b):
    if len(a) < 2:
        return float('nan')
    a0 = a - np.mean(a)
    b0 = b - np.mean(b)
    denom = np.sqrt(np.sum(a0**2) * np.sum(b0**2))
    return float(np.sum(a0 * b0) / denom) if denom > 0 else float('nan')

def mag_spectrum(x):
    N = len(x)
    if N == 0:
        return np.array([]), np.array([])
    X = np.abs(np.fft.fft(x))[:N//2]
    f = np.fft.fftfreq(N)[:N//2]
    return f, X

# ---------- Main ----------
def plot_weiner_filter(desired_p='desired.txt', input_p='input.txt', output_p='expected.txt',
         out_img='wiener_filter_analysis.png'):
    d = read_signal(desired_p)
    x = read_signal(input_p)
    y = read_signal(output_p)
    mmse = read_mmse(output_p)

    n = min(len(d), len(x), len(y))
    d, x, y = d[:n], x[:n], y[:n]
    idx = np.arange(n)

    # Metrics
    e = d - y
    noise_before = x - d
    noise_after  = y - d
    snr_before = snr_db(d, noise_before)
    snr_after  = snr_db(d, noise_after)
    delta_snr  = snr_after - snr_before
    r = corr(d, y)
    e_rmse = rmse(d, y)

    # In ra terminal
    print("\n--- Wiener Filter Metrics ---")
    print(f"Desired signal: {len(d)} samples")
    print(f"Input signal:   {len(x)} samples")
    print(f"Output signal:  {len(y)} samples")
    print("-" * 40)
    print(f"MMSE        = {mmse:.4f}" if mmse is not None else "MMSE        = N/A")
    print(f"SNR_before  = {snr_before:.2f} dB")
    print(f"SNR_after   = {snr_after:.2f} dB")
    print(f"ΔSNR        = {delta_snr:.2f} dB")
    print(f"RMSE        = {e_rmse:.4f}")
    print(f"Corr(d,y)   = {r:.4f}")
    print("-" * 40 + "\n")

    # Figure layout
    fig = plt.figure(figsize=(16, 12))
    gs = GridSpec(4, 2, figure=fig, hspace=0.6, wspace=0.25)

    # 1 Desired
    ax1 = fig.add_subplot(gs[0, 0])
    ax1.plot(idx, d, linewidth=1.5, label='Desired Signal')
    ax1.set_title('Desired Signal (Original)', fontsize=12, fontweight='bold')
    ax1.set_xlabel('Sample Index (n)')
    ax1.set_ylabel('Amplitude')
    ax1.grid(True, alpha=0.3)
    ax1.legend()

    # 2 Input
    ax2 = fig.add_subplot(gs[0, 1])
    ax2.plot(idx, x, linewidth=0.9, alpha=0.8, color='r', label='Input Signal (Noisy)')
    ax2.set_title('Input Signal (Desired + Noise)', fontsize=12, fontweight='bold')
    ax2.set_xlabel('Sample Index (n)')
    ax2.set_ylabel('Amplitude')
    ax2.grid(True, alpha=0.3)
    ax2.legend()

    # 3 Output
    ax3 = fig.add_subplot(gs[1, 0])
    ax3.plot(idx, y, linewidth=1.1, color='g', label='Output Signal (Filtered)')
    ax3.set_title('Output Signal (After Wiener Filter)', fontsize=12, fontweight='bold')
    ax3.set_xlabel('Sample Index (n)')
    ax3.set_ylabel('Amplitude')
    ax3.grid(True, alpha=0.3)
    ax3.legend()

    # 4 Compare Desired vs Output
    ax4 = fig.add_subplot(gs[1, 1])
    ax4.plot(idx, d, linewidth=1.4, label='Desired', color='b')
    ax4.plot(idx, y, linewidth=1.4, linestyle='--', label='Output (Filtered)', color='g')
    ax4.set_title(f'Comparison: Desired vs Output\n'
                  f'SNR Before = {snr_before:.2f} dB | After = {snr_after:.2f} dB | Δ = {delta_snr:.2f} dB',
                  fontsize=12, fontweight='bold')
    ax4.set_xlabel('Sample Index (n)')
    ax4.set_ylabel('Amplitude')
    ax4.grid(True, alpha=0.3)
    ax4.legend()

    # 5 All signals (first 100)
    ax5 = fig.add_subplot(gs[2, 0])
    z = min(100, n)
    ax5.plot(idx[:z], d[:z], label='Desired', linewidth=1.3, color='b')
    ax5.plot(idx[:z], x[:z], label='Input (Noisy)', linewidth=0.9, alpha=0.7, color='r')
    ax5.plot(idx[:z], y[:z], label='Output (Filtered)', linewidth=1.3, linestyle='--', color='g')
    ax5.set_title(f'All Signals Comparison (First {z} Samples)', fontsize=12, fontweight='bold')
    ax5.set_xlabel('Sample Index (n)')
    ax5.set_ylabel('Amplitude')
    ax5.grid(True, alpha=0.3)
    ax5.legend()

    # 6 Error + MMSE
    ax6 = fig.add_subplot(gs[2, 1])
    ax6.plot(idx, e, color='purple', linewidth=0.9, label='Error')
    ax6.axhline(0, color='k', linewidth=0.5)
    cap = f'Error: Desired - Output (MMSE: {mmse:.2f})' if mmse is not None else 'Error: Desired - Output'
    ax6.set_title(cap, fontsize=12, fontweight='bold')
    ax6.set_xlabel('Sample Index (n)')
    ax6.set_ylabel('Error Amplitude')
    ax6.grid(True, alpha=0.3)
    ax6.legend()

    # 7 Histogram error
    ax7 = fig.add_subplot(gs[3, 0])
    ax7.hist(e, bins=50, alpha=0.75, edgecolor='black', color='purple')
    ax7.set_title('Error Distribution', fontsize=12, fontweight='bold')
    ax7.set_xlabel('Error Value')
    ax7.set_ylabel('Frequency')
    ax7.grid(True, alpha=0.3, axis='y')

    # 8 Spectrum comparison
    ax8 = fig.add_subplot(gs[3, 1])
    f_in,  X = mag_spectrum(x)
    f_des, D = mag_spectrum(d)
    f_out, Y = mag_spectrum(y)
    ax8.semilogy(f_in,  X + 1e-12, label='Input (Noisy)', color='r')
    ax8.semilogy(f_des, D + 1e-12, label='Desired', color='b')
    ax8.semilogy(f_out, Y + 1e-12, label='Output (Filtered)', linestyle='--', color='g')
    ax8.set_title('Frequency Spectrum Comparison', fontsize=12, fontweight='bold')
    ax8.set_xlabel('Normalized Frequency')
    ax8.set_ylabel('Magnitude (log)')
    ax8.grid(True, alpha=0.3)
    ax8.legend()

    # plt.tight_layout()  # bỏ auto-layout vì có thể gây cảnh báo
    plt.subplots_adjust(hspace=0.6, wspace=0.25)

    # Lưu hình và in kết quả
    plt.savefig(out_img, dpi=300, bbox_inches='tight')
    print(f"Saved: {out_img}")

if __name__ == '__main__':
    plot_weiner_filter()
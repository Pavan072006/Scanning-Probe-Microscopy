import numpy as np
from scipy import signal

# ================= USER PARAMETERS =================
Fs = 31.25e6     # sampling frequency (Hz)
Fc = 1000e3       # cutoff frequency (Hz)
Rp = 0.3         # passband ripple (dB)
N  = 4           # filter order
QFMT = 30        # Q2.30
# ===================================================

# Design Chebyshev Type-I LPF in SOS form
sos = signal.cheby1(
    N,
    Rp,
    Fc,
    btype='low',
    fs=Fs,
    output='sos'
)

print("Floating-point SOS coefficients:")
print(sos)

def to_q30(x):
    return int(np.round(x * (1 << QFMT)))

print("\nQ2.30 coefficients (for FPGA):\n")

for i, sec in enumerate(sos):
    b0, b1, b2, a0, a1, a2 = sec

    # Normalize (a0 should already be 1)
    b0q = to_q30(b0)
    b1q = to_q30(b1)
    b2q = to_q30(b2)
    a1q = to_q30(a1)
    a2q = to_q30(a2)

    print(f"// ===== BIQUAD {i+1} =====")
    print(f"b0 = {b0q}   // {b0}")
    print(f"b1 = {b1q}   // {b1}")
    print(f"b2 = {b2q}   // {b2}")
    print(f"a1 = {a1q}   // {a1}")
    print(f"a2 = {a2q}   // {a2}")
    print()

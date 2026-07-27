# Scanning Probe Microscopy
 
FPGA-based instrumentation for scanning probe microscopy, built on a **Zynq-7020** platform and driven from Python through **PYNQ**. The repository collects the incremental designs that lead up to the main deliverable: a fully digital, self-locking **lock-in amplifier** for cantilever amplitude and phase detection.
 
Each folder is a self-contained experiment with its own bitstream (`.bit`), PYNQ hardware handoff (`.hwh`) and control notebook. The folders are ordered below roughly in order of increasing complexity.
 
---
 
## Requirements
 
- Zynq-7000 board — Red Pitaya STEMlab 125-14 for the lock-in, PYNQ-Z1/Z2 for the introductory designs
- Xilinx Vivado 2025.2 (all bitstreams in this repo were built with it)
- PYNQ Linux image with Jupyter
- Python: `numpy`, `scipy`, `matplotlib`, `plotly`, `pandas`, `ipywidgets`
---
 
## Repository Layout
 
| Folder | Purpose |
|---|---|
| `Blink/` | Minimal PS↔PL example — LED driven from BRAM |
| `Analog_Offset/` | Minimal example — DC offset injection on the analog output path |
| `Phase_Shift/` | Programmable phase delay of a reference signal |
| `Frequency_Detection/` | Hardware resonance-frequency estimator (derivative-ratio method) |
| `Lock-in amplifier/` | Full digital lock-in amplifier with ADPLL reference tracking |
 
---
 
## `Blink/` — PS↔PL handshake sanity check
 
The "hello world" of the project. The ARM processing system writes a word into a block RAM over AXI; a small RTL module (`PTN.v`) continuously reads address 0 of BRAM port B and drives an LED high when it sees `0x00000001`. `Blink.ipynb` toggles that word once per second over MMIO at `0x40000000`.
 
Its only purpose is to confirm that the AXI SmartConnect path, the BRAM controller, the overlay loading and the pin constraints all work end to end. `Block Diagram.png` shows the Vivado block design.
 
| File | Contents |
|---|---|
| `Blink.ipynb` | Overlay load, MMIO write loop, plus a PYNQ `GlobalState` monkey-patch |
| `Blink_wrapper.bit` / `.hwh` | Bitstream and hardware handoff |
| `Blink_wrapper.v` | Auto-generated Vivado top-level wrapper |
| `PTN.v` | Custom RTL — BRAM read → LED |
| `const.xdc` | Pin constraint (`led_0` → R14, LVCMOS33) |
| `Block Diagram.png` | Vivado block design screenshot |
 
---
 
## `Analog_Offset/` — DC offset injection
 
A second small example, this time exercising the analog front end rather than an LED. Two `offset_ctrl` IP blocks sit in the ADC/DAC path and add a programmable DC term. `analog_echo.ipynb` converts a voltage into a signed 15-bit code (`V × (2¹⁵ − 1)`) and writes it to the two channels of an AXI GPIO.
 
This is the mechanism later used to bias the analog path so that the signal of interest sits in the middle of the ADC range.
 
| File | Contents |
|---|---|
| `analog_echo.ipynb` | Overlay load, volts→code conversion, GPIO writes |
| `ADC.bit` / `ADC.hwh` | Bitstream and handoff (`adc_0`, `dac_0`, `offset_ctrl_0/1`, `axi_gpio_0`) |
 
---
 
## `Phase_Shift/` — Programmable reference phase delay
 
Many SPM detection schemes need the reference waveform shifted by a controlled phase relative to the drive. This design implements that shift in the simplest possible way: as an **integer delay in FPGA clock cycles**, computed from the measured signal frequency.
 
### How it works
 
1. Load the frequency-detection overlay and measure the input frequency `f_est` (same procedure as `Frequency_Detection/`, described below).
2. Convert that to a period in clock cycles:
   `phase = f_fpga / f_est`, with `f_fpga = 125 MHz`. This is the number of FPGA clock cycles in one full 2π of the signal.
3. Load the phase-shift overlay and drive an `ipywidgets` slider spanning 0 → 2π. Each slider position `x ∈ [0, 2]` is mapped to a delay of `x · phase / 2` cycles and written to AXI GPIO channel 2.
Because the delay is quantised to 125 MHz clock ticks, the achievable phase resolution is `360° × f_est / 125 MHz` — fine for the kHz-range cantilever frequencies this is aimed at, and increasingly coarse as the signal frequency rises.
 
The two-overlay structure (measure, then shift) is deliberate: the correct delay cannot be known until the resonance frequency has been measured, so the frequency estimate feeds directly into the phase controller.
 
| File | Contents |
|---|---|
| `Untitled.ipynb` | Frequency measurement, then slider-driven phase delay via GPIO |
| `nodma_1.bit` / `.hwh` | Frequency-detection overlay (identical to `Frequency_Detection/`) |
| `ADC.bit` / `ADC.hwh` | Analog-path overlay (identical to `Analog_Offset/`) |
 
---
 
## `Frequency_Detection/` — Hardware resonance-frequency estimator
 
Tracking a cantilever's resonance requires a frequency estimate that is fast, cheap in logic, and does not need an FFT. This design computes one entirely in the PL using a **derivative-ratio method**, then does a single inverse-trigonometric step on the host.
 
### Principle
 
For a sampled sinusoid `x[n] = A·sin(2πf·n·dt)`, finite differences of the sequence scale by a known function of the normalised frequency. Taking the **ratio of two accumulated derivative energies** cancels the amplitude `A` entirely and leaves a quantity that depends only on `f·dt`. The design accumulates a numerator and a denominator over a user-chosen number of samples, and the host inverts the relation:
 
```
A     = num / den
f_est = arcsin(√(A / 4)) / (2π · dt)      with dt = 1 µs
```
 
Because amplitude cancels, the estimate is insensitive to drive level and to slow gain drift — which matters in SPM, where the oscillation amplitude changes as the tip approaches the surface. Averaging over many samples buys precision at the cost of measurement time, and that trade-off is exposed directly as the sample-count register.
 
### Register interface
 
| Register | Address | Function |
|---|---|---|
| `reg_bank_0` | `0x40` | Number of samples to accumulate |
| `reg_bank_0` | `0x44` | Acquisition trigger (write 1, then 0) |
| `double_derivative_top_0` | `0x00` | Bit 0 = start, bit 1 = done |
| `double_derivative_top_0` | `0x10` / `0x14` | Numerator, low / high 32 bits |
| `double_derivative_top_0` | `0x28` / `0x2c` | Denominator, low / high 32 bits |
 
The numerator and denominator are each reassembled into a signed 64-bit value on the host.
 
### Notebook
 
`nodma_dd.ipynb` walks through the full characterisation:
 
- **Single-shot measurement** — arm, poll the done flag, read the accumulators, compute `f_est`.
- **Repeated measurement** — 500 consecutive estimates at 625 000 samples each, with per-iteration timing recorded.
- **Noise analysis** — Welch power spectral density of the estimate sequence (units of Hz²/Hz), which characterises the estimator's own frequency noise floor.
- **Linearity sweep** — interactive loop prompting for the true input frequency, plotting measured against ideal, and tabulating the error in a pandas DataFrame.
| File | Contents |
|---|---|
| `nodma_dd.ipynb` | Single-shot, repeated, PSD and linearity-sweep measurements |
| `nodma_1.bit` / `.hwh` | Bitstream and handoff (`adc_0`, `double_derivative_top_0`, `reg_bank_0`, `stream_ctrl_0`) |
 
---
 
## `Lock-in amplifier/` — Digital lock-in with ADPLL reference tracking
 
The main deliverable. A lock-in amplifier recovers a signal buried far below the noise floor by exploiting the fact that the signal of interest is at a *known* frequency: multiply the noisy input by a reference at that frequency, low-pass filter the product hard, and everything not phase-coherent with the reference averages to zero. In SPM this is what extracts cantilever amplitude and phase from a photodiode signal dominated by thermal and electronic noise.
 
The distinguishing feature of this implementation is that **the reference does not have to be supplied as a clean waveform**. A TTL reference edge is enough — an on-chip all-digital PLL locks a numerically controlled oscillator to it, so the internal sine and cosine are phase-coherent with the drive even as the drive frequency drifts.
 
Everything runs at the **125 MHz ADC clock** with **16-bit** datapaths and a **46-bit** frequency control word.
 
### Signal chain (`lockin_for_bd.v`)
 
```
ADC ──┬─────────────────────────────────────────────────► ×  ──► LPF ──► boxcar ──┐
      │                                                   ▲                       │
      │                                              sin ─┤                       ├─► 64-bit AXI-Stream
TTL ──► edge detect ──► period measure ──► coarse FTW ──► DDS ──► ×  ──► LPF ──► boxcar ──┘
                    │                          ▲    cos
                    └──► ADPLL (PFD → PI) ─────┘
```
 
**1 — Reference conditioning.** `digital_edge_detector.v` takes the raw TTL reference through a two-flop synchroniser, an N-tap debounce shift register, rising-edge detection, and a configurable dead-time counter. The dead time suppresses the multiple false edges that a noisy or slow-slewing TTL line would otherwise produce, which would corrupt the period measurement downstream.
 
**2 — Coarse frequency estimation.** The interval between clean reference edges is measured and averaged, and a `div_gen` divider converts that period into an initial frequency control word. This gets the NCO close to the right frequency immediately, so the PLL only has to pull in a small residual error rather than acquire from scratch.
 
**3 — NCO.** A `dds_compiler` instance generates quadrature sine and cosine from the selected 46-bit FTW, with phase reset and an NCO-sync output so its phase can be aligned to the reference edge.
 
**4 — ADPLL (`adpll_for_bd.sv`).** The fine-tracking loop:
 
- **Phase-frequency detector** — an RS-latch pair sets `q_up` on a reference edge and `q_dn` on an NCO edge, clearing when both are present. The resulting `up_act` / `dn_act` windows are measured by counters, giving a signed phase error in clock cycles. Unlike a plain multiplier-based phase detector, this construction is frequency-sensitive as well as phase-sensitive, so it pulls in from a large initial offset without false-locking to a harmonic.
- **PI controller** — fixed-point proportional and integral paths with runtime-settable `kp` and `ki` gains in Q-format, pipelined across several stages to close timing at 125 MHz.
- **Output** — an FTW correction added to the base word, plus a `lock_flag` asserted when the phase error stays inside tolerance.
**5 — FTW selector.** Chooses between the coarse estimate, the PLL-corrected fine value, and a free-running word supplied from software. The free-running mode is what you use when there is no external reference at all and the FPGA itself must generate the drive.
 
**6 — Mixing.** The (optionally amplitude-scaled) ADC sample is multiplied by sine and by cosine, producing the in-phase `I` and quadrature `Q` products. Each contains a DC term proportional to the signal component at the reference frequency, plus a sum-frequency term and noise, both of which the following filters remove.
 
**7 — Low-pass filtering (`lpf_for_bd.v`).** Three instances of a Red Pitaya–style single-pole IIR block are present: one on the input as a high-pass (currently bypassed) and one on each of the I and Q channels. Each uses a **two-phase multi-cycle datapath** — multiply on one cycle, accumulate and update state on the next — with a 60-bit accumulator and an explicitly DSP-inferred multiplier. The wide accumulator is what makes very low cutoff frequencies usable without rounding error accumulating in the feedback loop, and the two-cycle structure keeps the DSP timing comfortable. Coefficients `aa`, `pp`, `kk` are all runtime-writable, so the time constant can be changed without rebuilding.
 
**8 — Boxcar averaging and decimation.** A power-of-two boxcar averager with a 16 384-deep window in block RAM, fed by a programmable clock-enable sub-sampler (`decimation_rate_i`). This drops the output rate to something the ARM core and Python can actually consume, while providing a second stage of noise rejection.
 
**9 — Settling detection.** A controller takes `settling_samples_i` — computed in software as roughly 4× the filter time constant, expressed in exact clock cycles — and gates the output valid signal until the filters have settled after a configuration change. This prevents transients being recorded as data.
 
**10 — Output packing.** Two 64-bit AXI-Stream channels:
 
| Stream | Bits | Contents |
|---|---|---|
| `m_axis_tdata` | `[63:48]` | Filtered Q |
| | `[47:32]` | Filtered I |
| | `[31:16]` | Phase-matched raw ADC input |
| | `[15:0]` | NCO sine (current tracking phase) |
| `m_axis_freq_tdata` | `[63:48]` | Averaged reference period |
| | `[47]` / `[46]` | Reference edge / NCO edge |
| | `[45:0]` | Currently selected FTW |
 
Bundling the raw ADC sample and the NCO output alongside I and Q means the host can independently verify phase alignment and lock quality from the same capture, rather than trusting the hardware's own lock flag.
 
### Filter design flow
 
The IIR and FIR coefficients are not hand-tuned — they are generated by scripts and imported as `.coe` files into the Xilinx IP:
 
- **`iir_filter_coefficients.py`** — designs a 4th-order Chebyshev Type-I low-pass (Fs 31.25 MHz, Fc 1 MHz, 0.3 dB passband ripple) in second-order-section form and prints Q2.30 integer coefficients ready to paste into RTL.
- **`cic_compensation.ipynb`** — a CIC decimator (R = 128, M = 1, N = 5) has significant passband droop. This notebook computes the CIC magnitude response analytically, inverts it, and designs a 151-tap `firwin2` compensator that flattens the passband out to 110 kHz, writing `cic_compensation_2.coe`.
- **`FIR_filter_coeff.ipynb`** — designs a 201-tap Kaiser-window FIR (β = 9, ≈90 dB stopband) at Fs 488.28 kHz with a 110 kHz cutoff, quantises to 16-bit, writes the `.coe`, and plots the response for verification.
### Alternative decimation chain
 
Two modules explore a higher-decimation path than the single-pole IIRs used in the main design:
 
- **`cic_fir_filter.sv`** — chains a Xilinx CIC compiler into two cascaded FIR compensation stages with shift-based rescaling between them, plus a system-bus register interface. This is the consumer of the two `.coe` files above.
- **`iir_biquad_filter.sv`** — a three-stage pipelined biquad section with externally supplied `a1, a2, b0, b1, b2` coefficients and a shared `sample_en` enable pipeline, consuming the Q2.30 output of `iir_filter_coefficients.py`.
### Verification and analysis
 
**`lockin_test_tb.v`** simulates the top-level `lockin` module at 125 MHz, driving synthetic ADC and TTL reference inputs along with the full coefficient, decimation and settling configuration, and monitors the mixer, LPF, amplitude and lock outputs.
 
**`lockin_plotter.ipynb`** is the post-processing workbench for captured data. It loads a saved `.npz`, bit-unpacks the 64-bit stream into its Q / I / ADC / sine components, converts to volts, and produces:
 
- an eight-panel Plotly dashboard covering extracted amplitude `R = √(I² + Q²)`, the filtered quadrature DC levels, raw ADC-versus-reference phase alignment, ADPLL edge and control channels, coarse period-estimator timing, and the final tracked frequency;
- amplitude statistics (mean, standard deviation, min/max, peak-to-peak) quantifying the residual noise on `R`;
- several FFT analyses with selectable detrending, windowing (Hann / Hamming / Blackman) and zero-padding, applied to the ADC input, the amplitude output, the quadrature channels and the NCO reference, for locating spurs and leakage.
### File index
 
| File | Contents |
|---|---|
| `lockin_for_bd.v` | Top-level lock-in — edge detect, coarse estimate, DDS, PLL control, mixing, LPF, boxcar, settling, stream packing |
| `adpll_for_bd.sv` | All-digital PLL — pulse-width PFD, fixed-point PI controller, FTW correction, lock flag |
| `lpf_for_bd.v` | Two-phase multi-cycle single-pole IIR low-/high-pass block |
| `digital_edge_detector.v` | TTL reference conditioning — sync, debounce, edge detect, dead time |
| `iir_biquad_filter.sv` | Pipelined biquad section with external coefficients |
| `cic_fir_filter.sv` | CIC → FIR → FIR decimation and compensation chain |
| `iir_filter_coefficients.py` | Chebyshev-I SOS design, Q2.30 output |
| `cic_compensation.ipynb` | CIC droop compensator design, writes `.coe` |
| `FIR_filter_coeff.ipynb` | Kaiser-window FIR design, writes `.coe` |
| `lockin_test_tb.v` | Top-level Verilog testbench |
| `lockin_plotter.ipynb` | Capture decoding, Plotly dashboard, amplitude statistics, FFT analysis |
| `pll_final_version.xpr` | Vivado project (references `design_1.bd`, `stream_ctrl.v`, `dds_compiler_0`, `div_gen_0`, `redpitaya-125-14.xdc`) |
 
---

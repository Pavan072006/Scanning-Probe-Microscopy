`timescale 1ns/1ps

module tb_lockin;

  // ---------------- Params ----------------
  localparam CLK_PERIOD = 8; // 125 MHz Clock (8ns period)
  localparam ADC_W      = 16;
  localparam COEFF_W    = 25;

  // ---------------- DUT signals ----------------
  reg clk;
  reg rstn;

  reg signed [ADC_W-1:0] adc_in_tdata;
  reg                    adc_in_tvalid;

  reg ref_in_tdata;
  reg ref_in_tvalid;

  reg signed [15:0] amp_ctrl_i;
  reg                use_pll_i;

  reg signed [17:0]        hpf_aa_i;
  reg signed [COEFF_W-1:0] hpf_pp_i, hpf_kk_i;
  reg signed [17:0]        lpf_aa_i;
  reg signed [COEFF_W-1:0] lpf_pp_i, lpf_kk_i;

  reg [31:0] ftw_free_low_i;
  reg [13:0] ftw_free_high_i;

  // NEW: Multi-rate configuration lines driving the boxcar/settling engine
  reg [31:0] decimation_rate_i;
  reg [31:0] settling_samples_i;

  wire signed [ADC_W-1:0] sin_tdata;
  wire                    sin_tvalid;
  wire signed [ADC_W-1:0] cos_tdata;
  wire                    cos_tvalid;

  // Monitored internal outputs for amplitude analysis
  wire signed [ADC_W-1:0] sig_sin_tdata, sig_cos_tdata;
  wire signed [ADC_W-1:0] mix_i_lpf_tdata, mix_q_lpf_tdata;
  wire                    mix_i_lpf_tvalid, mix_q_lpf_tvalid;
  wire signed [ADC_W-1:0] mix_i_tdata, mix_q_tdata;
  wire                    mix_i_tvalid, mix_q_tvalid;

  wire [63:0] m_axis_tdata;
  wire        m_axis_tvalid;
  wire        lock_flag_o;
  wire        ttl_edge_o;
  wire ref_edge_pll;
  wire nco_edge_pll;
  
  wire        ftw_free_ttl_o;
  
  // ---------------- DUT Instance ----------------
  lockin #(
    .FCW(46),
    .ADC_W(ADC_W),
    .COEFF_W(COEFF_W)
  ) dut (
    .clk(clk),
    .rstn(rstn),

    .adc_in_tdata(adc_in_tdata),
    .adc_in_tvalid(adc_in_tvalid),

    .ref_in_tdata(ref_in_tdata),
    .ref_in_tvalid(ref_in_tvalid),

    .amp_ctrl_i(amp_ctrl_i),
    .use_pll_i(use_pll_i),

    .hpf_aa_i(hpf_aa_i),
    .hpf_pp_i(hpf_pp_i),
    .hpf_kk_i(hpf_kk_i),

    .lpf_aa_i(lpf_aa_i),
    .lpf_pp_i(lpf_pp_i),
    .lpf_kk_i(lpf_kk_i),

    .ftw_free_low_i(ftw_free_low_i),
    .ftw_free_high_i(ftw_free_high_i),
    .ftw_free_ttl_o(ftw_free_ttl_o),

    // CONNECT NEW AVERAGER CONTROLS
    .decimation_rate_i(decimation_rate_i),
    .settling_samples_i(settling_samples_i),

    .sin_tdata(sin_tdata),
    .sin_tvalid(sin_tvalid),
    .cos_tdata(cos_tdata),
    .cos_tvalid(cos_tvalid),

    .sig_sin_tdata(sig_sin_tdata),
    .sig_sin_tvalid(),
    .sig_cos_tdata(sig_cos_tdata),
    .sig_cos_tvalid(),

    .mix_i_tdata(mix_i_tdata),
    .mix_i_tvalid(mix_i_tvalid),
    .mix_q_tdata(mix_q_tdata),
    .mix_q_tvalid(mix_q_tvalid),

    .mix_i_lpf_tdata(mix_i_lpf_tdata),
    .mix_i_lpf_tvalid(mix_i_lpf_tvalid),
    .mix_q_lpf_tdata(mix_q_lpf_tdata),
    .mix_q_lpf_tvalid(mix_q_lpf_tvalid),

    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_freq_tdata(),
    .m_axis_freq_tvalid(),

    .lock_flag_o(lock_flag_o),
    .ttl_edge_o(ttl_edge_o),
    .ttl_valid_o(),
    .nco_sync_o(),
    .ref_edge_pll(ref_edge_pll),
    .nco_edge_pll(nco_edge_pll)
  );

  // ---------------- Clock Generator ----------------
  always #(CLK_PERIOD/2) clk = ~clk;

  // ---------------- Mathematical Simulation Variables ----------------
  real fs;                  // Sampling Frequency (125 MHz)
  real sim_freq;            // Target Input frequency to simulate (e.g., 500 kHz)
  real sim_phase_rad;       // Phase accumulator tracker
  real dynamic_phase_shift; // Simulated phase drift relative to the reference
  real signal_amplitude;    // Peak simulated analog voltage scale
  
  real pi;
  
  // ============================================================
  // Filter tuning variables
  // ============================================================
  real cutoff_freq;
  real alpha;
  
  // NEW: Real helpers to map out boxcar properties in the testbench
  real target_window_time;
  real time_per_sample;
  real tau;
  real temp_dec;
  real temp_settle;

  // ============================================================
  // Function : Convert floating point to fixed-point coefficient
  // ============================================================
  function signed [24:0] real_to_q24;
    input real x;
    real temp;
    begin
      temp = x * (2.0**24);
      real_to_q24 = $rtoi(temp);
    end
  endfunction
  
  function signed [25:0] real_to_q25;
    input real x;
    real temp;
    begin
      temp = x * (2.0**25);
      real_to_q25 = $rtoi(temp);
    end
  endfunction
  
  // ============================================================
  // Real-time Magnitude Monitoring (Integer Format)
  // ============================================================
  reg signed [31:0] R_pre_int;
  reg signed [31:0] R_post_int;

  always @(posedge clk) begin
    if (rstn) begin
      R_pre_int  <= $rtoi($sqrt($itor($signed(mix_i_tdata)) * $itor($signed(mix_i_tdata)) + 
                                $itor($signed(mix_q_tdata)) * $itor($signed(mix_q_tdata))));
                            
      R_post_int <= $rtoi($sqrt($itor($signed(mix_i_lpf_tdata)) * $itor($signed(mix_i_lpf_tdata)) + 
                                $itor($signed(mix_q_lpf_tdata)) * $itor($signed(mix_q_lpf_tdata))));
    end else begin
      R_pre_int  <= 32'sd0;
      R_post_int <= 32'sd0;
    end
  end

  // ---------------- Stimulus Generation ----------------
  initial begin
    // Setup system constants
    clk = 0;
    rstn = 0;
    pi = 3.141592653589793;
    fs = 125.0e6;
    
    // Choose a distinct test frequency
    sim_freq = 45000.0; 
    sim_phase_rad = 0.0;
    dynamic_phase_shift = 0.0; 
    signal_amplitude = 25000.0; 

    adc_in_tdata = 0;
    adc_in_tvalid = 0;
    ref_in_tdata = 0;
    ref_in_tvalid = 1;

    amp_ctrl_i = 16'sd32767; // Unity gain coefficient
    use_pll_i = 1;

    // High Pass Filter: Configured to BYPASS (No low cut)
    hpf_aa_i = 18'sd0;
    hpf_pp_i = 25'sd0;
    hpf_kk_i = 25'sd16777215; // 1.0 scaled up to 2^24 precision

    // Low Pass Filter Cutoff Setup
    cutoff_freq = 1000.0;
    alpha = 1.0 - $exp(-2.0 * 3.1415926535 * cutoff_freq / fs);
    lpf_aa_i = real_to_q25(alpha);      
    lpf_pp_i = 25'sd0;
    lpf_kk_i = real_to_q24(alpha);    

    // ============================================================
    // NEW: MATCHING TESTBENCH MATH FOR THE DYNAMIC BOXCAR ENGINE
    // ============================================================
    tau = 1.0 / cutoff_freq;
    time_per_sample    = tau / 16384.0; // 2^14 fixed depth
    temp_dec           = time_per_sample * fs;
    
    if (temp_dec < 1.0) 
      decimation_rate_i = 32'd1;
    else 
      decimation_rate_i = $rtoi(temp_dec);

    // Compute hardware settling clock tracking threshold (4 * Tau)
    temp_settle  = 4.0 * tau * fs;
    settling_samples_i = $rtoi(temp_settle);

    // Configure the Free running frequency registry 
    // 450 kHz tuning word equivalent -> (450,000 * 2^46) / 125,000,000
    {ftw_free_high_i, ftw_free_low_i} = 46'd253327479039;

    #100;
    rstn = 1;
    adc_in_tvalid = 1;

    // ---------------- Main Run Loop ----------------
    repeat (10000000) begin
      @(posedge clk);
      
      // 1. Advance the mathematical phase vector
      sim_phase_rad = sim_phase_rad + (2.0 * pi * sim_freq / fs);
      if (sim_phase_rad >= 2.0 * pi) begin
          sim_phase_rad = sim_phase_rad - (2.0 * pi);
      end
      
      // 2. Synthesize a clean analog-equivalent ADC Input signal
      adc_in_tdata = $rtoi(signal_amplitude * $sin(sim_phase_rad + dynamic_phase_shift));
      
      // 3. Synthesize the clean, matching TTL Reference square wave 
      if (sim_phase_rad < pi)
          ref_in_tdata = 1'b1;
      else
          ref_in_tdata = 1'b0;
    end

    #1000;
    $display("Simulation successfully complete. Check internal IQ filter outputs.");
    $finish;
  end

endmodule
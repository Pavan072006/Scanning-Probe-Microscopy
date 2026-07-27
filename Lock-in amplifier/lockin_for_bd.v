module lockin #(
  parameter FCW      = 46,
  parameter ADC_W    = 16,
  parameter COEFF_W  = 25,
  parameter DEC_BITS = 8
)(
  input clk,
  input rstn,

  input  signed [ADC_W-1:0] adc_in_tdata,
  input                     adc_in_tvalid,
  input                     ref_in_tdata,  // ttl
  input                     ref_in_tvalid,

  input signed [15:0] amp_ctrl_i,
  input               use_pll_i,

  input signed [18-1:0] hpf_aa_i,
  input signed [COEFF_W-1:0] hpf_pp_i,
  input signed [COEFF_W-1:0] hpf_kk_i,

  input signed [18-1:0] lpf_aa_i,
  input signed [COEFF_W-1:0] lpf_pp_i,
  input signed [COEFF_W-1:0] lpf_kk_i,

  input [31:0] ftw_free_low_i,
  input [13:0] ftw_free_high_i,
  
  input [31:0] decimation_rate_i,   // Number of clock cycles between boxcar samples
  input [31:0] settling_samples_i,  // 4 * Time Constant mapped to exact clock count from Python
  
  output                    ftw_free_ttl_o,
  output signed [ADC_W-1:0] sin_tdata,
  output                    sin_tvalid,
  output signed [ADC_W-1:0] cos_tdata,
  output                    cos_tvalid,

  output signed [ADC_W-1:0] sig_sin_tdata,
  output                    sig_sin_tvalid,
  output signed [ADC_W-1:0] sig_cos_tdata,
  output                    sig_cos_tvalid,

  output signed [ADC_W-1:0] mix_i_tdata,
  output                    mix_i_tvalid,
  output signed [ADC_W-1:0] mix_q_tdata,
  output                    mix_q_tvalid,

  output signed [ADC_W-1:0] mix_i_lpf_tdata,
  output                    mix_i_lpf_tvalid,
  output signed [ADC_W-1:0] mix_q_lpf_tdata,
  output                    mix_q_lpf_tvalid,

  output [63:0] m_axis_tdata,
  output        m_axis_tvalid,
  output [63:0] m_axis_freq_tdata,
  output        m_axis_freq_tvalid,

  output lock_flag_o,
  output ttl_edge_o,
  output ttl_valid_o,
  output nco_sync_o,
  output ref_edge_pll,
  output nco_edge_pll
);

  // ============================================================
  // PARAMETERS / GLOBAL REGS
  // ============================================================

  localparam DDS_LATENCY = 8;
  localparam TTL_LATENCY = 6;
  localparam GW = 32;

  reg signed [GW-1:0] kp_sel = 32'sd300000000;//32'sd1610612736;
  reg signed [GW-1:0] ki_sel = 32'sd150000000;//32'sd107374182;

  reg [FCW-1:0] ftw_free_reg;
  reg [FCW-1:0] ftw_selected;
  wire [FCW-1:0] ftw_pll;
  wire           up_act;
  wire           dn_act;
  wire           q_up;
  wire           q_dn;
  wire signed [FCW-1:0] corr;

  reg [3:0] init_cnt;
  reg data_valid;

  // ============================================================
  // INPUT VALID PIPELINE
  // ============================================================

  always @(posedge clk) begin
    if (!rstn || !adc_in_tvalid) begin
      init_cnt   <= 0;
      data_valid <= 0;
    end else begin
      if (init_cnt < 4)
        init_cnt <= init_cnt + 1;
      if (init_cnt == 3)
        data_valid <= 1;
    end
  end

  // ============================================================
  // HPF (unused for now)
  // ============================================================

  wire signed [ADC_W-1:0] adc_hpf_out;
  wire hpf_tvalid;

  reg signed [COEFF_W-1:0] hpf_aa_r, hpf_pp_r, hpf_kk_r;
  reg hpf_reset_req;

  localparam COEFF_ONE = 25'shFFFFFF;

  wire hpf_coeff_changed =
    (hpf_aa_i != hpf_aa_r) ||
    (hpf_pp_i != hpf_pp_r) ||
    (hpf_kk_i != hpf_kk_r);

  always @(posedge clk) begin
    if (!rstn) begin
      hpf_aa_r <= 0;
      hpf_pp_r <= COEFF_ONE;
      hpf_kk_r <= 0;
      hpf_reset_req <= 0;
    end else begin
      hpf_aa_r <= hpf_aa_i;
      hpf_pp_r <= hpf_pp_i;
      hpf_kk_r <= hpf_kk_i;
      hpf_reset_req <= hpf_coeff_changed;
    end
  end

  wire hpf_rstn = rstn & ~hpf_reset_req;

  red_pitaya_lpf_block #(
    .ADC_W(ADC_W),
    .COEFF_W(COEFF_W),
    .HIGHPASS(1)
  ) u_hpf (
    .clk(clk),
    .rstn(hpf_rstn),
    .signal_in_tvalid(data_valid),
    .signal_in_tdata(adc_in_tdata),
    .signal_out_tdata(adc_hpf_out),
    .cfg_aa_i(hpf_aa_r),
    .cfg_pp_i(hpf_pp_r),
    .cfg_kk_i(hpf_kk_r),
    .signal_out_tvalid(hpf_tvalid)
  );

  reg signed [ADC_W-1:0] adc_reg;

  always @(posedge clk) begin
    if (!rstn)
      adc_reg <= 0;
    else if (hpf_tvalid)
      adc_reg <= adc_in_tdata;
  end

  // ============================================================
  // ZCD + REF ALIGN
  // ============================================================

  dig_edge_detect #(
    .N_DEBOUNCE(3),
    .DEAD_CYCLES(30)
  ) u_edge (
    .clk(clk),
    .rstn(rstn),
    .valid_i(1'b1),
    .sig_i(ref_in_tdata),
    .edge_o(ttl_edge_o),
    .valid_o(ttl_valid_o)
  );

  reg [DDS_LATENCY-1:0] ref_edge_pipe;

  always @(posedge clk) begin
    if (!rstn)
      ref_edge_pipe <= 0;
    else
      ref_edge_pipe <= {ref_edge_pipe[DDS_LATENCY-2:0], ttl_edge_o};
  end

  wire ref_edge_aligned = ref_edge_pipe[DDS_LATENCY-1];

  // ============================================================
  // COARSE FREQUENCY ESTIMATION
  // ============================================================

  localparam [FCW+1:0] K_PHASE_SCALE = 48'd70368744177664;

  reg [31:0] period_cnt;
  wire [31:0] period_avg;

  always @(posedge clk) begin
    if (!rstn) begin
      period_cnt <= 0;
    end else if (ttl_valid_o) begin
      if (ttl_edge_o)
        period_cnt <= 1;
      else
        period_cnt <= period_cnt + 1;
    end
  end
  
  reg [31:0] period_sum;
  reg [31:0] period_fifo [0:7];
  reg [2:0] wr_ptr;
  integer j;

  always @(posedge clk) begin
    if (!rstn) begin
      period_sum <= 0;
      wr_ptr <= 0;
      for (j = 0; j < 8; j = j + 1)
        period_fifo[j] <= 0;
    end else if (ttl_edge_o) begin
      // subtract oldest, add newest
      period_sum <= period_sum - period_fifo[wr_ptr] + period_cnt;
      // store new value
      period_fifo[wr_ptr] <= period_cnt;
      // increment pointer
      wr_ptr <= wr_ptr + 1;
    end
  end
  
  reg [4:0] avg_valid_cnt;
  wire avg_valid;

  always @(posedge clk) begin
    if (!rstn)
      avg_valid_cnt <= 0;
    else if (ttl_edge_o && avg_valid_cnt != 9)
      avg_valid_cnt <= avg_valid_cnt + 1;
  end

  assign avg_valid = (avg_valid_cnt >= 9);
  wire [31:0] period_avg_raw = period_sum >> 3;
  assign period_avg = avg_valid ? period_avg_raw : 0;

  wire div_valid;
  wire [FCW+1:0] div_quotient;
  wire div_start = ttl_edge_o && (period_avg != 0);

  div_gen_0 u_divider (
    .aclk(clk),
    .aresetn(rstn),
    .s_axis_dividend_tvalid(div_start),
    .s_axis_dividend_tdata(K_PHASE_SCALE),
    .s_axis_divisor_tvalid(div_start),
    .s_axis_divisor_tdata(period_avg),
    .m_axis_dout_tvalid(div_valid),
    .m_axis_dout_tdata(div_quotient)
  );

  reg [FCW-1:0] ftw_est;
  reg ftw_est_valid;

  always @(posedge clk) begin
    if (!rstn) begin
      ftw_est <= 0;
      ftw_est_valid <= 0;
    end else if (div_valid) begin
      ftw_est <= div_quotient[FCW-1:0];
      ftw_est_valid <= 1;
    end
  end

  // ============================================================
  // COARSE UPDATE DETECTION
  // ============================================================

  reg [FCW-1:0] ftw_diff, ftw_thresh;
  reg coarse_raw;

  always @(posedge clk) begin
    if (!rstn) begin
      ftw_diff <= 0;
      ftw_thresh <= 0;
    end else if (ftw_est_valid) begin
      ftw_diff <= (ftw_est > ftw_pll) ? (ftw_est - ftw_pll) : (ftw_pll - ftw_est);
      ftw_thresh <= ftw_est >> 7;
    end
  end

  always @(posedge clk) begin
    if (!rstn)
      coarse_raw <= 0;
    else if (ftw_est_valid)
      coarse_raw <= (ftw_diff > ftw_thresh);
  end

  reg [1:0] coarse_count;
  wire coarse_update_final;
  reg coarse_update_prev;

  always @(posedge clk) begin
    if (!rstn) begin
      coarse_count <= 0;
      coarse_update_prev <= 0;
    end else begin
      if (coarse_raw) begin
        if (~coarse_update_final) 
          coarse_count <= coarse_count + 1;
      end else
        coarse_count <= 0;
      coarse_update_prev <= coarse_update_final;
    end
  end
  
  assign coarse_update_final = (coarse_count == 2);
  wire phase_align_active = (~coarse_update_final) & coarse_update_prev;

  // ============================================================
  // DDS + PHASE RESET
  // ============================================================

  wire [103:0] dds_i;
  wire [31:0] dds_o;
  wire dds_valid;

  reg arm_phase_reset;

  always @(posedge clk) begin
    if (!rstn)
      arm_phase_reset <= 0;
    else if (phase_align_active)
      arm_phase_reset <= 1;
    else if (arm_phase_reset && ttl_edge_o)
      arm_phase_reset <= 0;
  end

  wire dds_phase_reset = arm_phase_reset && ttl_edge_o;

  reg [DDS_LATENCY-1:0] dds_reset_pipe;

  always @(posedge clk) begin
    if (!rstn)
      dds_reset_pipe <= 0;
    else
      dds_reset_pipe <= {dds_reset_pipe[DDS_LATENCY-2:0], dds_phase_reset};
  end

  wire dds_reset_aligned = dds_reset_pipe[DDS_LATENCY-1];

  assign dds_i[45:0]   = ftw_selected;
  assign dds_i[47:46]  = 0;
  assign dds_i[93:48]  = 0;
  assign dds_i[95:94]  = 0;
  assign dds_i[96]     = dds_phase_reset;
  assign dds_i[103:97] = 0;

  dds_compiler_0 u_dds (
    .aclk(clk),
    .s_axis_phase_tvalid(1'b1),
    .s_axis_phase_tdata(dds_i),
    .m_axis_data_tdata(dds_o),
    .m_axis_data_tvalid(dds_valid)
  );

  assign cos_tdata = dds_o[15:0];
  assign sin_tdata = dds_o[31:16];
  assign cos_tvalid = dds_valid;
  assign sin_tvalid = dds_valid;

  // ============================================================
  // NCO SYNC
  // ============================================================

  reg sin_msb_prev, nco_sync_r;

  always @(posedge clk) begin
    if (!rstn)
      sin_msb_prev <= 0;
    else if (sin_tvalid)
      sin_msb_prev <= sin_tdata[ADC_W-1];
  end

  assign nco_sync_o = (~sin_tdata[ADC_W-1]) && sin_msb_prev;

  // ============================================================
  // PLL CONTROL
  // ============================================================

  reg pll_rst, pll_enable, seen_dds_reset;
  reg [FCW-1:0] ftw_base;

  always @(posedge clk) begin
    if (!rstn)
      pll_rst <= 1;
    else if (coarse_update_final)
      pll_rst <= 1;
    else
      pll_rst <= 0;
  end

  always @(posedge clk) begin
    if (!rstn)
      seen_dds_reset <= 0;
    else if (dds_phase_reset)
      seen_dds_reset <= 1;
    else if (pll_enable)
      seen_dds_reset <= 0;
  end

  always @(posedge clk) begin
    if (!rstn)
      pll_enable <= 0;
    else if (coarse_update_final)
      pll_enable <= 0;
    else if (seen_dds_reset && dds_reset_aligned)
      pll_enable <= 1;
  end

  assign ref_edge_pll = pll_enable ? ref_edge_aligned : 0;
  assign nco_edge_pll = pll_enable ? nco_sync_o : 0;

  always @(posedge clk) begin
    if (!rstn)
      ftw_base <= ftw_free_reg;
    else if (coarse_update_final)
      ftw_base <= ftw_est;
  end

  adpll #(
    .FTW_W(FCW),
    .GAIN_W(GW),
    .FRAC_MIN(25),
    .ERR_W(32),
    .FRAC(15)
  ) u_adpll (
    .clk(clk),
    .rstn(rstn & ~pll_rst),
    .ref_edge(ref_edge_pll),
    .dco_edge(nco_edge_pll),
    .kp(kp_sel),
    .ki(ki_sel),
    .ftw_base(ftw_base),
    .period_avg(period_avg),
    .ftw_out(ftw_pll),
    .lock_flag(lock_flag_o),
    .up_act_o (up_act),
    .dn_act_o (dn_act),
    .q_up_o   (q_up),
    .q_dn_o   (q_dn),
    .corr_o   (corr)
  );

  // ============================================================================
  // FTW SELECTOR (coarse / fine / free-running) 
  // ============================================================================

  reg  [31:0] ftw_free_low;
  reg  [13:0] ftw_free_high;

  wire [FCW-1:0] ftw_free_reg_next;

  always @(posedge clk) begin
    if (!rstn) begin
        ftw_free_low    <= 32'sd0;      // full scale
        ftw_free_high   <= 14'sd0;
    end else begin
        ftw_free_low    <= ftw_free_low_i;
        ftw_free_high   <= ftw_free_high_i;
    end
  end
  
  // Combine high + low parts into full FTW
  assign ftw_free_reg_next = {ftw_free_high, ftw_free_low};

  // Register free-running FTW
  always @(posedge clk) begin
      if (!rstn)
          ftw_free_reg <= 46'd5629499534;  // 10 kHz default
      else
          ftw_free_reg <= ftw_free_reg_next;
  end
  
  reg [FCW-1:0] phase_acc_free;

  always @(posedge clk) begin
    if (!rstn)
      phase_acc_free <= {FCW{1'b0}};
    else
      phase_acc_free <= phase_acc_free + ftw_free_reg;
  end
  
  assign ftw_free_ttl_o = phase_acc_free[FCW-1];
  
  localparam [1:0] FTW_FREE = 2'd0;
  localparam [1:0] FTW_EST  = 2'd1;
  localparam [1:0] FTW_PLL  = 2'd2;
  reg [1:0] ftw_mode;

  // Final FTW selection
  always @(posedge clk) begin
      if (!rstn) begin
          ftw_selected <= 46'd5629499534;  // 10 kHz default
          ftw_mode     <= FTW_FREE;
      end else if (!use_pll_i) begin
          ftw_selected <= ftw_free_reg;     // Free running
          ftw_mode     <= FTW_FREE;
      end else if (coarse_update_final) begin
          ftw_selected <= ftw_est;          // Coarse override
          ftw_mode     <= FTW_EST;
      end else begin
          ftw_selected <= ftw_pll;          // Fine PLL
          ftw_mode     <= FTW_PLL;
      end
  end

  // ============================================================================
  // Amplitude scaling
  // ============================================================================

  reg  signed [31:0] sig_sin_scaled;
  reg  signed [31:0] sig_cos_scaled;
  reg signed [15:0] amp_reg;
  always @(posedge clk) begin
    if (!rstn)
      amp_reg    <= 16'sd32767;      // full scale
    else
      amp_reg    <= amp_ctrl_i;
  end
  
  always @(posedge clk) begin
    if (!rstn) begin
      sig_sin_scaled <= 32'sd0;
      sig_cos_scaled <= 32'sd0;
    end else begin
      sig_sin_scaled <= sin_tdata * amp_reg;
      sig_cos_scaled <= cos_tdata * amp_reg;
    end
  end

  assign sig_sin_tdata = sig_sin_scaled[30:15];
  assign sig_sin_tvalid = dds_valid;
  assign sig_cos_tdata = sig_cos_scaled[30:15];
  assign sig_cos_tvalid = dds_valid;
  
  // ============================================================================
  // MIXING
  // ============================================================================

  reg signed [ADC_W-1:0] adc_pipe [0:DDS_LATENCY+TTL_LATENCY-1];
  integer i;

  always @(posedge clk) begin
    if (!rstn) begin
      for (i = 0; i < DDS_LATENCY+TTL_LATENCY; i = i + 1)
        adc_pipe[i] <= 0;
    end else begin
      adc_pipe[0] <= adc_in_tdata;
      for (i = 1; i < DDS_LATENCY+TTL_LATENCY; i = i + 1)
        adc_pipe[i] <= adc_pipe[i-1];
    end
  end

  wire signed [ADC_W-1:0] adc_aligned = adc_pipe[DDS_LATENCY+TTL_LATENCY-1];
  
  reg [DDS_LATENCY+TTL_LATENCY-1:0] valid_pipe;

  always @(posedge clk) begin
    if (!rstn)
      valid_pipe <= 0;
    else
      valid_pipe <= {valid_pipe[DDS_LATENCY+TTL_LATENCY-2:0], data_valid};
  end
  
  wire data_valid_aligned = valid_pipe[DDS_LATENCY+TTL_LATENCY-1];
  
  reg signed [31:0] prod_i;
  reg signed [31:0] prod_q;
  reg               mix_valid;

  always @(posedge clk) begin
    if (!rstn) begin
      prod_i <= 32'sd0;
      prod_q <= 32'sd0;
      mix_valid <= 1'b0;
    end else if (dds_valid && data_valid_aligned) begin
      // Use upper 14 bits of sin/cos
      prod_i <= sin_tdata * adc_aligned;
      prod_q <= cos_tdata * adc_aligned;
      mix_valid <= dds_valid && data_valid_aligned;
    end
  end

  assign mix_i_tdata = prod_i[30:15];
  assign mix_q_tdata = prod_q[30:15];
  assign mix_i_tvalid = mix_valid;
  assign mix_q_tvalid = mix_valid;

  // ============================================================================
  // LPF (dfilt1) for I/Q channels
  // ============================================================================

  wire signed [ADC_W-1:0] mix_i_lpf;
  wire signed [ADC_W-1:0] mix_q_lpf;
  wire                    mix_i_lpf_valid_w;
  wire                    mix_q_lpf_valid_w;

  reg signed [COEFF_W-1:0] lpf_aa_r;
  reg signed [COEFF_W-1:0] lpf_pp_r;
  reg signed [COEFF_W-1:0] lpf_kk_r;
  reg lpf_reset_req;
  wire lpf_coeff_changed;

  assign lpf_coeff_changed = (lpf_aa_i != lpf_aa_r) || (lpf_pp_i != lpf_pp_r) || (lpf_kk_i != lpf_kk_r);
  
  // Register coefficients
  always @(posedge clk) begin
    if (!rstn) begin
      lpf_aa_r <= 0;
      lpf_pp_r <= 0;
      lpf_kk_r <= COEFF_ONE;
      lpf_reset_req <= 1'b0;
    end else begin
      lpf_aa_r <= lpf_aa_i;
      lpf_pp_r <= lpf_pp_i;
      lpf_kk_r <= lpf_kk_i;
      lpf_reset_req <= lpf_coeff_changed;
    end
  end
  
  wire lpf_rstn;
  assign lpf_rstn = rstn & ~lpf_reset_req;

  // ---- I-channel LPF ----

  red_pitaya_lpf_block #(
      .ADC_W    (ADC_W),
      .COEFF_W  (COEFF_W),
      .HIGHPASS (0)
  ) i_lpf (
      .clk    (clk),
      .rstn   (lpf_rstn),
      .signal_in_tvalid  (mix_i_tvalid),
      .signal_in_tdata (mix_i_tdata),
      .signal_out_tdata (mix_i_lpf),
      .cfg_aa_i (lpf_aa_r),
      .cfg_pp_i (lpf_pp_r),
      .cfg_kk_i (lpf_kk_r),
      .signal_out_tvalid  (mix_i_lpf_valid_w)
  );

  // ---- Q-channel LPF ----

  red_pitaya_lpf_block #(
      .ADC_W    (ADC_W),
      .COEFF_W  (COEFF_W),
      .HIGHPASS (0)
  ) q_lpf (
      .clk      (clk),
      .rstn     (lpf_rstn),
      .signal_in_tvalid  (mix_q_tvalid),
      .signal_in_tdata (mix_q_tdata),
      .signal_out_tdata (mix_q_lpf),
      .cfg_aa_i (lpf_aa_r),
      .cfg_pp_i (lpf_pp_r),
      .cfg_kk_i (lpf_kk_r),
      .signal_out_tvalid  (mix_q_lpf_valid_w)
  );
  
  // ============================================================================
  // DYNAMIC POWER-OF-TWO BOXCAR AVERAGER
  // ============================================================================
  
  // Hardwired to 2^14 depth (16,384 elements). Safe and optimized for BRAM synthesis.
  localparam MAX_SHIFT_BITS = 14;
  localparam WINDOW_SIZE    = 16384;
  
  (* ram_style = "block" *) reg signed [ADC_W-1:0] i_buffer [0:WINDOW_SIZE-1];
  (* ram_style = "block" *) reg signed [ADC_W-1:0] q_buffer [0:WINDOW_SIZE-1];
  reg [MAX_SHIFT_BITS-1:0] buffer_ptr;
  
  // Initialize Block RAM arrays to zero for clean simulation/power-up
  integer idx;
  initial begin
    for (idx = 0; idx < WINDOW_SIZE; idx = idx + 1) begin
      i_buffer[idx] = 0;
      q_buffer[idx] = 0;
    end
  end

  reg signed [31:0] i_sum;
  reg signed [31:0] q_sum;
  
  // --- Clock Enable (CE) Decimation Sub-sampler Engine ---
  reg [31:0] sample_rate_counter;
  reg        sample_strobe_ce;

  always @(posedge clk) begin
    if (!lpf_rstn) begin
      sample_rate_counter <= 0;
      sample_strobe_ce    <= 0;
    end else if (mix_i_lpf_valid_w) begin
      if (sample_rate_counter >= decimation_rate_i - 1) begin
        sample_rate_counter <= 0;
        sample_strobe_ce    <= 1; // Drop down-sample tick
      end else begin
        sample_rate_counter <= sample_rate_counter + 1;
        sample_strobe_ce    <= 0;
      end
    end else begin
      sample_strobe_ce <= 0;
    end
  end

  // Pipeline registers to cleanly capture synchronous RAM output ports
  reg signed [ADC_W-1:0] i_old_data;
  reg signed [ADC_W-1:0] q_old_data;
  reg signed [ADC_W-1:0] i_input_reg;
  reg signed [ADC_W-1:0] q_input_reg;
  reg                    sum_update_en;
  reg                    avg_out_valid_r;

  // Fixed division holding registers
  reg signed [ADC_W-1:0] avg_i_out;
  reg signed [ADC_W-1:0] avg_q_out;

  // Pipelined ring-buffer execution
  always @(posedge clk) begin
    if (!lpf_rstn) begin
      buffer_ptr      <= 0;
      i_sum           <= 0;
      q_sum           <= 0;
      i_old_data      <= 0;
      q_old_data      <= 0;
      i_input_reg     <= 0;
      q_input_reg     <= 0;
      sum_update_en   <= 0;
      avg_out_valid_r <= 0;
      avg_i_out       <= 0;
      avg_q_out       <= 0;
    end else begin
      // Step 1: Address lookup trigger
      if (sample_strobe_ce) begin
        buffer_ptr   <= buffer_ptr + 1;
        i_input_reg  <= mix_i_lpf;
        q_input_reg  <= mix_q_lpf;
        sum_update_en<= 1;
      end else begin
        sum_update_en<= 0;
      end

      // Step 2: RAM read completes. Update accumulator and output registers.
      if (sum_update_en) begin
        i_old_data <= i_buffer[buffer_ptr];
        q_old_data <= q_buffer[buffer_ptr];

        i_sum <= i_sum + i_input_reg - i_old_data;
        q_sum <= q_sum + q_input_reg - q_old_data;

        i_buffer[buffer_ptr] <= i_input_reg;
        q_buffer[buffer_ptr] <= q_input_reg;
        
        // These update ONLY when a new calculation happens, holding their value in between
        avg_i_out       <= (i_sum + i_input_reg - i_old_data) >> MAX_SHIFT_BITS; 
        avg_q_out       <= (q_sum + q_input_reg - q_old_data) >> MAX_SHIFT_BITS;
        avg_out_valid_r <= 1;
      end else begin
        avg_out_valid_r <= 0; // Strobe drops back to 0 on the next cycle
      end
    end
  end

  // ============================================================================
  // AUTOMATED SETTLING DETECTION TIMING CONTROLLER
  // ============================================================================
  reg [31:0] settling_timer;
  reg        lock_state;

  always @(posedge clk) begin
    if (!rstn) begin
      settling_timer <= 0;
      lock_state     <= 0;
    end else if (lpf_coeff_changed) begin
      settling_timer <= 0;
      lock_state     <= 0; // Turn off Lock LED immediately on change
    end else begin
      if (settling_timer < settling_samples_i) begin
        settling_timer <= settling_timer + 1;
        lock_state     <= 0;
      end else begin
        lock_state     <= 1; // 4 Time constants have passed -> Lock LED turned ON
      end
    end
  end

  assign lock_flag_o = lock_state;
  
  // ============================================================================
  // OUTPUT FOR OSCILLOSCOPE
  // ============================================================================

//  assign mix_i_lpf_tdata = mix_i_lpf_tvalid ? mix_i_lpf : adc_reg;
//  assign mix_q_lpf_tdata = mix_q_lpf_tvalid ? mix_q_lpf : adc_reg;
  assign mix_i_lpf_tvalid = mix_i_lpf_valid_w;
  assign mix_q_lpf_tvalid = mix_q_lpf_valid_w;
  assign mix_i_lpf_tdata = avg_i_out;
  assign mix_q_lpf_tdata = avg_q_out;
  
//  assign m_axis_tvalid = avg_out_valid_r;
//  assign m_axis_freq_tvalid = avg_out_valid_r;
  assign m_axis_tvalid = mix_i_lpf_tvalid;
  assign m_axis_freq_tvalid = mix_i_lpf_tvalid;
// Pack channel data for complete Python Vector Amplitude Processing
  assign m_axis_tdata = {
    mix_q_lpf,            // [63:48] Filtered Q component
    mix_i_lpf,            // [47:32] Filtered I component
    adc_aligned,          // [31:16] Phase-matched raw signal input
    sin_tdata            // [15:0]  Captures NCO current processing tracking phase
  };

// Pack frequency tracking alongside the mixer's internal reference oscillator
  assign m_axis_freq_tdata = {
    period_avg[15:0],     // [63:48] Period avg used for frequency estimation
    ref_edge_pll,         // [47]    Reference edge
    nco_edge_pll,         // [46]    NCO edge
    ftw_selected          // [45:0]  Current fine tuning execution value
  };
    
  
endmodule
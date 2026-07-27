`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// DIGITAL PLL (ADPLL)
// -----------------------------------------------------------------------------
// Features:
//   - Pulse-width PFD (UP/DN counters)
//   - Fixed-point PI controller (Q format)
//   - Multi-stage pipelined datapath
//   - FTW correction for NCO
// -----------------------------------------------------------------------------

module adpll #(
  parameter int FTW_W  = 24,                 // FTW width (NCO word)
  parameter int GAIN_W = 24,                 // width of loop gain inputs (kp, ki)
  parameter int FRAC_MIN   = 25,             // fractional bits in gain*error products (for pterm and iterm_incr)
  parameter int ERR_W  = 25,                 // error counter width (clk cycles)
  parameter int FRAC = 19
)(
  input  logic               clk,
  input  logic               rstn,
  // Edges from reference and DCO (single-cycle pulses, async to each other OK)
  input  logic               ref_edge,
  input  logic               dco_edge,

  // Loop gains (fixed-point signed Q[GAIN_W-FRAC-1].[FRAC])
  input  logic signed [GAIN_W-1:0] kp,
  input  logic signed [GAIN_W-1:0] ki,

  // Base FTW and loop outputs
  input  logic  [FTW_W-1:0]  ftw_base,
  input  logic  [31-1:0]     period_avg,
   
  output logic  [FTW_W-1:0]  ftw_out,
  output logic               lock_flag,
  
  output logic               up_act_o,
  output logic               dn_act_o,
  output logic               q_up_o,
  output logic               q_dn_o,
  output logic signed [FTW_W-1:0] corr_o
);

  // ===============================================================================================================
  // 1. EDGE DETECTION (ref_edge / dco_edge -> single-cycle pulses)
  // ===============================================================================================================
  logic ref_d, dco_d;
  logic ref_p, dco_p;

  always_ff @(posedge clk) begin
    ref_d <= ref_edge;
    dco_d <= dco_edge;
  end
  
  assign ref_p = ref_edge & ~ref_d;
  assign dco_p = dco_edge & ~dco_d;

  // ================================================================================================================
  // 2. PULSE-WIDTH PFD (RS latch based UP/DN measurement window)  PFD: Phase Frequency Detector, RS: Reset Set latch
  // ================================================================================================================
  logic q_up, q_dn;
  
  always_ff @(posedge clk) begin
    if (!rstn) begin
      q_up <= 1'b0;
      q_dn <= 1'b0;
    end else begin
      if (ref_p) q_up <= 1'b1;
      if (dco_p) q_dn <= 1'b1;

      // Reset when both have occurred (one-clock overlap)
      if (q_up & q_dn) begin
        q_up <= 1'b0;
        q_dn <= 1'b0;
      end
    end
  end

  // Indicates active UP/DN pulses
  wire up_act = q_up & ~q_dn;   // ref leads dco
  wire dn_act = q_dn & ~q_up;   // dco leads ref
  
  assign q_up_o = q_up;
  assign q_dn_o = q_dn;
  assign up_act_o = up_act;
  assign dn_act_o = dn_act;

  // =================================================================================================================
  // 3. MEASURE PULSE WIDTHS AND GENERATE SIGNED ERROR
  // =================================================================================================================
  logic [ERR_W-1:0] up_cnt, dn_cnt;
  logic meas_prev_both, meas_both, meas_done;

  // "both high" appears for one clock before reset above; detect rising edge
  assign meas_both = q_up & q_dn;
  always_ff @(posedge clk) begin
    if (!rstn)      meas_prev_both <= 1'b0;
    else          meas_prev_both <= meas_both;
  end
  assign meas_done = meas_both & ~meas_prev_both;  // strobe once per comparison

  // pipeline versions of meas_done
  logic meas_d1, meas_d2, meas_d3, meas_d4;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      meas_d1 <= 1'b0;
      meas_d2 <= 1'b0;
      meas_d3 <= 1'b0;
      meas_d4 <= 1'b0;
    end else begin
      meas_d1 <= meas_done;
      meas_d2 <= meas_d1;
      meas_d3 <= meas_d2;
      meas_d4 <= meas_d3;
    end
  end
  
  // Count pulse widths while active; reset when a measurement completes
  always_ff @(posedge clk) begin
    if (!rstn || meas_done) begin
      up_cnt <= '0;
      dn_cnt <= '0;
    end else begin
      if (up_act  && ~&up_cnt) up_cnt <= up_cnt + 1'b1;
      if (dn_act  && ~&dn_cnt) dn_cnt <= dn_cnt + 1'b1;
    end
  end

  // Latch signed error at meas_done: positive => ref leads, negative => dco leads
  logic signed [ERR_W:0]   e;  // one more bit for signed diff
  logic signed [ERR_W:0]   e_prev;
  logic signed [ERR_W:0]   delta_e;
  logic        [ERR_W-1:0] thresh;
  
  assign thresh = period_avg >> 1;
  logic signed [ERR_W+8:0] slip_accum;
  logic signed [ERR_W:0]   e_unwrapped;
  
  logic cycle_slip;
  
  always_ff @(posedge clk) begin
    if (!rstn)
      e <= '0;
    else if (meas_done) begin
      e_prev <= e;
      e <= $signed({1'b0,up_cnt}) - $signed({1'b0,dn_cnt});
    end
  end
  
  always_ff @(posedge clk) begin
    if (!rstn)
      delta_e <= '0;
    else if (meas_d1)
      delta_e <= e - e_prev;
  end
  
  always_ff @(posedge clk) begin
    if (!rstn) begin
      e_prev <= '0;
      slip_accum <= '0;
    end else if (meas_d2) begin      
      //Detect slip
      if (($signed(delta_e) > $signed(thresh)) || ($signed(delta_e) < -$signed(thresh))) begin
        //Positive wrap -> subtract one period
        slip_accum <= e_unwrapped;
        cycle_slip <= 1'b1;
      end else
        cycle_slip <= 1'b0;
    end
  end
        
  always_ff @(posedge clk) begin
    if (!rstn)
      e_unwrapped <= '0;
    else if (meas_d3)
      e_unwrapped <= e + slip_accum;
  end    

  // ========================================================================================================================
  // 4. PI CONTROLLER , MULTIPLIERS (Stage 1)
  // ========================================================================================================================

  // ------------------------
  // PI controller (fixed-point)
  //   p = (kp * e) >> FRAC
  //   i += (ki * e) >> FRAC
  //   u = p + i
  // ------------------------
  // Mult widths: (GAIN_W x (ERR_W+1)) -> (GAIN_W+ERR_W+1)
  
  localparam int MUL_W = GAIN_W + ERR_W + 1;
  
  // ----- Stage 1: multipliers -----
  logic signed [MUL_W-1:0] kp_e_r, ki_e_r;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      kp_e_r <= '0;
      ki_e_r <= '0;
    end else if (meas_done) begin
      kp_e_r <= $signed(kp) * $signed(e_unwrapped);
      ki_e_r <= $signed(ki) * $signed(e_unwrapped);
    end
  end

  // =========================================================================================================================
  // 5. FIXED-POINT SHIFTING (Stage 2)
  // =========================================================================================================================
  localparam int MAX_P_W = MUL_W - FRAC_MIN;
    
  // ----- Stage 2: fixed shifts -> pterm, iterm_incr -----
  logic signed [MAX_P_W-1:0] pterm_r, iterm_incr_r;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      pterm_r      <= '0;
      iterm_incr_r <= '0;
    end else if (meas_d1) begin
      pterm_r      <= $signed(kp_e_r) >>> FRAC;
      iterm_incr_r <= $signed(ki_e_r) >>> FRAC;
    end
  end

  // ==========================================================================================================================
  // 6. INTEGRATOR WIDTH SATURATION (Stage 3)
  // ==========================================================================================================================
  localparam int I_W = MAX_P_W + 8;   // +8 guard bits for safety
  logic signed [I_W-1:0] iterm;

  // Saturating add helper
  function automatic logic signed [I_W-1:0] sat_add_I
  (
    input logic signed [I_W-1:0] a,
    input logic signed [I_W-1:0] b
  );
    logic signed [I_W:0] tmp;
    begin
      tmp = $signed(a) + $signed(b);
      // saturate to I_W
      if (tmp[I_W] != tmp[I_W-1])
        sat_add_I = tmp[I_W] ? {1'b1,{(I_W-1){1'b0}}} : {1'b0,{(I_W-1){1'b1}}};
      else
        sat_add_I = tmp[I_W-1:0];
    end
  endfunction
  
  always_ff @(posedge clk) begin
    if (!rstn) begin
      iterm <= '0;
    end else if (meas_d2) begin
      // sign-extend iterm_incr_r to I_W
      logic signed [I_W-1:0] iterm_incr_ext;
      iterm_incr_ext = {{(I_W-MAX_P_W){iterm_incr_r[MAX_P_W-1]}}, iterm_incr_r};
      if (cycle_slip)
        iterm <= iterm;  // hold
      else
        iterm <= sat_add_I(iterm - (iterm >>> 10), iterm_incr_ext); // leaky integrator with 10-bit shift leak; prevents overshoot and helps stability
      //iterm <= sat_add_I(iterm - (iterm >>> 10), iterm_incr_ext); //iterm <= sat_add_I(iterm, iterm_incr_ext);
    end
  end

  // ===========================================================================================================================
  // 7. SUM P + I TO FORM CONTROLLER OUTPUT u (Stage 4)
  // ===========================================================================================================================
  localparam int U_W = I_W + 1;
  
  // ----- Stage 4: u = p + i -----
  logic signed [U_W-1:0] u;
  always_ff @(posedge clk) begin
    if (!rstn) begin
      u <= '0;
    end else if (meas_d3) begin
      logic signed [U_W-1:0] pterm_ext, iterm_ext;
      pterm_ext = {{(U_W-MAX_P_W){pterm_r[MAX_P_W-1]}}, pterm_r};
      iterm_ext = {{(U_W-I_W)    {iterm[I_W-1]}},       iterm};
      u <= pterm_ext + iterm_ext;
    end
  end

  // ===========================================================================================================================
  // 8. MAP CONTROLLER OUTPUT u ? FTW CORRECTION (Stage 5)
  // ===========================================================================================================================

  // ------------------------
  // Map controller output -> FTW correction
  // You can treat SHIFT_U2FTW as loop "gain" knob (coarser than kp/ki).
  // ------------------------
  localparam int SHIFT_U2FTW = 3; //2 // divide u by 2^8 before adding to FTW
  localparam int CORR_W = U_W - SHIFT_U2FTW;
  
  // ----- Stage 5: map u -> FTW and update ftw_out -----
  logic signed [CORR_W-1:0] corr;
  logic signed [FTW_W:0]    sum;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      ftw_out <= ftw_base;
    end else if (meas_d4) begin
      logic signed [FTW_W:0] corr_ext;
      corr = $signed(u) >>> SHIFT_U2FTW;
      corr_ext = {{(FTW_W+1-CORR_W){corr[CORR_W-1]}}, corr};

      sum = $signed({1'b0,ftw_base}) + corr_ext;
     
      if (sum[FTW_W])           ftw_out <= {FTW_W{1'b0}}; // underflow
      else if (&sum[FTW_W-1:0]) ftw_out <= {FTW_W{1'b1}}; // overflow
      else                      ftw_out <= sum[FTW_W-1:0];
    end
  end
  
  assign corr_o = corr;

endmodule
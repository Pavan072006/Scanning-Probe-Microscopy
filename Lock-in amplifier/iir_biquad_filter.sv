`timescale 1ns / 1ps

module biquad_iir #(
  parameter ADC_W  = 14,
  parameter COEF_W = 32,
  parameter ACC_W  = 48
)(
  input  logic clk,
  input  logic rstn,

  input  logic sample_en,   // ONE global enable

  input  logic signed [ADC_W-1:0]  x_in,
  output logic signed [ADC_W-1:0]  y_out,

  input  logic signed [COEF_W-1:0] a1, a2,
  input  logic signed [COEF_W-1:0] b0, b1, b2
);

  // --------------------------------------------------
  // Enable pipeline (tracks sample through stages)
  // --------------------------------------------------
  logic en_s0 = '0;
  logic en_s1 = '0; 
  logic en_s2 = '0;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      en_s0 <= 1'b0;
      en_s1 <= 1'b0;
      en_s2 <= 1'b0;
    end else begin
      en_s0 <= sample_en;
      en_s1 <= en_s0;
      en_s2 <= en_s1;
    end
  end

  // --------------------------------------------------
  // Delay registers (sample domain, NOT clock domain)
  // --------------------------------------------------
  logic signed [ADC_W-1:0] x0, x1;
  logic signed [ACC_W-1:0] y1, y2;

  // --------------------------------------------------
  // Stage 1: multiplier outputs (registered)
  // --------------------------------------------------
  logic signed [ADC_W+COEF_W-1:0] mb0, mb1, mb2, b_q;
  logic signed [ACC_W+COEF_W-1:0] ma1, ma2, a_q;

  // --------------------------------------------------
  // Stage 2: accumulator
  // --------------------------------------------------
  logic signed [ACC_W-1:0] acc;

  // =========================
  // Stage 0: multipliers
  // =========================
  always_ff @(posedge clk) begin
    if (!rstn) begin
      x0 <= '0; x1 <= '0;
      mb0 <= '0; mb1 <= '0; mb2 <= '0;
      ma1 <= '0; ma2 <= '0;
    end else if (en_s0) begin
      mb0 <= b0 * x_in;
      mb1 <= b1 * x0;
      mb2 <= b2 * x1;
      ma1 <= a1 * acc;
      ma2 <= a2 * y1;
      x0 <= x_in;
      x1 <= x0;
    end
  end

  // =========================
  // Stage 1: adders
  // =========================
  always_ff @(posedge clk) begin
    if (!rstn) begin
      b_q <= '0; a_q <= '0;
      y1 <= '0;
    end else if (en_s1) begin
      b_q <= mb0 + mb1 + mb2;
      a_q <= ma1 + ma2;      
      y1 <= acc;
    end
  end

  // =========================
  // Stage 2: accumulate
  // =========================
  always_ff @(posedge clk) begin
    if (!rstn) begin
      acc   <= '0;
      y_out <= '0;
    end else if (en_s2) begin
      acc <= b_q - (a_q >>> (COEF_W-2));

      y_out <= acc >>> (COEF_W-2);
    end
  end

endmodule
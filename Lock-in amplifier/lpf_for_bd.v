`timescale 1ns / 1ps

module red_pitaya_lpf_block #(
    parameter      COEFF_W  = 25,
    parameter      ADC_W    = 16,
    parameter      HIGHPASS = 0
)(
   input                        clk ,  // ADC clock
   input                        rstn,  // ADC reset - active low
   input                        signal_in_tvalid,
   input  signed [ADC_W-1:0]    signal_in_tdata,   // ADC data
   output signed [ADC_W-1:0]    signal_out_tdata,  // ADC data
   // configuration
   input  signed [18-1:0]       cfg_aa_i,  // AA coefficient
   input  signed [COEFF_W-1:0]  cfg_pp_i,  // PP coefficient
   input  signed [COEFF_W-1:0]  cfg_kk_i,  // KK coefficient
   output                       signal_out_tvalid
);

// Configuration registers
reg signed [18-1:0]      cfg_aa_reg;
reg signed [COEFF_W-1:0] cfg_kk_reg;

always @(posedge clk) begin
    if (!rstn) begin
        cfg_aa_reg <= 0;
        cfg_kk_reg <= 0;
    end else begin
        cfg_aa_reg <= cfg_aa_i;
        cfg_kk_reg <= cfg_kk_i;
    end
end

//---------------------------------------------------------------------------------
// 2-Cycle Execution Control
//---------------------------------------------------------------------------------
reg phase; // 0: Multiply cycle, 1: Accumulate/Update cycle

always @(posedge clk) begin
    if (!rstn) begin
        phase <= 1'b0;
    end else if (signal_in_tvalid || phase == 1'b1) begin
        phase <= ~phase; // Alternates back and forth
    end
end

//---------------------------------------------------------------------------------
// IIR 1: Multi-cycle Implementation
//---------------------------------------------------------------------------------
// Full 48-bit accumulator to handle low cutoffs without rounding issues
reg signed [60-1:0] r3_sum_reg; 

// Extract the 23-bit upper slice for the multiplier (matching your original math)
wire signed [35-1:0] r3_reg_dsp1 = r3_sum_reg >>> 25;

// Pipeline register to hold the multiplication result across the cycle boundary
(* use_dsp="yes" *) reg signed [53-1:0] aa_mult_reg;

// Capture the input data on cycle 0 so it stays perfectly stable for cycle 1
reg signed [ADC_W-1:0] signal_in_latched;

always @(posedge clk) begin
    if (!rstn) begin
        aa_mult_reg        <= 0;
        signal_in_latched  <= 0;
    end else if (phase == 1'b0 && signal_in_tvalid) begin
        // Cycle 0: Calculate the multiplication and store it
        aa_mult_reg        <= r3_reg_dsp1 * cfg_aa_reg;
        signal_in_latched  <= signal_in_tdata;
    end
end

// Combinatorial evaluation for the accumulation
wire signed [60-1:0] r3_sum_next;
assign r3_sum_next = (signal_in_latched <<< 25) + (r3_sum_reg) - aa_mult_reg;

always @(posedge clk) begin
    if (!rstn) begin
        r3_sum_reg <= 0;
    end else if (phase == 1'b1) begin
        // Cycle 1: Add/Subtract the terms and update the main loop state
        r3_sum_reg <= r3_sum_next;
    end
end

//---------------------------------------------------------------------------------
//  Scaling Stage
//---------------------------------------------------------------------------------
reg signed [60-1:0] kk_mult;
reg signed [ADC_W-1:0] r5_reg;

// Extract full 23-bit registered state for scaling output
wire signed [35-1:0] r3_reg_dsp2 = r3_sum_reg >>> 25;

// MUX selection: If cfg_aa_reg is 0, we select the raw latched input signal 
// and sign-extend it to match the 35-bit size of the scaling multiplier input.
// This isolatest the cfg_aa_reg comparison routing delay from the kk_mult multiplier.
reg signed [35-1:0] scaling_input_reg;

always @(posedge clk) begin
    if (!rstn) begin
        scaling_input_reg <= 0;
    end else if (phase == 1'b0) begin
        // Latch the bypass decision on phase 0 so it's perfectly ready for phase 1
        if (cfg_aa_reg == 18'sd0)
            scaling_input_reg <= $signed(signal_in_latched);
        else
            scaling_input_reg <= r3_reg_dsp2;
    end
end
                                     
always @(posedge clk) begin
    if (!rstn) begin
        kk_mult <= 0;
    end else if (phase == 1'b1) begin
        // Start scaling multiplier right after the state updates
        kk_mult <= scaling_input_reg * cfg_kk_reg;
    end
end

// Saturation logic to prevent clipping wrap-around errors
always @(posedge clk) begin
    if (!rstn) begin
        r5_reg <= 0;
    end else if (phase == 1'b0) begin 
        // Latch final output on the alternative cycle
        if ((kk_mult >>> (COEFF_W-1)) > $signed(16'sd32767)) 
            r5_reg <= 16'sd32767;
        else if ((kk_mult >>> (COEFF_W-1)) < $signed(-16'sd32768)) 
            r5_reg <= -16'sd32768;
        else 
            r5_reg <= kk_mult >>> 24;
    end
end

//---------------------------------------------------------------------------------
// Highpass / Lowpass Selection Pipeline
//---------------------------------------------------------------------------------
reg signed [ADC_W-1:0] input_d1, input_d2, input_d3;

always @(posedge clk) begin
    if (!rstn) begin
        input_d1 <= 0;
        input_d2 <= 0;
        input_d3 <= 0;
    end else if (phase == 1'b1) begin
        input_d1 <= signal_in_latched;
        input_d2 <= input_d1;
        input_d3 <= input_d2; // Aligned cleanly with processing latency
    end
end

generate
    if (HIGHPASS == 0)
        assign signal_out_tdata = r5_reg;
    else
        assign signal_out_tdata = input_d3 - r5_reg;
endgenerate

//---------------------------------------------------------------------------------
// Valid Pipeline (Stays high for 2 consecutive cycles to reflect the output data)
//---------------------------------------------------------------------------------
reg out_valid_reg;

always @(posedge clk) begin
    if (!rstn) begin
        out_valid_reg <= 1'b0;
    end else begin
        // Output is fully calculated and valid whenever phase returns to 0
        if (phase == 1'b1) 
            out_valid_reg <= 1'b1;
        else if (!signal_in_tvalid)
            out_valid_reg <= 1'b0;
    end
end

assign signal_out_tvalid = out_valid_reg;

endmodule
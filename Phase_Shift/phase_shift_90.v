`timescale 1ns / 1ps

module phase_shift_90 #(
    parameter DATA_WIDTH    = 16,
    parameter MAX_DELAY     = 1024   // max possible delay (buffer size)
)(
    input  clk,
    input  rstn,
    input  signed [DATA_WIDTH-1:0] adc_in_tdata,
    input                          adc_in_tvalid,
    input  [15:0]                  delay_cycles_i,   // from Python via AXI GPIO
    output signed [DATA_WIDTH-1:0] shifted_tdata,
    output                         shifted_tvalid
);

    reg signed [DATA_WIDTH-1:0] shift_reg [0:MAX_DELAY-1];
    reg [15:0] delay_cycles;
    integer i;

    // Register the delay value to avoid glitches mid-shift
    always @(posedge clk) begin
        if (!rstn)
            delay_cycles <= 458;   // default 458 cycles
        else
            delay_cycles <= delay_cycles_i;
    end

    always @(posedge clk) begin
        if (!rstn) begin
            for (i = 0; i < MAX_DELAY; i = i + 1)
                shift_reg[i] <= 0;
        end else if (adc_in_tvalid) begin
            shift_reg[0] <= adc_in_tdata;
            for (i = 1; i < MAX_DELAY; i = i + 1)
                shift_reg[i] <= shift_reg[i-1];
        end
    end

    assign shifted_tdata  = shift_reg[delay_cycles];
    assign shifted_tvalid = adc_in_tvalid;

endmodule
`timescale 1ns / 1ps

module PTN (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [31:0] addrb,    // address we want to read
    input  wire [31:0] doutb,    // data coming back from BRAM
    output reg   enb,
    output reg   [3:0] web,
    output reg   rstb,
    output reg   [31:0] dinb,
    // Only need to READ from BRAM - just doutb comes in

    // LED is the only output
    output reg         led
);

    always @(posedge clk or negedge rst_n) begin
        
        if (!rst_n) begin
            led   <= 1'b0;
            addrb <= 32'd0;
        rstb <= 0;
        web <= 4'd0;
        dinb <= 32'd0;
        enb <= 1;
        
            
        end
        else begin
        addrb <= 32'd0;
        rstb <= 0;
        web <= 4'd0;
        dinb <= 32'd0;
        enb <= 1;
           
            if (doutb == 32'h0000_0001)
                led <= 1'b1;
            else
                led <= 1'b0;
        end
    end

endmodule
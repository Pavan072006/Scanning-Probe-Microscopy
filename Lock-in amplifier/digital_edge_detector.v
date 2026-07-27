module dig_edge_detect #(
    parameter integer N_DEBOUNCE = 3,
    parameter integer DEAD_CYCLES = 30
)(
    input  wire clk,
    input  wire rstn,
    input  wire valid_i,
    input  wire sig_i,

    output wire edge_o,
    output wire valid_o
);

    // ---------------- Sync ----------------
    reg s0, s1;
    always @(posedge clk) begin
        if (!rstn) begin
            s0 <= 0; s1 <= 0;
        end else begin
            s0 <= sig_i;
            s1 <= s0;
        end
    end

    // ---------------- Debounce ----------------
    reg [N_DEBOUNCE-1:0] sr;
    always @(posedge clk) begin
        if (!rstn)
            sr <= 0;
        else if (valid_i)
            sr <= {sr[N_DEBOUNCE-2:0], s1};
    end

    wire stable_hi = &sr;
    wire stable_lo = ~|sr;

    reg clean;
    always @(posedge clk) begin
        if (!rstn)
            clean <= 0;
        else if (valid_i) begin
            if (stable_hi) clean <= 1;
            else if (stable_lo) clean <= 0;
        end
    end

    // ---------------- Edge detect ----------------
    reg prev;
    always @(posedge clk) begin
        if (!rstn)
            prev <= 0;
        else if (valid_i)
            prev <= clean;
    end

    wire rise = clean & ~prev;

    // ---------------- Dead time ----------------
    reg [$clog2(DEAD_CYCLES+1)-1:0] cnt;
    reg dead;

    always @(posedge clk) begin
        if (!rstn) begin
            dead <= 0;
            cnt  <= 0;
        end else begin
            if (dead) begin
                if (cnt == 0)
                    dead <= 0;
                else
                    cnt <= cnt - 1;
            end else if (rise && valid_i) begin
                dead <= 1;
                cnt  <= DEAD_CYCLES;
            end
        end
    end

    // ---------------- Output ----------------
    reg edge_r;
    always @(posedge clk) begin
        if (!rstn)
            edge_r <= 0;
        else
            edge_r <= rise && !dead && valid_i;
    end

    assign edge_o  = edge_r;
    assign valid_o = valid_i;

endmodule
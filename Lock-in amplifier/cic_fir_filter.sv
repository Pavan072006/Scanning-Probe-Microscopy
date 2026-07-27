`timescale 1ns / 1ps

module filter_test #(
  parameter int FCW            = 46,  // phase word width
  parameter int ADC_W          = 14,  // ADC data width
  parameter int COEF_W         = 32  // filter coefficient width
)(
  // clock / reset
  input  logic                 clk_i,      // NCO clock (use adc_clk)
  input  logic                 rstn_i,     // active low reset (adc_rstn)

  // ADC sampled input
  input  logic signed [ADC_W-1:0] adc_in,

  // outputs: oscillator and mixer
  output logic signed [13:0]   wave_o,
  
  // for oscilloscope capture
  output logic signed [13:0]   wave_lpf_o,    // filtered I
  output logic                 dac_valid,
  
  // system bus interface
  input      [31:0]            sys_addr,
  input      [31:0]            sys_wdata,
  input                        sys_wen,
  input                        sys_ren,
  output logic [31:0]          sys_rdata,
  output logic                 sys_err,
  output logic                 sys_ack
);
  
  logic signed [ADC_W-1:0] adc_reg;//, adc_hpf_stage1, adc_hpf_stage2;
  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      adc_reg <= '0;
    end else begin
      adc_reg <= adc_in;
    end
  end

  // ============================================================================
  // 10. ADDING
  // ============================================================================
  
  assign wave_o = adc_reg;
  
  // ============================================================
  // CIC wires
  // ============================================================
  logic signed [48:0] cic_out;
  logic signed [13:0] cic_scaled;
  logic cic_valid;
  
  // ============================================================
  // CIC instance
  // ============================================================
  cic_compiler_0 cic_inst (
    .aclk(clk_i),
    .aresetn(rstn_i),

    .s_axis_data_tvalid(1'b1),
    .s_axis_data_tdata(wave_o),

    .m_axis_data_tvalid(cic_valid),
    .m_axis_data_tdata(cic_out)
  );
  
  // ============================================================
  // FIR wires
  // ============================================================
  //logic signed [64:0] fir1_out, fir2_out;
  logic signed [32:0] fir1_out, fir2_out;
  logic fir1_valid, fir2_valid;
  logic signed [14:0] fir1_scaled;
  
  localparam signed [ADC_W-1:0] ADC_MAX =  14'sd8191;
  localparam signed [ADC_W-1:0] ADC_MIN = -14'sd8192;
  
  // ============================================================
  // FIR instance (CIC compensation)
  // ============================================================
  assign cic_scaled = cic_out >>> 35;
  
  fir_compiler_2 fir_inst_1 (
    .aclk(clk_i),
    .aresetn(rstn_i),

    .s_axis_data_tvalid(cic_valid),
    .s_axis_data_tdata(cic_scaled),

    .m_axis_data_tvalid(fir1_valid),
    .m_axis_data_tdata(fir1_out)
  );
  
  assign fir1_scaled = fir1_out >>> 17;
  
  fir_compiler_3 fir_inst_2 (
    .aclk(clk_i),
    .aresetn(rstn_i),

    .s_axis_data_tvalid(fir1_valid),
    .s_axis_data_tdata(fir1_scaled),

    .m_axis_data_tvalid(fir2_valid),
    .m_axis_data_tdata(fir2_out)
  );
  
  // ============================================================================
  // Output select (IIR only or IIR ? FIR)
  // ============================================================================

  logic decim;
//  logic signed [43:0] dac_scaled;
  logic signed [16:0] dac_scaled;
  logic signed [13:0] dac_sat;
  
//  assign dac_scaled = fir2_out >>> 51;
  assign dac_scaled = fir2_out >>> 16;
  assign dac_sat =
      (dac_scaled > ADC_MAX) ? ADC_MAX :
      (dac_scaled < ADC_MIN) ? ADC_MIN :
                               dac_scaled[ADC_W-1:0];

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      wave_lpf_o <= '0;
      dac_valid  <= '0;
    end else begin
      if (!decim) begin
        if (fir2_valid) begin
          wave_lpf_o <= dac_sat;
          dac_valid  <= 1'b1;
        end else
          dac_valid <= 1'b0;
//      end else
//        wave_lpf_o <= fir1_out_r;
//        //dac_valid  <= fir1_valid;
//        dac_valid  <= decim1_en_r;
      end
    end
  end

  // ============================================================================
  // 13. System Bus: Readout of I/Q
  // ============================================================================
 
  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      decim      <= 1'b0;
    end else begin
      if (sys_wen) begin

        case (sys_addr[19:0])

          20'h00034: decim   <= sys_wdata[0];
          
        endcase
      end
    end
  end

  // sysbus read (write path is unused, same as your original)
  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      sys_err   <= 1'b0;
      sys_ack   <= 1'b0;
      sys_rdata <= 32'h0;
    end else begin
      sys_err <= 1'b0;
      sys_ack <= (sys_wen | sys_ren);   // acknowledge any access
      case (sys_addr[19:0])
      
        20'h00034: sys_rdata = {31'd0, decim};
        
        default:   sys_rdata <= 32'h0;
      endcase
    end
  end

endmodule
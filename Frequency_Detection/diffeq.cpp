#include <hls_stream.h>
#include <ap_int.h>
#include <ap_axi_sdata.h>

#define DECIMATE 125
#define SAMPLES 1250000000   // 125MHz → 1MHz

void double_derivative_top(
    hls::stream< ap_axis<16,0,0,0> > &adc_data,
    ap_int<64>                        *num_out,
    ap_int<64>                        *den_out,
    ap_uint<16>                        mul
) {

#pragma HLS INTERFACE axis      port=adc_data
#pragma HLS INTERFACE s_axilite port=num_out  bundle=CTRL_BUS
#pragma HLS INTERFACE s_axilite port=den_out  bundle=CTRL_BUS
#pragma HLS INTERFACE s_axilite port=mul      bundle=CTRL_BUS
#pragma HLS INTERFACE s_axilite port=return   bundle=CTRL_BUS

    ap_int<16>  x0=0, x1=0, x2=0, x3=0, x4=0;
    ap_int<64>  num = 0;
    ap_int<64>  den = 0;
    ap_uint<4>  count = 0;
    ap_uint<8>  dec_count = 0;        // decimation counter
    ap_axis<16,0,0,0> temp;


    for (int k = 0; k<= SAMPLES -1; k++) {
        #pragma HLS PIPELINE II=1
        temp = adc_data.read();


            // only every 125th sample feeds the derivative
            x0 = x1; x1 = x2; x2 = x3; x3 = x4;
            x4 = (ap_int<16>)temp.data;

            if (count >= 4) {
                ap_int<32> xdd = (ap_int<32>)x4
                               - ((ap_int<32>)x2 << 1)
                               + (ap_int<32>)x0;
                ap_int<32> xc   = (ap_int<32>)x2;
                ap_int<32> xddr = xdd;

                num += (ap_int<64>)xddr * (ap_int<64>)xc;
                den += (ap_int<64>)xc   * (ap_int<64>)xc;
            } else {
                count++;
            }


        if (temp.last) break;
    }

    *num_out = -num;
    *den_out =  den;
}

# PYNQ LED Blink (BRAM Controlled)

## Overview
This project demonstrates an LED blinking system on a PYNQ-Zynq FPGA board using a BRAM-based interface between the Processing System (PS) and Programmable Logic (PL). A Jupyter Notebook is used to control the hardware through a Vivado-generated overlay.

---

## Hardware Design
- AXI-connected BRAM used for PS–PL communication  
- Python (PYNQ) writes data to BRAM  
- FPGA logic reads BRAM and drives LED output  
- Vivado Block Design used to generate bitstream and hardware interface  

---

## Project Files
- `Blink.ipynb` → Jupyter Notebook for control  
- `Blink_wrapper.bit` → FPGA bitstream  
- `Blink_wrapper.hwh` → PYNQ hardware metadata  
- `Blink_wrapper.v` → Top-level wrapper module
- `Block Diagram.png` → Vivado system architecture diagram showing PS–PL communication through AXI BRAM for LED control
- `const.xdc` → FPGA pin constraints  
- `PTN.v` → Custom RTL for LED logic  


---

## Requirements
- PYNQ-Z1 / PYNQ-Z2 (or compatible Zynq board)  
- Xilinx Vivado Design Suite  
- PYNQ Linux image with Jupyter Notebook  

---

## Result
The LED toggles ON and OFF periodically based on values written into BRAM from Python running on the Processing System.

---

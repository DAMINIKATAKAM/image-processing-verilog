# Image processing pipeline - simulation with Icarus Verilog
#   make                          -> process images/input.bmp in all 8 modes
#   make IMAGE=images/photo.bmp   -> use your own picture
#   make clean

RTL   = rtl/image_proc.v
TB    = tb/tb_image_proc.v
IMAGE ?= images/input.bmp

sim:
	mkdir -p build output
	iverilog -g2005 -Wall -o build/tb.out $(RTL) $(TB)
	cd build && vvp tb.out +IMAGE=../$(IMAGE)

synth:
	yosys -p "read_verilog $(RTL); synth -top image_proc; stat"

clean:
	rm -rf build output

.PHONY: sim synth clean

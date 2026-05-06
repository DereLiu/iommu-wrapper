#########################################################################################
# pre-process iommu into a single blackbox file
#########################################################################################

iommu_blocks_dir := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# zero-day-labs 
IOMMU_TYPE ?= zerodaylabs
IOMMU_NAME = riscv_iommu

# path to use synthesis or fpga rams
# either "fpga/model" or "synth"
IOMMU_RAMS ?= fpga/model

# name of output pre-processed verilog file
PREPROC_VERILOG_DIR = $(iommu_blocks_dir)
PREPROC_VERILOG = $(PREPROC_VERILOG_DIR)/$(IOMMU_NAME).preprocessed.sv

.PHONY: default $(PREPROC_VERILOG)
default: $(PREPROC_VERILOG)

#########################################################################################
# includes and vsrcs
#########################################################################################

lookup_srcs = $(shell find -L $(1)/ -name target -prune -o -iname "*.$(2)" -print 2> /dev/null)

VLOG_DIR = $(iommu_blocks_dir)/vsrc

include $(iommu_blocks_dir)/vsrc.mk

ALL_VSRCS = \
	$(iommu_vsrcs)

INC_DIRS = \
	$(iommu_blocks_dir)/vsrc/packages/dependencies \
	$(iommu_blocks_dir)/vsrc/include \
	$(iommu_blocks_dir)/vsrc/include/common_cells \

#########################################################################################
# pre-process using custom script to replace the includes (but leave rest unaffected)
#########################################################################################

PREPROC_SCRIPT = $(iommu_blocks_dir)/../../../../../scripts/insert-includes.py

$(PREPROC_VERILOG): $(ALL_VSRCS)
	mkdir -p $(dir $(PREPROC_VERILOG))
	echo "\`define CF_MATH_PKG_DEF" > defs.v
	echo "\`define CVA6_CONFIG" >> defs.v
	cat defs.v $(ALL_VSRCS) > combined.sv
	$(PREPROC_SCRIPT) combined.sv $@ $(INC_DIRS)
	rm -rf combined.sv defs.v guard_undefs.v

clean:
	rm -rf $(iommu_blocks_dir)/*.preprocessed.sv

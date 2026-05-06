# list of srcs for zerodaylabs configurations of IOMMU
# note: bulk includes all files in vsrc/*/ doesn't work since some of the files have syntax errors
#$(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/axi_pkg.sv) \
#$(wildcard $(iommu_blocks_dir)/vsrc/include/assertions.svh)	\
# use axi_pkg from the CVA6/CVA6CoreBlackbox bundle to avoid duplicate package definitions
IOMMU_RAM_SUBDIR = $(IOMMU_RAMS)
# $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/iommu_riscv_pkg.sv) \
# When set, include third-party dependency packages and vendor IPs inside the
# preprocessed bundle. This is useful for standalone builds. Chipyard defaults
# to sharing the copies provided by CVA6 to avoid duplicate definitions.
IOMMU_BUNDLE_DEPS ?= 0

# Always-present IOMMU-specific packages
iommu_pkg_vsrcs := \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/axi_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/ariane_soc_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/ariane_axi_soc_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/riscv_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/rv_iommu/rv_iommu_field_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/rv_iommu/rv_iommu_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/rv_iommu/rv_iommu_reg_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/ariane_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/ariane_dm_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/packages/dependencies/riscv_pkg.sv)
# Optional dependency packages that overlap with CVA6
#iommu_dep_vsrcs := \


# Headers/includes
iommu_include_vsrcs := \
 $(wildcard $(iommu_blocks_dir)/vsrc/include/axi/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/include/common_cells/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/include/register_interface/*)

# IOMMU-specific vendor files (must precede RTL that uses them)
iommu_vendor_vsrcs := \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/cf_math_pkg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/REG_BUS.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/apb_to_reg.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/fifo_v3.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/fifo_v2.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/fifo.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_single_slice.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_aw_buffer.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_ar_buffer.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_w_buffer.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_r_buffer.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_b_buffer.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi2apb_64_32.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/spill_register_flushable.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/spill_register.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_atop_filter.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_burst_splitter.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_err_slv.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/id_queue.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/onehot_to_bin.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/axi_demux.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/stream_register.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/stream_mux.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/vendor/stream_demux.sv)

# RTL proper
iommu_rtl_vsrcs := \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/rv_iommu_ddtc.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/rv_iommu_mrif_handler.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/rv_iommu_mrifc.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/rv_iommu_msiptw.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/rv_iommu_pdtc.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/iotlb/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/cdw/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/ptw/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/translation_logic/wrapper/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/rv_iommu_cq_handler.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/rv_iommu_fq_handler.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/rv_iommu_hpm.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/rv_iommu_msi_ig.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/rv_iommu_wsi_ig.sv) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/regmap/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/software_interface/wrapper/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/ext_interfaces/*) \
 $(wildcard $(iommu_blocks_dir)/vsrc/rtl/riscv_iommu.sv)

iommu_core_vsrcs := $(iommu_pkg_vsrcs) $(iommu_include_vsrcs) $(iommu_vendor_vsrcs) $(iommu_rtl_vsrcs)

ifeq ($(IOMMU_BUNDLE_DEPS),1)
 iommu_core_vsrcs := $(iommu_dep_vsrcs) $(iommu_core_vsrcs)
endif

iommu_vsrcs := $(iommu_core_vsrcs)
 

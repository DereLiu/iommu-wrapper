# IOMMU Wrapper

This wraps up the Zero-Day Labs RISC-V IOMMU
(https://github.com/zero-day-labs/riscv-iommu) into a Rocket Chip based
peripheral to be used in Chipyard.

The Zero-Day Labs RISC-V IOMMU is a SystemVerilog RTL implementation compliant
with the RISC-V IOMMU Specification v1.0. It provides I/O address translation
and permission checking for requests originated by bus master devices.

This wrapper adapts the Zero-Day Labs IOMMU IP to the Rocket Chip and Chipyard
infrastructure. It can be attached to a Chipyard-generated SoC and used to
support DMA isolation for DMA-capable devices such as accelerators.

## Chipyard Collateral

Please refer to the Chipyard integration files for more information on how to
build an SoC or FPGA image with the IOMMU Wrapper enabled.

## Based On

This work is based on the RISC-V IOMMU implementation from Zero-Day Labs:

- https://github.com/zero-day-labs/riscv-iommu

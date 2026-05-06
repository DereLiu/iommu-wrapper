// Flattened wrapper around the typed riscv_iommu top.
// This module exposes simple scalar/vector ports matching the Chisel BlackBox
// and packs/unpacks them to the typed struct ports expected by riscv_iommu.

`timescale 1ns/1ps

// Minimal register bus typedefs (addr/write/wdata/wstrb/valid) used across the IOMMU wrapper.
typedef struct packed {
    logic [31:0] addr;
    logic        write;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        valid;
} iommu_reg_req_t;

typedef struct packed {
    logic [31:0] rdata;
    logic        error;
    logic        ready;
} iommu_reg_rsp_t;

module riscv_iommu_flat #(
    // Number of IOTLB entries
    parameter int unsigned  IOTLB_ENTRIES       = 8,
    // Number of DDTC entries
    parameter int unsigned  DDTC_ENTRIES        = 4,
    // Number of PDTC entries
    parameter int unsigned  PDTC_ENTRIES        = 4,

    // Include process_id support
    parameter bit                   InclPC      = 1,
    // Include AXI4 address boundary check
    parameter bit                   InclBC      = 1,
    // Include debug register interface
    parameter bit                   InclDBG     = 1,
    // Include MSI translation support
    parameter bit                   InclMSITrans = 0,
    
    // Interrupt Generation Support (integer-coded: 0=MSI_ONLY,1=WSI_ONLY,2=BOTH)
    parameter int unsigned         IGS         = 1,
    // Number of interrupt vectors supported
    parameter int unsigned          N_INT_VEC   = 16,
    // Number of Performance monitoring event counters (set to zero to disable HPM)
    parameter int unsigned          N_IOHPMCTR  = 0,     // max 31

    /// AXI Bus Addr width.
    parameter int   ADDR_WIDTH      = 64,
    /// AXI Bus data width.
    parameter int   DATA_WIDTH      = 64,
    /// AXI ID width
    parameter int   ID_WIDTH        = 4,
    /// AXI Slave ID width
    parameter int   ID_SLV_WIDTH    = 4,
    /// AXI user width
    parameter int   USER_WIDTH      = 1
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Translation Request Interface (Slave) - flattened request + response
    input  logic [ID_WIDTH-1:0]       dev_tr_req_i_aw_id,
    input  logic [ADDR_WIDTH-1:0]     dev_tr_req_i_aw_addr,
    input  logic [7:0]                dev_tr_req_i_aw_len,
    input  logic [2:0]                dev_tr_req_i_aw_size,
    input  logic [1:0]                dev_tr_req_i_aw_burst,
    input  logic                      dev_tr_req_i_aw_lock,
    input  logic [3:0]                dev_tr_req_i_aw_cache,
    input  logic [2:0]                dev_tr_req_i_aw_prot,
    input  logic [3:0]                dev_tr_req_i_aw_qos,
    input  logic [3:0]                dev_tr_req_i_aw_region,
    input  logic [5:0]                dev_tr_req_i_aw_atop,
    input  logic [USER_WIDTH-1:0]     dev_tr_req_i_aw_user,
    input  logic                      dev_tr_req_i_aw_valid,
    input  logic [DATA_WIDTH-1:0]     dev_tr_req_i_w_data,
    input  logic [DATA_WIDTH/8-1:0]   dev_tr_req_i_w_strb,
    input  logic                      dev_tr_req_i_w_last,
    input  logic [USER_WIDTH-1:0]     dev_tr_req_i_w_user,
    input  logic                      dev_tr_req_i_w_valid,
    input  logic [ID_WIDTH-1:0]       dev_tr_req_i_ar_id,
    input  logic [ADDR_WIDTH-1:0]     dev_tr_req_i_ar_addr,
    input  logic [7:0]                dev_tr_req_i_ar_len,
    input  logic [2:0]                dev_tr_req_i_ar_size,
    input  logic [1:0]                dev_tr_req_i_ar_burst,
    input  logic                      dev_tr_req_i_ar_lock,
    input  logic [3:0]                dev_tr_req_i_ar_cache,
    input  logic [2:0]                dev_tr_req_i_ar_prot,
    input  logic [3:0]                dev_tr_req_i_ar_qos,
    input  logic [3:0]                dev_tr_req_i_ar_region,
    input  logic [USER_WIDTH-1:0]     dev_tr_req_i_ar_user,
    input  logic                      dev_tr_req_i_ar_valid,
    input  logic                      dev_tr_req_i_b_ready,
    input  logic                      dev_tr_req_i_r_ready,
    // IOMMU-extended AXI fields
    input  logic [23:0]               dev_tr_req_i_axMMUSID,
    input  logic [19:0]               dev_tr_req_i_axMMUSSID,
    input  logic                      dev_tr_req_i_axMMUSSIDV,
    // Device response (flattened)
    output logic                      dev_tr_resp_o_aw_ready,
    output logic                      dev_tr_resp_o_w_ready,
    output logic                      dev_tr_resp_o_ar_ready,
    output logic [ID_WIDTH-1:0]       dev_tr_resp_o_b_id,
    output logic [1:0]                dev_tr_resp_o_b_resp,
    output logic [USER_WIDTH-1:0]     dev_tr_resp_o_b_user,
    output logic                      dev_tr_resp_o_b_valid,
    output logic [ID_WIDTH-1:0]       dev_tr_resp_o_r_id,
    output logic [DATA_WIDTH-1:0]     dev_tr_resp_o_r_data,
    output logic [1:0]                dev_tr_resp_o_r_resp,
    output logic                      dev_tr_resp_o_r_last,
    output logic [USER_WIDTH-1:0]     dev_tr_resp_o_r_user,
    output logic                      dev_tr_resp_o_r_valid,

    // Translation Completion Interface (Master) - flattened resp in and req out
    input  logic                      dev_comp_resp_i_aw_ready,
    input  logic                      dev_comp_resp_i_w_ready,
    input  logic                      dev_comp_resp_i_ar_ready,
    input  logic [ID_WIDTH-1:0]       dev_comp_resp_i_b_id,
    input  logic [1:0]                dev_comp_resp_i_b_resp,
    input  logic [USER_WIDTH-1:0]     dev_comp_resp_i_b_user,
    input  logic                      dev_comp_resp_i_b_valid,
    input  logic [ID_WIDTH-1:0]       dev_comp_resp_i_r_id,
    input  logic [DATA_WIDTH-1:0]     dev_comp_resp_i_r_data,
    input  logic [1:0]                dev_comp_resp_i_r_resp,
    input  logic                      dev_comp_resp_i_r_last,
    input  logic [USER_WIDTH-1:0]     dev_comp_resp_i_r_user,
    input  logic                      dev_comp_resp_i_r_valid,
    output logic [ID_WIDTH-1:0]       dev_comp_req_o_aw_id,
    output logic [ADDR_WIDTH-1:0]     dev_comp_req_o_aw_addr,
    output logic [7:0]                dev_comp_req_o_aw_len,
    output logic [2:0]                dev_comp_req_o_aw_size,
    output logic [1:0]                dev_comp_req_o_aw_burst,
    output logic                      dev_comp_req_o_aw_lock,
    output logic [3:0]                dev_comp_req_o_aw_cache,
    output logic [2:0]                dev_comp_req_o_aw_prot,
    output logic [3:0]                dev_comp_req_o_aw_qos,
    output logic [3:0]                dev_comp_req_o_aw_region,
    output logic [5:0]                dev_comp_req_o_aw_atop,
    output logic [USER_WIDTH-1:0]     dev_comp_req_o_aw_user,
    output logic                      dev_comp_req_o_aw_valid,
    output logic [DATA_WIDTH-1:0]     dev_comp_req_o_w_data,
    output logic [DATA_WIDTH/8-1:0]   dev_comp_req_o_w_strb,
    output logic                      dev_comp_req_o_w_last,
    output logic [USER_WIDTH-1:0]     dev_comp_req_o_w_user,
    output logic                      dev_comp_req_o_w_valid,
    output logic [ID_WIDTH-1:0]       dev_comp_req_o_ar_id,
    output logic [ADDR_WIDTH-1:0]     dev_comp_req_o_ar_addr,
    output logic [7:0]                dev_comp_req_o_ar_len,
    output logic [2:0]                dev_comp_req_o_ar_size,
    output logic [1:0]                dev_comp_req_o_ar_burst,
    output logic                      dev_comp_req_o_ar_lock,
    output logic [3:0]                dev_comp_req_o_ar_cache,
    output logic [2:0]                dev_comp_req_o_ar_prot,
    output logic [3:0]                dev_comp_req_o_ar_qos,
    output logic [3:0]                dev_comp_req_o_ar_region,
    output logic [USER_WIDTH-1:0]     dev_comp_req_o_ar_user,
    output logic                      dev_comp_req_o_ar_valid,
    output logic                      dev_comp_req_o_b_ready,
    output logic                      dev_comp_req_o_r_ready,
    output logic [23:0]               dev_comp_req_o_axMMUSID,
    output logic [19:0]               dev_comp_req_o_axMMUSSID,
    output logic                      dev_comp_req_o_axMMUSSIDV,

    // Data Structures Interface (Master) - flattened resp in and req out
    input  logic                      ds_resp_i_aw_ready,
    input  logic                      ds_resp_i_w_ready,
    input  logic                      ds_resp_i_ar_ready,
    input  logic [ID_WIDTH-1:0]       ds_resp_i_b_id,
    input  logic [1:0]                ds_resp_i_b_resp,
    input  logic [USER_WIDTH-1:0]     ds_resp_i_b_user,
    input  logic                      ds_resp_i_b_valid,
    input  logic [ID_WIDTH-1:0]       ds_resp_i_r_id,
    input  logic [DATA_WIDTH-1:0]     ds_resp_i_r_data,
    input  logic [1:0]                ds_resp_i_r_resp,
    input  logic                      ds_resp_i_r_last,
    input  logic [USER_WIDTH-1:0]     ds_resp_i_r_user,
    input  logic                      ds_resp_i_r_valid,
    output logic [ID_WIDTH-1:0]       ds_req_o_aw_id,
    output logic [ADDR_WIDTH-1:0]     ds_req_o_aw_addr,
    output logic [7:0]                ds_req_o_aw_len,
    output logic [2:0]                ds_req_o_aw_size,
    output logic [1:0]                ds_req_o_aw_burst,
    output logic                      ds_req_o_aw_lock,
    output logic [3:0]                ds_req_o_aw_cache,
    output logic [2:0]                ds_req_o_aw_prot,
    output logic [3:0]                ds_req_o_aw_qos,
    output logic [3:0]                ds_req_o_aw_region,
    output logic [5:0]                ds_req_o_aw_atop,
    output logic [USER_WIDTH-1:0]     ds_req_o_aw_user,
    output logic                      ds_req_o_aw_valid,
    output logic [DATA_WIDTH-1:0]     ds_req_o_w_data,
    output logic [DATA_WIDTH/8-1:0]   ds_req_o_w_strb,
    output logic                      ds_req_o_w_last,
    output logic [USER_WIDTH-1:0]     ds_req_o_w_user,
    output logic                      ds_req_o_w_valid,
    output logic [ID_WIDTH-1:0]       ds_req_o_ar_id,
    output logic [ADDR_WIDTH-1:0]     ds_req_o_ar_addr,
    output logic [7:0]                ds_req_o_ar_len,
    output logic [2:0]                ds_req_o_ar_size,
    output logic [1:0]                ds_req_o_ar_burst,
    output logic                      ds_req_o_ar_lock,
    output logic [3:0]                ds_req_o_ar_cache,
    output logic [2:0]                ds_req_o_ar_prot,
    output logic [3:0]                ds_req_o_ar_qos,
    output logic [3:0]                ds_req_o_ar_region,
    output logic [USER_WIDTH-1:0]     ds_req_o_ar_user,
    output logic                      ds_req_o_ar_valid,
    output logic                      ds_req_o_b_ready,
    output logic                      ds_req_o_r_ready,
    output logic [23:0]               ds_req_o_axMMUSID,
    output logic [19:0]               ds_req_o_axMMUSSID,
    output logic                      ds_req_o_axMMUSSIDV,

    // Programming Interface (Slave) - flattened req in + resp out
    input  logic [ID_SLV_WIDTH-1:0]   prog_req_i_aw_id,
    input  logic [ADDR_WIDTH-1:0]     prog_req_i_aw_addr,
    input  logic [7:0]                prog_req_i_aw_len,
    input  logic [2:0]                prog_req_i_aw_size,
    input  logic [1:0]                prog_req_i_aw_burst,
    input  logic                      prog_req_i_aw_lock,
    input  logic [3:0]                prog_req_i_aw_cache,
    input  logic [2:0]                prog_req_i_aw_prot,
    input  logic [3:0]                prog_req_i_aw_qos,
    input  logic [3:0]                prog_req_i_aw_region,
    input  logic [5:0]                prog_req_i_aw_atop,
    input  logic [USER_WIDTH-1:0]     prog_req_i_aw_user,
    input  logic                      prog_req_i_aw_valid,
    input  logic [DATA_WIDTH-1:0]     prog_req_i_w_data,
    input  logic [DATA_WIDTH/8-1:0]   prog_req_i_w_strb,
    input  logic                      prog_req_i_w_last,
    input  logic [USER_WIDTH-1:0]     prog_req_i_w_user,
    input  logic                      prog_req_i_w_valid,
    input  logic [ID_SLV_WIDTH-1:0]   prog_req_i_ar_id,
    input  logic [ADDR_WIDTH-1:0]     prog_req_i_ar_addr,
    input  logic [7:0]                prog_req_i_ar_len,
    input  logic [2:0]                prog_req_i_ar_size,
    input  logic [1:0]                prog_req_i_ar_burst,
    input  logic                      prog_req_i_ar_lock,
    input  logic [3:0]                prog_req_i_ar_cache,
    input  logic [2:0]                prog_req_i_ar_prot,
    input  logic [3:0]                prog_req_i_ar_qos,
    input  logic [3:0]                prog_req_i_ar_region,
    input  logic [USER_WIDTH-1:0]     prog_req_i_ar_user,
    input  logic                      prog_req_i_ar_valid,
    input  logic                      prog_req_i_b_ready,
    input  logic                      prog_req_i_r_ready,
    input  logic [23:0]               prog_req_i_axMMUSID,
    input  logic [19:0]               prog_req_i_axMMUSSID,
    input  logic                      prog_req_i_axMMUSSIDV,
    output logic                      prog_resp_o_aw_ready,
    output logic                      prog_resp_o_w_ready,
    output logic                      prog_resp_o_ar_ready,
    output logic [ID_SLV_WIDTH-1:0]   prog_resp_o_b_id,
    output logic [1:0]                prog_resp_o_b_resp,
    output logic [USER_WIDTH-1:0]     prog_resp_o_b_user,
    output logic                      prog_resp_o_b_valid,
    output logic [ID_SLV_WIDTH-1:0]   prog_resp_o_r_id,
    output logic [DATA_WIDTH-1:0]     prog_resp_o_r_data,
    output logic [1:0]                prog_resp_o_r_resp,
    output logic                      prog_resp_o_r_last,
    output logic [USER_WIDTH-1:0]     prog_resp_o_r_user,
    output logic                      prog_resp_o_r_valid,

    // WSI interrupt wires flattened
    output logic                      wsi_wires_0,
    output logic                      wsi_wires_1,
    output logic                      wsi_wires_2,
    output logic                      wsi_wires_3,
    output logic                      wsi_wires_4,
    output logic                      wsi_wires_5,
    output logic                      wsi_wires_6,
    output logic                      wsi_wires_7,
    output logic                      wsi_wires_8,
    output logic                      wsi_wires_9,
    output logic                      wsi_wires_10,
    output logic                      wsi_wires_11,
    output logic                      wsi_wires_12,
    output logic                      wsi_wires_13,
    output logic                      wsi_wires_14,
    output logic                      wsi_wires_15
);

  // Note: Do not reference rv_iommu::* types here to avoid
  // package compile-order issues in Vivado. The integer-coded
  // parameters MSITrans and IGS are passed directly to the
  // underlying module; tools will cast to the enum type.

  // ------------------------------
  // AXI typed channels (master/slave)
  // ------------------------------
  // Master/Device request/response channel types (ID_WIDTH)
  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic                  lock;
    logic [3:0]            cache;
    logic [2:0]            prot;
    logic [3:0]            qos;
    logic [3:0]            region;
    logic [5:0]            atop;
    logic [USER_WIDTH-1:0] user;
  } aw_chan_t;

  typedef struct packed {
    logic [DATA_WIDTH-1:0]   data;
    logic [DATA_WIDTH/8-1:0] strb;
    logic                    last;
    logic [USER_WIDTH-1:0]   user;
  } w_chan_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [1:0]            resp;
    logic [USER_WIDTH-1:0] user;
  } b_chan_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic                  lock;
    logic [3:0]            cache;
    logic [2:0]            prot;
    logic [3:0]            qos;
    logic [3:0]            region;
    logic [USER_WIDTH-1:0] user;
  } ar_chan_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [DATA_WIDTH-1:0] data;
    logic [1:0]            resp;
    logic                  last;
    logic [USER_WIDTH-1:0] user;
  } r_chan_t;

  typedef struct packed {
    aw_chan_t  aw;
    logic      aw_valid;
    w_chan_t   w;
    logic      w_valid;
    logic      b_ready;
    ar_chan_t  ar;
    logic      ar_valid;
    logic      r_ready;
  } axi_req_t;

  // Match the ready/valid ordering used by ariane_axi_soc::resp_t
  typedef struct packed {
    logic    aw_ready;
    logic    ar_ready;
    logic    w_ready;
    logic    b_valid;
    b_chan_t b;
    logic    r_valid;
    r_chan_t r;
  } axi_rsp_t;

  // Programming (slave) channel types (ID_SLV_WIDTH)
  typedef struct packed {
    logic [DATA_WIDTH-1:0]   data;
    logic [DATA_WIDTH/8-1:0] strb;
    logic                    last;
    logic [USER_WIDTH-1:0]   user;
  } w_chan_slv_t;

  typedef struct packed {
    logic [ID_SLV_WIDTH-1:0]   id;
    logic [1:0]                resp;
    logic [USER_WIDTH-1:0]     user;
  } b_chan_slv_t;

  typedef struct packed {
    logic [ID_SLV_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0]     addr;
    logic [7:0]                len;
    logic [2:0]                size;
    logic [1:0]                burst;
    logic                      lock;
    logic [3:0]                cache;
    logic [2:0]                prot;
    logic [3:0]                qos;
    logic [3:0]                region;
    logic [5:0]                atop;
    logic [USER_WIDTH-1:0]     user;
  } aw_chan_slv_t;

  typedef struct packed {
    logic [ID_SLV_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0]     addr;
    logic [7:0]                len;
    logic [2:0]                size;
    logic [1:0]                burst;
    logic                      lock;
    logic [3:0]                cache;
    logic [2:0]                prot;
    logic [3:0]                qos;
    logic [3:0]                region;
    logic [USER_WIDTH-1:0]     user;
  } ar_chan_slv_t;

  typedef struct packed {
    logic [ID_SLV_WIDTH-1:0]   id;
    logic [DATA_WIDTH-1:0]     data;
    logic [1:0]                resp;
    logic                      last;
    logic [USER_WIDTH-1:0]     user;
  } r_chan_slv_t;

  typedef struct packed {
    aw_chan_slv_t  aw;
    logic          aw_valid;
    w_chan_slv_t   w;
    logic          w_valid;
    logic          b_ready;
    ar_chan_slv_t  ar;
    logic          ar_valid;
    logic          r_ready;
  } axi_req_slv_t;

  // Match the ready/valid ordering used by ariane_axi_soc::resp_slv_t
  typedef struct packed {
    logic          aw_ready;
    logic          ar_ready;
    logic          w_ready;
    logic          b_valid;
    b_chan_slv_t   b;
    logic          r_valid;
    r_chan_slv_t   r;
  } axi_rsp_slv_t;

  // IOMMU-extended device request channel types (adds stream id fields)
  typedef struct packed {
    // Standard AXI AW
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic                  lock;
    logic [3:0]            cache;
    logic [2:0]            prot;
    logic [3:0]            qos;
    logic [3:0]            region;
    logic [5:0]            atop;
    logic [USER_WIDTH-1:0] user;
    // IOMMU extension
    logic [23:0]           stream_id;
    logic                  ss_id_valid;
    logic [19:0]           substream_id;
  } aw_chan_iommu_t;

  typedef struct packed {
    // Standard AXI AR
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic                  lock;
    logic [3:0]            cache;
    logic [2:0]            prot;
    logic [3:0]            qos;
    logic [3:0]            region;
    logic [USER_WIDTH-1:0] user;
    // IOMMU extension
    logic [23:0]           stream_id;
    logic                  ss_id_valid;
    logic [19:0]           substream_id;
  } ar_chan_iommu_t;

  typedef struct packed {
    aw_chan_iommu_t  aw;
    logic            aw_valid;
    w_chan_t         w;
    logic            w_valid;
    logic            b_ready;
    ar_chan_iommu_t  ar;
    logic            ar_valid;
    logic            r_ready;
  } axi_req_iommu_t;

  // ------------------------------
  // Local wires for typed connections
  // ------------------------------
  axi_req_iommu_t dev_tr_req_t;
  axi_rsp_t       dev_tr_resp_t;
  axi_req_t       dev_comp_req_t;
  axi_rsp_t       dev_comp_resp_t;
  axi_req_t       ds_req_t;
  axi_rsp_t       ds_resp_t;

  // No need to model device request/response or master AXI types here;
  // the internal IOMMU instance will use untyped (logic) for those.

  // Programming interface typed connections and WSI
  axi_req_slv_t   prog_req_t;
  axi_rsp_slv_t   prog_resp_t;
  logic [N_INT_VEC-1:0] wsi_wires_vec;

  // Pack flattened into typed for Programming IF
  // AW
  assign prog_req_t.aw.id     = prog_req_i_aw_id;
  assign prog_req_t.aw.addr   = prog_req_i_aw_addr;
  assign prog_req_t.aw.len    = prog_req_i_aw_len;
  assign prog_req_t.aw.size   = prog_req_i_aw_size;
  assign prog_req_t.aw.burst  = prog_req_i_aw_burst;
  assign prog_req_t.aw.lock   = prog_req_i_aw_lock;
  assign prog_req_t.aw.cache  = prog_req_i_aw_cache;
  assign prog_req_t.aw.prot   = prog_req_i_aw_prot;
  assign prog_req_t.aw.qos    = prog_req_i_aw_qos;
  assign prog_req_t.aw.region = prog_req_i_aw_region;
  assign prog_req_t.aw.atop   = prog_req_i_aw_atop;
  assign prog_req_t.aw.user   = prog_req_i_aw_user;
  assign prog_req_t.aw_valid  = prog_req_i_aw_valid;
  // W
  assign prog_req_t.w.data    = prog_req_i_w_data;
  assign prog_req_t.w.strb    = prog_req_i_w_strb;
  assign prog_req_t.w.last    = prog_req_i_w_last;
  assign prog_req_t.w.user    = prog_req_i_w_user;
  assign prog_req_t.w_valid   = prog_req_i_w_valid;
  // B
  assign prog_req_t.b_ready   = prog_req_i_b_ready;
  // AR
  assign prog_req_t.ar.id     = prog_req_i_ar_id;
  assign prog_req_t.ar.addr   = prog_req_i_ar_addr;
  assign prog_req_t.ar.len    = prog_req_i_ar_len;
  assign prog_req_t.ar.size   = prog_req_i_ar_size;
  assign prog_req_t.ar.burst  = prog_req_i_ar_burst;
  assign prog_req_t.ar.lock   = prog_req_i_ar_lock;
  assign prog_req_t.ar.cache  = prog_req_i_ar_cache;
  assign prog_req_t.ar.prot   = prog_req_i_ar_prot;
  assign prog_req_t.ar.qos    = prog_req_i_ar_qos;
  assign prog_req_t.ar.region = prog_req_i_ar_region;
  assign prog_req_t.ar.user   = prog_req_i_ar_user;
  assign prog_req_t.ar_valid  = prog_req_i_ar_valid;
  // R
  assign prog_req_t.r_ready   = prog_req_i_r_ready;

  // ------------------------------------------------------------------
  // Pack MMU stream/substream metadata into AW/AR user for master side
  // user[44:21] = stream_id[23:0], user[20] = ssid_valid, user[19:0] = substream_id
  // ------------------------------------------------------------------
  logic [44:0] mmu_user_pack;
  assign mmu_user_pack = {dev_tr_req_i_axMMUSID, dev_tr_req_i_axMMUSSIDV, dev_tr_req_i_axMMUSSID};

  // Pack flattened into typed for Device Translation (extended AW/AR)
  // AW
  assign dev_tr_req_t.aw.id            = dev_tr_req_i_aw_id;
  assign dev_tr_req_t.aw.addr          = dev_tr_req_i_aw_addr;
  assign dev_tr_req_t.aw.len           = dev_tr_req_i_aw_len;
  assign dev_tr_req_t.aw.size          = dev_tr_req_i_aw_size;
  assign dev_tr_req_t.aw.burst         = dev_tr_req_i_aw_burst;
  assign dev_tr_req_t.aw.lock          = dev_tr_req_i_aw_lock;
  assign dev_tr_req_t.aw.cache         = dev_tr_req_i_aw_cache;
  assign dev_tr_req_t.aw.prot          = dev_tr_req_i_aw_prot;
  assign dev_tr_req_t.aw.qos           = dev_tr_req_i_aw_qos;
  assign dev_tr_req_t.aw.region        = dev_tr_req_i_aw_region;
  assign dev_tr_req_t.aw.atop          = dev_tr_req_i_aw_atop;
  assign dev_tr_req_t.aw.user          = dev_tr_req_i_aw_user;
  assign dev_tr_req_t.aw.stream_id     = dev_tr_req_i_axMMUSID;
  assign dev_tr_req_t.aw.ss_id_valid   = dev_tr_req_i_axMMUSSIDV;
  assign dev_tr_req_t.aw.substream_id  = dev_tr_req_i_axMMUSSID;
  assign dev_tr_req_t.aw_valid         = dev_tr_req_i_aw_valid;
  // W
  assign dev_tr_req_t.w.data           = dev_tr_req_i_w_data;
  assign dev_tr_req_t.w.strb           = dev_tr_req_i_w_strb;
  assign dev_tr_req_t.w.last           = dev_tr_req_i_w_last;
  assign dev_tr_req_t.w.user           = dev_tr_req_i_w_user;
  assign dev_tr_req_t.w_valid          = dev_tr_req_i_w_valid;
  // AR
  assign dev_tr_req_t.ar.id            = dev_tr_req_i_ar_id;
  assign dev_tr_req_t.ar.addr          = dev_tr_req_i_ar_addr;
  assign dev_tr_req_t.ar.len           = dev_tr_req_i_ar_len;
  assign dev_tr_req_t.ar.size          = dev_tr_req_i_ar_size;
  assign dev_tr_req_t.ar.burst         = dev_tr_req_i_ar_burst;
  assign dev_tr_req_t.ar.lock          = dev_tr_req_i_ar_lock;
  assign dev_tr_req_t.ar.cache         = dev_tr_req_i_ar_cache;
  assign dev_tr_req_t.ar.prot          = dev_tr_req_i_ar_prot;
  assign dev_tr_req_t.ar.qos           = dev_tr_req_i_ar_qos;
  assign dev_tr_req_t.ar.region        = dev_tr_req_i_ar_region;
  assign dev_tr_req_t.ar.user          = dev_tr_req_i_ar_user;
  assign dev_tr_req_t.ar.stream_id     = dev_tr_req_i_axMMUSID;
  assign dev_tr_req_t.ar.ss_id_valid   = dev_tr_req_i_axMMUSSIDV;
  assign dev_tr_req_t.ar.substream_id  = dev_tr_req_i_axMMUSSID;
  assign dev_tr_req_t.ar_valid         = dev_tr_req_i_ar_valid;
  // R/B handshake
  assign dev_tr_req_t.b_ready          = dev_tr_req_i_b_ready;
  assign dev_tr_req_t.r_ready          = dev_tr_req_i_r_ready;

  // Pack flattened into typed for Completion Response (input)
  assign dev_comp_resp_t.aw_ready      = dev_comp_resp_i_aw_ready;
  assign dev_comp_resp_t.w_ready       = dev_comp_resp_i_w_ready;
  assign dev_comp_resp_t.ar_ready      = dev_comp_resp_i_ar_ready;
  assign dev_comp_resp_t.b.id          = dev_comp_resp_i_b_id;
  assign dev_comp_resp_t.b.resp        = dev_comp_resp_i_b_resp;
  assign dev_comp_resp_t.b.user        = dev_comp_resp_i_b_user;
  assign dev_comp_resp_t.b_valid       = dev_comp_resp_i_b_valid;
  assign dev_comp_resp_t.r.id          = dev_comp_resp_i_r_id;
  assign dev_comp_resp_t.r.data        = dev_comp_resp_i_r_data;
  assign dev_comp_resp_t.r.resp        = dev_comp_resp_i_r_resp;
  assign dev_comp_resp_t.r.last        = dev_comp_resp_i_r_last;
  assign dev_comp_resp_t.r.user        = dev_comp_resp_i_r_user;
  assign dev_comp_resp_t.r_valid       = dev_comp_resp_i_r_valid;

  // Pack flattened into typed for DS Response (input)
  assign ds_resp_t.aw_ready            = ds_resp_i_aw_ready;
  assign ds_resp_t.w_ready             = ds_resp_i_w_ready;
  assign ds_resp_t.ar_ready            = ds_resp_i_ar_ready;
  assign ds_resp_t.b.id                = ds_resp_i_b_id;
  assign ds_resp_t.b.resp              = ds_resp_i_b_resp;
  assign ds_resp_t.b.user              = ds_resp_i_b_user;
  assign ds_resp_t.b_valid             = ds_resp_i_b_valid;
  assign ds_resp_t.r.id                = ds_resp_i_r_id;
  assign ds_resp_t.r.data              = ds_resp_i_r_data;
  assign ds_resp_t.r.resp              = ds_resp_i_r_resp;
  assign ds_resp_t.r.last              = ds_resp_i_r_last;
  assign ds_resp_t.r.user              = ds_resp_i_r_user;
  assign ds_resp_t.r_valid             = ds_resp_i_r_valid;

  // Instantiate the typed IOMMU
  // Bind types so the core sees typed AXI on all interfaces
  riscv_iommu #(
    .IOTLB_ENTRIES   ( IOTLB_ENTRIES ),
    .DDTC_ENTRIES    ( DDTC_ENTRIES  ),
    .PDTC_ENTRIES    ( PDTC_ENTRIES  ),
    .InclPC          ( InclPC        ),
    .InclBC          ( InclBC        ),
    .InclDBG         ( InclDBG       ),
    .InclMSITrans    ( InclMSITrans  ),
    .IGS             ( IGS           ),
    .N_INT_VEC       ( N_INT_VEC     ),
    .N_IOHPMCTR      ( N_IOHPMCTR    ),
    .ADDR_WIDTH      ( ADDR_WIDTH    ),
    .DATA_WIDTH      ( DATA_WIDTH    ),
    .ID_WIDTH        ( ID_WIDTH      ),
    .ID_SLV_WIDTH    ( ID_SLV_WIDTH  ),
    .USER_WIDTH      ( USER_WIDTH    ),
    // Channel types for master/device paths
    .aw_chan_t       ( aw_chan_t     ),
    .w_chan_t        ( w_chan_t      ),
    .b_chan_t        ( b_chan_t      ),
    .ar_chan_t       ( ar_chan_t     ),
    .r_chan_t        ( r_chan_t      ),
    .axi_req_t       ( axi_req_t     ),
    .axi_rsp_t       ( axi_rsp_t     ),
    // Programming interface types
    .axi_req_slv_t   ( axi_req_slv_t ),
    .axi_rsp_slv_t   ( axi_rsp_slv_t ),
    // Device translation extended request type (note: parameter is axi_req_mmu_t in the core)
    .axi_req_mmu_t   ( axi_req_iommu_t ),
    // Register interface types (drive the real reg bus instead of tying it off)
    .reg_req_t       ( iommu_reg_req_t ),
    .reg_rsp_t       ( iommu_reg_rsp_t )
  ) i_iommu (
    .clk_i          ( clk_i        ),
    .rst_ni         ( rst_ni       ),
    // Device translation interface (typed)
    .dev_tr_req_i   ( dev_tr_req_t   ),
    .dev_tr_resp_o  ( dev_tr_resp_t  ),
    // Completion interface
    .dev_comp_resp_i( dev_comp_resp_t ),
    .dev_comp_req_o ( dev_comp_req_t  ),
    // Data structures interface
    .ds_resp_i      ( ds_resp_t      ),
    .ds_req_o       ( ds_req_t       ),
    // Programming interface
    .prog_req_i     ( prog_req_t  ),
    .prog_resp_o    ( prog_resp_t ),
    // Interrupt wires
    .wsi_wires_o    ( wsi_wires_vec )
  );

  // Drive all flattened non-programming outputs low to satisfy ports.
  // Device Translation Response (flatten)
  assign dev_tr_resp_o_aw_ready = dev_tr_resp_t.aw_ready;
  assign dev_tr_resp_o_w_ready  = dev_tr_resp_t.w_ready;
  assign dev_tr_resp_o_ar_ready = dev_tr_resp_t.ar_ready;
  assign dev_tr_resp_o_b_id     = dev_tr_resp_t.b.id;
  assign dev_tr_resp_o_b_resp   = dev_tr_resp_t.b.resp;
  assign dev_tr_resp_o_b_user   = dev_tr_resp_t.b.user;
  assign dev_tr_resp_o_b_valid  = dev_tr_resp_t.b_valid;
  assign dev_tr_resp_o_r_id     = dev_tr_resp_t.r.id;
  assign dev_tr_resp_o_r_data   = dev_tr_resp_t.r.data;
  assign dev_tr_resp_o_r_resp   = dev_tr_resp_t.r.resp;
  assign dev_tr_resp_o_r_last   = dev_tr_resp_t.r.last;
  assign dev_tr_resp_o_r_user   = dev_tr_resp_t.r.user;
  assign dev_tr_resp_o_r_valid  = dev_tr_resp_t.r_valid;

  // Completion Request (master flatten)
  assign dev_comp_req_o_aw_id     = dev_comp_req_t.aw.id;
  assign dev_comp_req_o_aw_addr   = dev_comp_req_t.aw.addr;
  assign dev_comp_req_o_aw_len    = dev_comp_req_t.aw.len;
  assign dev_comp_req_o_aw_size   = dev_comp_req_t.aw.size;
  assign dev_comp_req_o_aw_burst  = dev_comp_req_t.aw.burst;
  assign dev_comp_req_o_aw_lock   = dev_comp_req_t.aw.lock;
  assign dev_comp_req_o_aw_cache  = dev_comp_req_t.aw.cache;
  assign dev_comp_req_o_aw_prot   = dev_comp_req_t.aw.prot;
  assign dev_comp_req_o_aw_qos    = dev_comp_req_t.aw.qos;
  assign dev_comp_req_o_aw_region = dev_comp_req_t.aw.region;
  assign dev_comp_req_o_aw_atop   = dev_comp_req_t.aw.atop;
  assign dev_comp_req_o_aw_user   = mmu_user_pack;
  assign dev_comp_req_o_aw_valid  = dev_comp_req_t.aw_valid;
  assign dev_comp_req_o_w_data    = dev_comp_req_t.w.data;
  assign dev_comp_req_o_w_strb    = dev_comp_req_t.w.strb;
  assign dev_comp_req_o_w_last    = dev_comp_req_t.w.last;
  assign dev_comp_req_o_w_user    = dev_comp_req_t.w.user;
  assign dev_comp_req_o_w_valid   = dev_comp_req_t.w_valid;
  assign dev_comp_req_o_ar_id     = dev_comp_req_t.ar.id;
  assign dev_comp_req_o_ar_addr   = dev_comp_req_t.ar.addr;
  assign dev_comp_req_o_ar_len    = dev_comp_req_t.ar.len;
  assign dev_comp_req_o_ar_size   = dev_comp_req_t.ar.size;
  assign dev_comp_req_o_ar_burst  = dev_comp_req_t.ar.burst;
  assign dev_comp_req_o_ar_lock   = dev_comp_req_t.ar.lock;
  assign dev_comp_req_o_ar_cache  = dev_comp_req_t.ar.cache;
  assign dev_comp_req_o_ar_prot   = dev_comp_req_t.ar.prot;
  assign dev_comp_req_o_ar_qos    = dev_comp_req_t.ar.qos;
  assign dev_comp_req_o_ar_region = dev_comp_req_t.ar.region;
  assign dev_comp_req_o_ar_user   = mmu_user_pack;
  assign dev_comp_req_o_ar_valid  = dev_comp_req_t.ar_valid;
  assign dev_comp_req_o_b_ready   = dev_comp_req_t.b_ready;
  assign dev_comp_req_o_r_ready   = dev_comp_req_t.r_ready;
  // Extended fields not present on master side
  assign dev_comp_req_o_axMMUSID  = '0;
  assign dev_comp_req_o_axMMUSSID = '0;
  assign dev_comp_req_o_axMMUSSIDV= 1'b0;

  // DS Request (master flatten)
  assign ds_req_o_aw_id     = ds_req_t.aw.id;
  assign ds_req_o_aw_addr   = ds_req_t.aw.addr;
  assign ds_req_o_aw_len    = ds_req_t.aw.len;
  assign ds_req_o_aw_size   = ds_req_t.aw.size;
  assign ds_req_o_aw_burst  = ds_req_t.aw.burst;
  assign ds_req_o_aw_lock   = ds_req_t.aw.lock;
  assign ds_req_o_aw_cache  = ds_req_t.aw.cache;
  assign ds_req_o_aw_prot   = ds_req_t.aw.prot;
  assign ds_req_o_aw_qos    = ds_req_t.aw.qos;
  assign ds_req_o_aw_region = ds_req_t.aw.region;
  assign ds_req_o_aw_atop   = ds_req_t.aw.atop;
  assign ds_req_o_aw_user   = mmu_user_pack;
  assign ds_req_o_aw_valid  = ds_req_t.aw_valid;
  assign ds_req_o_w_data    = ds_req_t.w.data;
  assign ds_req_o_w_strb    = ds_req_t.w.strb;
  assign ds_req_o_w_last    = ds_req_t.w.last;
  assign ds_req_o_w_user    = ds_req_t.w.user;
  assign ds_req_o_w_valid   = ds_req_t.w_valid;
  assign ds_req_o_ar_id     = ds_req_t.ar.id;
  assign ds_req_o_ar_addr   = ds_req_t.ar.addr;
  assign ds_req_o_ar_len    = ds_req_t.ar.len;
  assign ds_req_o_ar_size   = ds_req_t.ar.size;
  assign ds_req_o_ar_burst  = ds_req_t.ar.burst;
  assign ds_req_o_ar_lock   = ds_req_t.ar.lock;
  assign ds_req_o_ar_cache  = ds_req_t.ar.cache;
  assign ds_req_o_ar_prot   = ds_req_t.ar.prot;
  assign ds_req_o_ar_qos    = ds_req_t.ar.qos;
  assign ds_req_o_ar_region = ds_req_t.ar.region;
  assign ds_req_o_ar_user   = mmu_user_pack;
  assign ds_req_o_ar_valid  = ds_req_t.ar_valid;
  assign ds_req_o_b_ready   = ds_req_t.b_ready;
  assign ds_req_o_r_ready   = ds_req_t.r_ready;
  // Extended fields not present on master side
  assign ds_req_o_axMMUSID  = '0;
  assign ds_req_o_axMMUSSID = '0;
  assign ds_req_o_axMMUSSIDV= 1'b0;

  // Programming response
  assign prog_resp_o_aw_ready = prog_resp_t.aw_ready;
  assign prog_resp_o_w_ready  = prog_resp_t.w_ready;
  assign prog_resp_o_b_id     = prog_resp_t.b.id;
  assign prog_resp_o_b_resp   = prog_resp_t.b.resp;
  assign prog_resp_o_b_user   = prog_resp_t.b.user;
  assign prog_resp_o_b_valid  = prog_resp_t.b_valid;
  assign prog_resp_o_ar_ready = prog_resp_t.ar_ready;
  assign prog_resp_o_r_id     = prog_resp_t.r.id;
  assign prog_resp_o_r_data   = prog_resp_t.r.data;
  assign prog_resp_o_r_resp   = prog_resp_t.r.resp;
  assign prog_resp_o_r_last   = prog_resp_t.r.last;
  assign prog_resp_o_r_user   = prog_resp_t.r.user;
  assign prog_resp_o_r_valid  = prog_resp_t.r_valid;

  // WSI vector fan-out (support the commonly used case N_INT_VEC=16)
  // If fewer than 16, upper outputs remain 0. If more, extras are dropped.
  assign {wsi_wires_15,wsi_wires_14,wsi_wires_13,wsi_wires_12,wsi_wires_11,wsi_wires_10,wsi_wires_9,wsi_wires_8,
          wsi_wires_7,wsi_wires_6,wsi_wires_5,wsi_wires_4,wsi_wires_3,wsi_wires_2,wsi_wires_1,wsi_wires_0} =
         wsi_wires_vec[15:0];

`ifdef VERILATOR
  // Optional debug to observe Completion master traffic
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (dev_comp_req_o_aw_valid && dev_comp_resp_i_aw_ready) begin
        $display("[%0t][COMP] AW id=0x%0h addr=0x%0h len=0x%0h size=0x%0h", $time,
                 dev_comp_req_o_aw_id, dev_comp_req_o_aw_addr, dev_comp_req_o_aw_len, dev_comp_req_o_aw_size);
      end
      if (dev_comp_req_o_ar_valid && dev_comp_resp_i_ar_ready) begin
        $display("[%0t][COMP] AR id=0x%0h addr=0x%0h len=0x%0h size=0x%0h", $time,
                 dev_comp_req_o_ar_id, dev_comp_req_o_ar_addr, dev_comp_req_o_ar_len, dev_comp_req_o_ar_size);
      end
      if (dev_comp_resp_i_b_valid && dev_comp_req_o_b_ready) begin
        $display("[%0t][COMP] B id=0x%0h resp=0x%0h", $time, dev_comp_resp_i_b_id, dev_comp_resp_i_b_resp);
      end
      if (dev_comp_resp_i_r_valid && dev_comp_req_o_r_ready) begin
        $display("[%0t][COMP] R id=0x%0h last=%0b resp=0x%0h", $time,
                 dev_comp_resp_i_r_id, dev_comp_resp_i_r_last, dev_comp_resp_i_r_resp);
      end
    end
  end
`endif

endmodule

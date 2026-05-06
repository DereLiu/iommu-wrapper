package zerodaylabs.blocks.ip.iommu


import sys.process._

import chisel3._
import chisel3.util._

class AxiReq(val addWidth: Int, val dataWidth: Int, val idWidth: Int, val userWidth: Int) extends Bundle {
  //AW channel
  val aw_id = UInt(idWidth.W)
  val aw_addr = UInt(addWidth.W)
  val aw_len = UInt(8.W)
  val aw_size = UInt(3.W)
  val aw_burst = UInt(2.W)
  val aw_lock = Bool()
  val aw_cache = UInt(4.W)
  val aw_prot = UInt(3.W)
  val aw_qos = UInt(4.W)
  val aw_region = UInt(4.W)
  val aw_atop = UInt(6.W)
  val aw_user = UInt(userWidth.W)
  val aw_valid = Bool()
  // Write Address Channel
  val w_data = UInt(dataWidth.W)
  val w_strb = UInt((dataWidth/8).W)
  val w_last = Bool()
  val w_user = UInt(userWidth.W)
  val w_valid = Bool()
  //AR channel
  val ar_id = UInt(idWidth.W)
  val ar_addr = UInt(addWidth.W)
  val ar_len = UInt(8.W)
  val ar_size = UInt(3.W)
  val ar_burst = UInt(2.W)
  val ar_lock = Bool()
  val ar_cache = UInt(4.W)
  val ar_prot = UInt(3.W)
  val ar_qos = UInt(4.W)
  val ar_region = UInt(4.W)
  val ar_user = UInt(userWidth.W)
  val ar_valid = Bool()

  val b_ready = Bool()
  val r_ready = Bool()
  // IOMMU exclusive
  val axMMUSID = UInt(24.W)
  val axMMUSSID = UInt(20.W)
  val axMMUSSIDV = Bool()
}

class AxiResp(val dataWidth: Int, val idWidth: Int, val userWidth: Int) extends Bundle {
  // Order must match resp_t in ariane_axi_soc_pkg
  val aw_ready = Bool()
  val ar_ready = Bool()
  val w_ready  = Bool()

  val b_valid  = Bool()
  val b_id     = UInt(idWidth.W)
  val b_resp   = UInt(2.W)
  val b_user   = UInt(userWidth.W)

  val r_valid  = Bool()
  val r_id     = UInt(idWidth.W)
  val r_data   = UInt(dataWidth.W)
  val r_resp   = UInt(2.W)
  val r_last   = Bool()
  val r_user   = UInt(userWidth.W)
}

//scalastyle:off
//turn off linter: blackbox name must match verilog module

class iommu(
  blackboxName: String,
  iotlbEntries: Int = 4,
  ddtcEntries: Int = 4,
  pdtcEntries: Int = 4,
  inclPc: Boolean = false,
  inclBc: Boolean = false,
  inclDbg: Boolean = false,
  // Integer-coded enums to avoid unsupported string params in synthesis
  // msiTrans: 0=MSI_DISABLED, 1=MSI_FLAT_ONLY, 2=MSI_FLAT_MRIF
  msiTrans: Int = 0,
  // igs: 0=MSI_ONLY, 1=WSI_ONLY, 2=BOTH
  igs: Int = 1,
  nIntVec: Int = 16,
  nIohpmctr: Int = 0,
  addrWidth: Int = 64,
  dataWidth: Int = 64,
  idWidth: Int = 4,
  idSlvWidth: Int = 4,
  userWidth: Int = 1,
) 
  extends BlackBox(
    Map(
      "IOTLB_ENTRIES" -> iotlbEntries,
      "DDTC_ENTRIES" -> ddtcEntries,
      "PDTC_ENTRIES" -> pdtcEntries,
      "InclPC" -> (if (inclPc) 1 else 0),
      "InclBC" -> (if (inclBc) 1 else 0),
      "InclDBG" -> (if (inclDbg) 1 else 0),
      // Force MSI translation off; if you intend to support MSI, plumb through
      // the parameter and update the regmap capability instead of leaving it high.
      "InclMSITrans" -> 0,
      "IGS" -> igs,
      "N_INT_VEC" -> nIntVec,
      "N_IOHPMCTR" -> nIohpmctr,
      "ADDR_WIDTH" -> addrWidth,
      "DATA_WIDTH" -> dataWidth,
      "ID_WIDTH" -> idWidth,
      "ID_SLV_WIDTH" -> idSlvWidth,
      "USER_WIDTH" -> userWidth)
    ) with HasBlackBoxPath
{
  override def desiredName: String = blackboxName

  private val Req = new AxiReq(addrWidth, dataWidth, idWidth, userWidth)
  private val Resp = new AxiResp(dataWidth, idWidth, userWidth)
  private val SlvReq = new AxiReq(addrWidth, dataWidth, idSlvWidth, userWidth)
  private val SlvResp = new AxiResp(dataWidth, idSlvWidth, userWidth)

  val io = IO(new Bundle{
    val clk_i = Input(Clock())
    val rst_ni = Input(Bool()) 

    //Translation Request interface (slave)
    val dev_tr_req_i = Input(Req.cloneType)
    val dev_tr_resp_o = Output(Resp.cloneType)

    //Translation Completion interface (master)
    val dev_comp_resp_i = Input(Resp.cloneType)
    val dev_comp_req_o = Output(Req.cloneType)

    //Data Structures Interface (master)
    val ds_resp_i = Input(Resp.cloneType)
    val ds_req_o = Output(Req.cloneType)

    //Programming interface (slave)
    val prog_req_i = Input(SlvReq.cloneType)
    val prog_resp_o = Output(SlvResp.cloneType)

    val wsi_wires = Output(Vec(nIntVec, Bool())) // WSI interrupt wires
  })

 val chipyardDir = System.getProperty("user.dir") 
 val iommuVsrcDir = s"$chipyardDir/generators/iommu/src/main/resources"

  // Always regenerate the preprocessed SV at elaboration to avoid staleness.
  // Bundle dependency packages into the preprocessed file so Vivado sees a
  // self-contained IOMMU (its filelist is alphabetically sorted, which can
  // otherwise place riscv_pkg after the IOMMU and break binding).
  val make = s"make -C $iommuVsrcDir IOMMU_BUNDLE_DEPS=1 default"
  require(make.! == 0, s"Failed to run IOMMU pre-processing step in $iommuVsrcDir")
 
 // Pull in dependency packages that are not bundled into the preprocessed IOMMU
 // source. Guards inside each package prevent double definitions when CVA6 is
 // also present.
 addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/ariane_dm_pkg.sv")
 addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/riscv_pkg.sv")
 // CVA6 configuration package must precede ariane_pkg, which imports it.
 addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/cv64a6_imafdc_sv39_config_pkg.sv")
 addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/ariane_pkg.sv")
 addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/ariane_soc_pkg.sv")
 addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/axi_pkg.sv")
 //addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/cf_math_pkg.sv")
addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/iommu_axi_pkg.sv")
addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/iommu_riscv_pkg.sv")
addPath(s"$iommuVsrcDir/vsrc/packages/dependencies/lint_wrapper_pkg.sv")
// Utility modules used by the preprocessed IOMMU RTL
addPath(s"$iommuVsrcDir/vsrc/vendor/counter.sv")
addPath(s"$iommuVsrcDir/vsrc/vendor/lzc.sv")
addPath(s"$iommuVsrcDir/vsrc/vendor/delta_counter.sv")
addPath(s"$iommuVsrcDir/vsrc/vendor/stream_arbiter.sv")
addPath(s"$iommuVsrcDir/vsrc/vendor/stream_arbiter_flushable.sv")
addPath(s"$iommuVsrcDir/vsrc/vendor/rr_arb_tree.sv")

 addPath(s"$iommuVsrcDir/riscv_iommu.preprocessed.sv")
 addPath(s"$iommuVsrcDir/riscv_iommu_flat.sv")
}

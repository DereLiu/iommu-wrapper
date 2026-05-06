package zerodaylabs.blocks.iommu

import chisel3._
import chisel3.util._
//import chisel3.experimental.dontTouch
import freechips.rocketchip.config.{Config, Field, Parameters}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.util._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.amba.axi4._
import freechips.rocketchip.subsystem.BaseSubsystem
import freechips.rocketchip.interrupts._
import freechips.rocketchip.diplomacy.{Description, ResourceBindings, ResourceInt, ResourceString}
import freechips.rocketchip.devices.tilelink.{DevNullParams, TLError}
import zerodaylabs.blocks.ip.iommu.{iommu => IOMMUBlackBox}

case class IOMMUParams(baseAddress: BigInt = 0x50010000L,
                       dataBits:   Int = 64,
                       exposeDevSlave: Boolean = false,
                       devDefaultSid: Int = 1,
                       devDefaultSsid: Int = 0,
                       devDefaultSsidValid: Boolean = false,
                       exposeAllWsis: Boolean = false,
                       devAddrBits: Int = 48) {
  require(devDefaultSid >= 0 && devDefaultSid < (1 << 24),
    s"devDefaultSid ($devDefaultSid) must fit within 24 bits")
  require(devDefaultSsid >= 0 && devDefaultSsid < (1 << 20),
    s"devDefaultSsid ($devDefaultSsid) must fit within 20 bits")
  require(devAddrBits >= 1 && devAddrBits <= 64,
    s"devAddrBits ($devAddrBits) must be in [1, 64]")
}

case object IOMMUKey extends Field[Option[IOMMUParams]](None)

class IOMMU(val params: IOMMUParams)(implicit p: Parameters) extends LazyModule {
  // DTS device: compatible + custom properties
  class IOMMUDevice extends SimpleDevice("iommu", Seq("zerodaylabs,iommu", "riscv,iommu")) {
    override def describe(resources: ResourceBindings): Description = {
      val Description(name, mapping) = super.describe(resources)
      val extra = Map(
        "#iommu-cells"     -> Seq(ResourceInt(1)),
        "interrupt-names"  -> Seq(
          ResourceString("cmdq"),
          ResourceString("fltq"),
          ResourceString("hpm")
        )
      )
      Description(name, mapping ++ extra)
    }
  }
  val dtsdevice = new IOMMUDevice

  val node = AXI4SlaveNode(Seq(AXI4SlavePortParameters(
    slaves = Seq(AXI4SlaveParameters(
      address       = Seq(AddressSet(params.baseAddress, 0xFFF)),
      resources     = dtsdevice.reg,
      regionType    = RegionType.UNCACHED,
      supportsRead  = TransferSizes(1, params.dataBits/8),
      supportsWrite = TransferSizes(1, params.dataBits/8),
      interleavedId = Some(0),
      executable    = false
    )),
    beatBytes = params.dataBits/8
  )))
  // Alias for clarity when hooking up CSR path
  val progNode: AXI4SlaveNode = node

  // Optional AXI device-translation slave (connect devices like NVDLA here)
  private val devAddrMask = (BigInt(1) << params.devAddrBits) - 1
  val devNodeOpt: Option[AXI4SlaveNode] = if (params.exposeDevSlave) Some(AXI4SlaveNode(Seq(AXI4SlavePortParameters(
    slaves = Seq(AXI4SlaveParameters(
      address       = Seq(AddressSet(BigInt(0), devAddrMask)),
      resources     = Nil,
      regionType    = RegionType.UNCACHED,
      interleavedId = Some(0),
      supportsRead  = TransferSizes(1, params.dataBits/8),
      supportsWrite = TransferSizes(1, params.dataBits/8),
      executable    = false
    )),
    beatBytes = params.dataBits/8,
    requestKeys = Seq(MMUStreamKey)
  )))) else None

  // AXI masters (Completion + DS)
  // Carry 45b MMU user on AW/AR via requestFields
  case object MmuUser extends ControlKey[UInt]("mmu_user")
  case class MmuUserField(width: Int) extends SimpleBundleField(MmuUser)(Output(UInt(width.W)), 0.U)
  private val mmuUserWidth = 45
  // Master ID width used for AXI master ports (DS/comp). Expose it so
  // downstream plumbing can size ID indexers appropriately.
  val masterIdBits = 6 // keep master/blackbox IDs aligned with broader fabric

  private val masterP = AXI4MasterPortParameters(
    masters = Seq(AXI4MasterParameters(
      name = "iommu",
      id = IdRange(0, 1 << masterIdBits),
      aligned = true,
      maxFlight = Some(1))),
    requestFields = Seq(MmuUserField(mmuUserWidth))
  )
  // Track the configured per-ID flight cap so downstream converters preserve the outstanding limit
  val maxFlightPerId: Int = masterP.masters.flatMap(_.maxFlight).max

  val dsNode = AXI4MasterNode(Seq(masterP.copy(masters = Seq(AXI4MasterParameters(
    name = "iommu-ds",
    id = IdRange(0, 1 << masterIdBits),
    aligned = true,
    maxFlight = Some(1))))))
  val compNode = AXI4MasterNode(Seq(masterP.copy(masters = Seq(AXI4MasterParameters(
    name = "iommu-comp",
    id = IdRange(0, 1 << masterIdBits),
    aligned = true,
    maxFlight = Some(1))))))

  // Interrupt source: export all 16 WSI lines to PLIC
  private val exposedIrqs = 3
  val intNode = IntSourceNode(IntSourcePortSimple(num = exposedIrqs, resources = dtsdevice.int))

  lazy val module = new LazyModuleImp(this) {
    val ctrl = node.in.head._1
    val slaveIdBits = ctrl.aw.bits.id.getWidth
    require(slaveIdBits == ctrl.ar.bits.id.getWidth,
      s"IOMMU control AW/AR ID widths differ (aw=${ctrl.aw.bits.id.getWidth}, ar=${ctrl.ar.bits.id.getWidth})")
    // DEBUG bypass: set true to ignore blackbox and immediately ack MMIO.
    // Use full blackbox responses in sim to satisfy TL protocol checking.
    val bypassProg = false.B

    // widen AXI user to carry MMU stream/substream metadata (24+1+20 = 45 bits)
    // Enable full-featured IOMMU to avoid tied-off signals:
    // - inclPc/inclBc/inclDbg enabled
    // - MSI translation with MRIF support
    // - Both WSI and MSI interrupt generation
    // - Some HPM counters enabled
    val bb   = Module(new IOMMUBlackBox(
      "riscv_iommu_flat",
      iotlbEntries = 4,
      inclPc    = true,
      inclBc    = true,
      inclDbg    = true,
      msiTrans   = 0,     // 0=DISABLED,1=FLAT_ONLY,2=FLAT_MRIF
      igs        = 1,     // 0=MSI_ONLY,1=WSI_ONLY,2=BOTH
      nIohpmctr  = 4,     // enable HPM to avoid tie-offs
      dataWidth  = params.dataBits,
      idWidth    = masterIdBits,
      idSlvWidth = slaveIdBits,
      userWidth  = 45
    ))

    // Use explicit clock signal to ensure same clock domain for both blackbox and reset synchronizer
    val bbClock = clock
    bb.io.clk_i  := bbClock
    // The IOMMU SV block expects a synchronous, active-low reset.  The global
    // subsystem reset is asynchronous and active-high, so explicitly
    // synchronize it into this clock domain before inversion.  For debug we
    // can temporarily force the reset high to confirm reset is not the cause
    // of the stall.
    val bbResetSync  = ResetCatchAndSync(bbClock, reset.asBool)
    val forceResetHi = false.B
    bb.io.rst_ni     := Mux(forceResetHi, true.B, !bbResetSync)

    // AW channel
    bb.io.prog_req_i.aw_id    := Mux(bypassProg, 0.U, ctrl.aw.bits.id)
    bb.io.prog_req_i.aw_addr  := Mux(bypassProg, 0.U, ctrl.aw.bits.addr)
    bb.io.prog_req_i.aw_len   := Mux(bypassProg, 0.U, ctrl.aw.bits.len)
    bb.io.prog_req_i.aw_size  := Mux(bypassProg, 0.U, ctrl.aw.bits.size)
    bb.io.prog_req_i.aw_burst := Mux(bypassProg, 0.U, ctrl.aw.bits.burst)
    bb.io.prog_req_i.aw_lock  := Mux(bypassProg, 0.U, ctrl.aw.bits.lock)
    bb.io.prog_req_i.aw_cache := Mux(bypassProg, 0.U, ctrl.aw.bits.cache)
    bb.io.prog_req_i.aw_prot  := Mux(bypassProg, 0.U, ctrl.aw.bits.prot)
    bb.io.prog_req_i.aw_qos   := Mux(bypassProg, 0.U, ctrl.aw.bits.qos)
    bb.io.prog_req_i.aw_region:= 0.U
    bb.io.prog_req_i.aw_atop  := 0.U
    bb.io.prog_req_i.aw_user  := 0.U
    bb.io.prog_req_i.aw_valid := Mux(bypassProg, false.B, ctrl.aw.valid)
    val wrInFlight = RegInit(false.B)
    val wrId       = Reg(UInt(slaveIdBits.W))
    when (ctrl.aw.fire) {
      wrInFlight := true.B
      wrId       := ctrl.aw.bits.id
    }
    // Accept AW when no outstanding write pending
    ctrl.aw.ready := Mux(bypassProg, !wrInFlight, bb.io.prog_resp_o.aw_ready)

    // W channel
    bb.io.prog_req_i.w_data  := Mux(bypassProg, 0.U, ctrl.w.bits.data)
    bb.io.prog_req_i.w_strb  := Mux(bypassProg, 0.U, ctrl.w.bits.strb)
    bb.io.prog_req_i.w_last  := Mux(bypassProg, false.B, ctrl.w.bits.last)
    bb.io.prog_req_i.w_user  := 0.U
    bb.io.prog_req_i.w_valid := Mux(bypassProg, false.B, ctrl.w.valid)
    ctrl.w.ready             := Mux(bypassProg, wrInFlight, bb.io.prog_resp_o.w_ready)

    // B channel
    val bValidBypass = RegInit(false.B)
    when (ctrl.w.fire && ctrl.w.bits.last) { bValidBypass := true.B }
    when (ctrl.b.fire) { bValidBypass := false.B; wrInFlight := false.B }
    ctrl.b.bits.id           := Mux(bypassProg, wrId, bb.io.prog_resp_o.b_id)
    ctrl.b.bits.resp         := Mux(bypassProg, 0.U, bb.io.prog_resp_o.b_resp)
    ctrl.b.bits.user         := 0.U.asTypeOf(ctrl.b.bits.user)
    ctrl.b.valid             := Mux(bypassProg, bValidBypass, bb.io.prog_resp_o.b_valid)
    bb.io.prog_req_i.b_ready := Mux(bypassProg, false.B, ctrl.b.ready)

    // AR channel
    bb.io.prog_req_i.ar_id    := Mux(bypassProg, 0.U, ctrl.ar.bits.id)
    bb.io.prog_req_i.ar_addr  := Mux(bypassProg, 0.U, ctrl.ar.bits.addr)
    bb.io.prog_req_i.ar_len   := Mux(bypassProg, 0.U, ctrl.ar.bits.len)
    bb.io.prog_req_i.ar_size  := Mux(bypassProg, 0.U, ctrl.ar.bits.size)
    bb.io.prog_req_i.ar_burst := Mux(bypassProg, 0.U, ctrl.ar.bits.burst)
    bb.io.prog_req_i.ar_lock  := Mux(bypassProg, 0.U, ctrl.ar.bits.lock)
    bb.io.prog_req_i.ar_cache := Mux(bypassProg, 0.U, ctrl.ar.bits.cache)
    bb.io.prog_req_i.ar_prot  := Mux(bypassProg, 0.U, ctrl.ar.bits.prot)
    bb.io.prog_req_i.ar_qos   := Mux(bypassProg, 0.U, ctrl.ar.bits.qos)
    bb.io.prog_req_i.ar_region:= 0.U
    bb.io.prog_req_i.ar_user  := 0.U
    bb.io.prog_req_i.ar_valid := Mux(bypassProg, false.B, ctrl.ar.valid)
    val rValidBypass = RegInit(false.B)
    val rId          = Reg(UInt(slaveIdBits.W))
    when (ctrl.ar.fire) { rValidBypass := true.B; rId := ctrl.ar.bits.id }
    when (ctrl.r.fire)  { rValidBypass := false.B }
    ctrl.ar.ready             := Mux(bypassProg, !rValidBypass, bb.io.prog_resp_o.ar_ready)
    bb.io.prog_req_i.axMMUSID   := 1.U
    bb.io.prog_req_i.axMMUSSID  := 1.U
    bb.io.prog_req_i.axMMUSSIDV := true.B

    // R channel
    ctrl.r.bits.id           := Mux(bypassProg, rId, bb.io.prog_resp_o.r_id)
    ctrl.r.bits.data         := Mux(bypassProg, 0.U, bb.io.prog_resp_o.r_data)
    ctrl.r.bits.resp         := Mux(bypassProg, 0.U, bb.io.prog_resp_o.r_resp)
    ctrl.r.bits.last         := Mux(bypassProg, true.B, bb.io.prog_resp_o.r_last)
    ctrl.r.bits.user         := 0.U.asTypeOf(ctrl.r.bits.user)
    ctrl.r.valid             := Mux(bypassProg, rValidBypass, bb.io.prog_resp_o.r_valid)
    bb.io.prog_req_i.r_ready := Mux(bypassProg, false.B, ctrl.r.ready)

    // Tie off unused ports
    // Hook AXI masters to TileLink (sbus) via AXI4ToTL
    val (dsOut,   _) = dsNode.out.head
    val (compOut, _) = compNode.out.head

    // Pack MMU user (same layout as in flat SV wrapper)
    val mmuUserPack = Cat(bb.io.dev_tr_req_i.axMMUSID, bb.io.dev_tr_req_i.axMMUSSIDV, bb.io.dev_tr_req_i.axMMUSSID)

    // Drive DS master
    dsOut.aw.valid       := bb.io.ds_req_o.aw_valid
    dsOut.aw.bits.id     := bb.io.ds_req_o.aw_id
    dsOut.aw.bits.addr   := bb.io.ds_req_o.aw_addr
    dsOut.aw.bits.len    := bb.io.ds_req_o.aw_len
    dsOut.aw.bits.size   := bb.io.ds_req_o.aw_size
    dsOut.aw.bits.burst  := bb.io.ds_req_o.aw_burst
    dsOut.aw.bits.lock   := bb.io.ds_req_o.aw_lock
    dsOut.aw.bits.cache  := bb.io.ds_req_o.aw_cache
    dsOut.aw.bits.prot   := bb.io.ds_req_o.aw_prot
    dsOut.aw.bits.qos    := bb.io.ds_req_o.aw_qos
    // region/atop are not modeled in Rocket-Chip AXI4 bundle
    dsOut.aw.bits.user.lift(MmuUser).foreach(_ := mmuUserPack)
    dsOut.w.valid        := bb.io.ds_req_o.w_valid
    dsOut.w.bits.data    := bb.io.ds_req_o.w_data
    dsOut.w.bits.strb    := bb.io.ds_req_o.w_strb
    dsOut.w.bits.last    := bb.io.ds_req_o.w_last
    dsOut.ar.valid       := bb.io.ds_req_o.ar_valid
    dsOut.ar.bits.id     := bb.io.ds_req_o.ar_id
    dsOut.ar.bits.addr   := bb.io.ds_req_o.ar_addr
    dsOut.ar.bits.len    := bb.io.ds_req_o.ar_len
    dsOut.ar.bits.size   := bb.io.ds_req_o.ar_size
    dsOut.ar.bits.burst  := bb.io.ds_req_o.ar_burst
    dsOut.ar.bits.lock   := bb.io.ds_req_o.ar_lock
    dsOut.ar.bits.cache  := bb.io.ds_req_o.ar_cache
    dsOut.ar.bits.prot   := bb.io.ds_req_o.ar_prot
    dsOut.ar.bits.qos    := bb.io.ds_req_o.ar_qos
    // region not modeled in Rocket-Chip AXI4 bundle
    dsOut.ar.bits.user.lift(MmuUser).foreach(_ := mmuUserPack)
    dsOut.b.ready        := bb.io.ds_req_o.b_ready
    dsOut.r.ready        := bb.io.ds_req_o.r_ready
    // DS responses
    bb.io.ds_resp_i.aw_ready := dsOut.aw.ready
    bb.io.ds_resp_i.w_ready  := dsOut.w.ready
    bb.io.ds_resp_i.ar_ready := dsOut.ar.ready
    bb.io.ds_resp_i.b_valid  := dsOut.b.valid
    bb.io.ds_resp_i.b_id     := dsOut.b.bits.id
    bb.io.ds_resp_i.b_resp   := dsOut.b.bits.resp
    bb.io.ds_resp_i.b_user   := 0.U
    bb.io.ds_resp_i.r_valid  := dsOut.r.valid
    bb.io.ds_resp_i.r_id     := dsOut.r.bits.id
    bb.io.ds_resp_i.r_data   := dsOut.r.bits.data
    bb.io.ds_resp_i.r_resp   := dsOut.r.bits.resp
    bb.io.ds_resp_i.r_last   := dsOut.r.bits.last
    bb.io.ds_resp_i.r_user   := 0.U

    // Drive Completion master
    compOut.aw.valid       := bb.io.dev_comp_req_o.aw_valid
    compOut.aw.bits.id     := bb.io.dev_comp_req_o.aw_id
    compOut.aw.bits.addr   := bb.io.dev_comp_req_o.aw_addr
    compOut.aw.bits.len    := bb.io.dev_comp_req_o.aw_len
    compOut.aw.bits.size   := bb.io.dev_comp_req_o.aw_size
    compOut.aw.bits.burst  := bb.io.dev_comp_req_o.aw_burst
    compOut.aw.bits.lock   := bb.io.dev_comp_req_o.aw_lock
    compOut.aw.bits.cache  := bb.io.dev_comp_req_o.aw_cache
    compOut.aw.bits.prot   := bb.io.dev_comp_req_o.aw_prot
    compOut.aw.bits.qos    := bb.io.dev_comp_req_o.aw_qos
    // region/atop are not modeled in Rocket-Chip AXI4 bundle
    compOut.aw.bits.user.lift(MmuUser).foreach(_ := mmuUserPack)
    compOut.w.valid        := bb.io.dev_comp_req_o.w_valid
    compOut.w.bits.data    := bb.io.dev_comp_req_o.w_data
    compOut.w.bits.strb    := bb.io.dev_comp_req_o.w_strb
    compOut.w.bits.last    := bb.io.dev_comp_req_o.w_last
    compOut.ar.valid       := bb.io.dev_comp_req_o.ar_valid
    compOut.ar.bits.id     := bb.io.dev_comp_req_o.ar_id
    compOut.ar.bits.addr   := bb.io.dev_comp_req_o.ar_addr
    compOut.ar.bits.len    := bb.io.dev_comp_req_o.ar_len
    compOut.ar.bits.size   := bb.io.dev_comp_req_o.ar_size
    compOut.ar.bits.burst  := bb.io.dev_comp_req_o.ar_burst
    compOut.ar.bits.lock   := bb.io.dev_comp_req_o.ar_lock
    compOut.ar.bits.cache  := bb.io.dev_comp_req_o.ar_cache
    compOut.ar.bits.prot   := bb.io.dev_comp_req_o.ar_prot
    compOut.ar.bits.qos    := bb.io.dev_comp_req_o.ar_qos
    // region not modeled in Rocket-Chip AXI4 bundle
    compOut.ar.bits.user.lift(MmuUser).foreach(_ := mmuUserPack)
    compOut.b.ready        := bb.io.dev_comp_req_o.b_ready
    compOut.r.ready        := bb.io.dev_comp_req_o.r_ready
    // Completion responses
    bb.io.dev_comp_resp_i.aw_ready := compOut.aw.ready
    bb.io.dev_comp_resp_i.w_ready  := compOut.w.ready
    bb.io.dev_comp_resp_i.ar_ready := compOut.ar.ready
    bb.io.dev_comp_resp_i.b_valid  := compOut.b.valid
    bb.io.dev_comp_resp_i.b_id     := compOut.b.bits.id
    bb.io.dev_comp_resp_i.b_resp   := compOut.b.bits.resp
    bb.io.dev_comp_resp_i.b_user   := 0.U
    bb.io.dev_comp_resp_i.r_valid  := compOut.r.valid
    bb.io.dev_comp_resp_i.r_id     := compOut.r.bits.id
    bb.io.dev_comp_resp_i.r_data   := compOut.r.bits.data
    bb.io.dev_comp_resp_i.r_resp   := compOut.r.bits.resp
    bb.io.dev_comp_resp_i.r_last   := compOut.r.bits.last
    bb.io.dev_comp_resp_i.r_user   := 0.U

    // -------------------------------
    // Device translation AXI slave (optional)
    // -------------------------------
    devNodeOpt match {
      case Some(devNode) =>
        val (devIn, _) = devNode.in.head
        // AW channel
        bb.io.dev_tr_req_i.aw_id    := devIn.aw.bits.id
        bb.io.dev_tr_req_i.aw_addr  := devIn.aw.bits.addr
        bb.io.dev_tr_req_i.aw_len   := devIn.aw.bits.len
        bb.io.dev_tr_req_i.aw_size  := devIn.aw.bits.size
        bb.io.dev_tr_req_i.aw_burst := devIn.aw.bits.burst
        bb.io.dev_tr_req_i.aw_lock  := devIn.aw.bits.lock
        bb.io.dev_tr_req_i.aw_cache := devIn.aw.bits.cache
        bb.io.dev_tr_req_i.aw_prot  := devIn.aw.bits.prot
        bb.io.dev_tr_req_i.aw_qos   := devIn.aw.bits.qos
        bb.io.dev_tr_req_i.aw_region:= 0.U
        bb.io.dev_tr_req_i.aw_atop  := 0.U
        bb.io.dev_tr_req_i.aw_user  := 0.U
        bb.io.dev_tr_req_i.aw_valid := devIn.aw.valid
        devIn.aw.ready              := bb.io.dev_tr_resp_o.aw_ready
        // W
        bb.io.dev_tr_req_i.w_data  := devIn.w.bits.data
        bb.io.dev_tr_req_i.w_strb  := devIn.w.bits.strb
        bb.io.dev_tr_req_i.w_last  := devIn.w.bits.last
        bb.io.dev_tr_req_i.w_user  := 0.U
        bb.io.dev_tr_req_i.w_valid := devIn.w.valid
        devIn.w.ready              := bb.io.dev_tr_resp_o.w_ready
        // AR
        bb.io.dev_tr_req_i.ar_id    := devIn.ar.bits.id
        bb.io.dev_tr_req_i.ar_addr  := devIn.ar.bits.addr
        bb.io.dev_tr_req_i.ar_len   := devIn.ar.bits.len
        bb.io.dev_tr_req_i.ar_size  := devIn.ar.bits.size
        bb.io.dev_tr_req_i.ar_burst := devIn.ar.bits.burst
        bb.io.dev_tr_req_i.ar_lock  := devIn.ar.bits.lock
        bb.io.dev_tr_req_i.ar_cache := devIn.ar.bits.cache
        bb.io.dev_tr_req_i.ar_prot  := devIn.ar.bits.prot
        bb.io.dev_tr_req_i.ar_qos   := devIn.ar.bits.qos
        bb.io.dev_tr_req_i.ar_region:= 0.U
        bb.io.dev_tr_req_i.ar_user  := 0.U
        bb.io.dev_tr_req_i.ar_valid := devIn.ar.valid
        devIn.ar.ready              := bb.io.dev_tr_resp_o.ar_ready
        // Ready
        bb.io.dev_tr_req_i.b_ready  := devIn.b.ready
        bb.io.dev_tr_req_i.r_ready  := devIn.r.ready
        // Device response
        devIn.b.valid     := bb.io.dev_tr_resp_o.b_valid
        devIn.b.bits.id   := bb.io.dev_tr_resp_o.b_id
        devIn.b.bits.resp := bb.io.dev_tr_resp_o.b_resp
        devIn.r.valid     := bb.io.dev_tr_resp_o.r_valid
        devIn.r.bits.id   := bb.io.dev_tr_resp_o.r_id
        devIn.r.bits.data := bb.io.dev_tr_resp_o.r_data
        devIn.r.bits.resp := bb.io.dev_tr_resp_o.r_resp
        devIn.r.bits.last := bb.io.dev_tr_resp_o.r_last
        // Default MMU IDs with optional override from AXI user signals
        val mmuSid   = WireDefault(params.devDefaultSid.U(24.W))
        val mmuSsid  = WireDefault(params.devDefaultSsid.U(20.W))
        val mmuSsidV = WireDefault(params.devDefaultSsidValid.B)

        devIn.aw.bits.user.lift(MMUStreamKey).foreach { user =>
          mmuSid   := user.sid
          mmuSsid  := user.ssid
          mmuSsidV := user.ssidv
        }
        devIn.ar.bits.user.lift(MMUStreamKey).foreach { user =>
          mmuSid   := user.sid
          mmuSsid  := user.ssid
          mmuSsidV := user.ssidv
        }

        bb.io.dev_tr_req_i.axMMUSID   := mmuSid
        bb.io.dev_tr_req_i.axMMUSSID  := mmuSsid
        bb.io.dev_tr_req_i.axMMUSSIDV := mmuSsidV
      case None =>
        // Tie off device translation when not exposed
        bb.io.dev_tr_req_i := 0.U.asTypeOf(bb.io.dev_tr_req_i)
    }
    // Map all WSI interrupt wires to PLIC via IntSourceNode
    val (io_int, _) = intNode.out(0)
    for (i <- 0 until exposedIrqs) {
      io_int(i) := bb.io.wsi_wires(i)
    }
  }
}

trait CanHavePeripheryIOMMU { this: BaseSubsystem =>
  val iommuOpt = p(IOMMUKey).map { params =>
    //IOMMU LazyModule
    val iommu = LazyModule(new IOMMU(params))
    pbus.coupleTo("iommu-csr") {
      iommu.progNode :=
        AXI4Buffer() :=               // smooth bursts before conversion
        // Preserve TL state (source/size) even though the IOMMU AXI slave
        // does not propagate AXI echo fields.
        AXI4UserYanker() :=
        TLToAXI4(adapterName = Some("iommu_csr")) := // TL CPU MMIO -> AXI4 control
        TLBuffer() :=                 // absorb TL side latency before conversion
        // Allow cache-line-sized accesses; fragment down to the IOMMU's beat width
        TLFragmenter(params.dataBits / 8, pbus.blockBytes, holdFirstDeny = true) :=
        TLWidthWidget(pbus.beatBytes) :=
        TLFIFOFixer() := _
    }
    // Hook interrupts into the global interrupt bus (PLIC)
    ibus.fromSync := iommu.intNode
    // // Connect IOMMU AXI masters to system bus via AXI4ToTL
    // sbus.coupleFrom("iommu-ds") { bus =>
    //   bus :=
    //     //TLSourceShrinker(16) :={gtkwave NET OFF} 
    //     TLBuffer() :=
    //     AXI4ToTL() :=                       // AXI -> TL conversion
    //     AXI4Buffer() :=                     // absorb latency backpressure
    //     //AXI4IdIndexer(4) :=                 // clamp ID width, preserve distinct IDs (e.g., CQ=2)
    //     iommu.dsNode
    // }
    // sbus.coupleFrom("iommu-comp") { bus =>
    //   bus :=
    //     //TLSourceShrinker(16) :=
    //     TLBuffer() :=
    //     AXI4ToTL() :=
    //     AXI4Buffer() :=
    //     //AXI4IdIndexer(4) :=
    //     iommu.compNode
    // }
    sbus.coupleFrom("iommu_ds") { bus =>
      bus :=
        TLBuffer() :=                 // decouple
        AXI4ToTL() :=                 // bridge
        AXI4Buffer() :=
        iommu.dsNode
    }

    sbus.coupleFrom("iommu-comp") { bus =>
      bus :=
        TLBuffer() :=
        AXI4ToTL() :=
        AXI4Buffer() :=
        iommu.compNode
    }
    iommu
  }
}


class WithIOMMU(base: BigInt = 0x50010000L,
                dataBits: Int = 64,
                exposeAllWsis: Boolean = false)
  extends Config((site, here, up) => {
    case IOMMUKey => Some(IOMMUParams(base, dataBits, exposeAllWsis = exposeAllWsis))
  })

// Variant that exposes the IOMMU device-translation AXI slave for external devices
class WithIOMMUDevSlave(base: BigInt = 0x50010000L,
                        dataBits: Int = 64,
                        devDefaultSid: Int = 1,
                        devDefaultSsid: Int = 0,
                        devDefaultSsidValid: Boolean = false,
                        exposeAllWsis: Boolean = true,
                        devAddrBits: Int = 48)
  extends Config((site, here, up) => {
    case IOMMUKey => Some(IOMMUParams(
      baseAddress         = base,
      dataBits            = dataBits,
      exposeDevSlave      = true,
      devDefaultSid       = devDefaultSid,
      devDefaultSsid      = devDefaultSsid,
      devDefaultSsidValid = devDefaultSsidValid,
      exposeAllWsis       = exposeAllWsis,
      devAddrBits         = devAddrBits))
  })

package zerodaylabs.blocks.iommu

import chisel3._
import freechips.rocketchip.util.{BundleField, ControlKey}

class MMUStreamBundle extends Bundle {
  val sid   = UInt(24.W)
  val ssid  = UInt(20.W)
  val ssidv = Bool()
}

case object MMUStreamKey extends ControlKey[MMUStreamBundle]("mmu_stream")
case class MMUStreamField() extends BundleField(MMUStreamKey) {
  def data: MMUStreamBundle = Output(new MMUStreamBundle)
  def default(x: MMUStreamBundle): Unit = {
    x.sid   := 0.U
    x.ssid  := 0.U
    x.ssidv := false.B
  }
}

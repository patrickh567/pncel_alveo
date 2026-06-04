"""
High-level driver for the mini_dice_alveo FPGA image.

Talks to the chip over XDMA:
  - CSR programming through the AXI-Lite packet FIFO (axi_lite_fifo →
    OP_WRITE packet → chip's cgra_io_csr).
  - BRAM preload + result read-back through h2c/c2h DMA into the BRAM
    partitions baked into mini_dice_alveo_dynamic_region.sv:
        META  region: BRAM 0x0000.. (chip mfetch addr X  → BRAM byte X)
        BS    region: BRAM 0x4000.. (chip bsfetch addr X → BRAM byte X + 0x4000)
        DATA  region: BRAM 0x8000.. (chip dfetch addr X  → BRAM byte 8X + 0x8000)

All address constants are derived directly from:
  /data2/pdh4/pncel_alveo/src/mini_dice_alveo_dynamic_region.sv
      `BS_BRAM_OFFSET = 17'h4000`
      `DATA_BRAM_OFFSET_WORDS = 17'h2000`  (cache word units; ×4 = 0x8000 byte units)
  /data2/pdh4/pncel_alveo/script/mini_dice_alveo_build.tcl:286-287
      `M02_SEG00_BASE_ADDR = 0x0000000400000000`
  /data2/pdh4/pncel_alveo/src/utility/vivado_ip/axil_host_switch.tcl
      M02 SEG00 = 0x0008_0000 (axi_lite_fifo aperture, 1 MB BAR layout)
  ~/repos/Mini_Dice_Backend/Mini_Dice/rtl/cgra_core/internal_memory/cgra_io_csr.sv
      REG_CTRL = 0xFF00, REG_STARTPC = 0xFF02, REG_STATUS = 0xFF04,
      REG_THREAD_COUNT = 0xFF0C, REG_CSRX0..7 = 0xFF10..0xFF1E
"""

from __future__ import annotations

import struct
import time
from typing import Iterable, List, Optional, Sequence

from cosim import CosimSocket, XdmaCosimBar, XdmaCosimC2H, XdmaCosimH2C
from xdma import XdmaC2H, XdmaH2C, XdmaUserBar


class MiniDice:

    # -- AXI-Lite (BAR1) aperture ------------------------------------------
    # 1 MB BAR (XDMA axilite_master_size=1).  Both apertures live inside
    # axil_host_switch.M02 SEG00 (0x80000..0x9FFFF, 128 KB).  Kept in
    # sync with `mini_dice_alveo_dynamic_region.sv:LITE_FIFO_BASE`,
    # `mini_dice_zcu102_top.sv:LITE_FIFO_BASE`, all three
    # `axi_lite_switch_xbar` IP TCLs, and the smoke/cta TBs.
    FIFO_BASE   = 0x0008_0000  # CSR-write FIFO (chip CSR addr at low 16 b)
    REGMAP_BASE = 0x0009_0000  # generic loopback regmap (16 × 4 B)

    # -- BRAM (DMA) base + region offsets -----------------------------------
    BRAM_DMA_BASE = 0x0000_0004_0000_0000  # axi_dma_switch.M02 SEG00
    META_BRAM_OFF = 0x0000   # chip mfetch addr X → BRAM byte X
    BS_BRAM_OFF   = 0x4000   # chip bsfetch addr X → BRAM byte X + 0x4000
    DATA_BRAM_OFF = 0x8000   # chip dfetch addr X → BRAM byte 8X + 0x8000

    # -- Chip-side CSR offsets (all 16-bit registers, 2-byte stride) --------
    REG_CTRL          = 0xFF00  # bit 0 = START pulse, bit 1 = cgra_reset, bit 2 = bsload_en
    REG_STARTPC       = 0xFF02
    REG_STATUS        = 0xFF04  # [0]complete [1]busy [2]dispatching [3]stack_overflow
    REG_BSLOAD_CNT    = 0xFF06  # bitstream-load word counter (RO)
    REG_STACK_DEPTH   = 0xFF08  # current SIMT stack depth (RO)
    REG_ERROR_INFO    = 0xFF0A  # error address/code, sticky (RO)
    REG_THREAD_COUNT  = 0xFF0C
    REG_CSRX_BASE     = 0xFF10
    CTRL_START        = 0x0001
    STATUS_COMPLETE       = 0x0001
    STATUS_BUSY           = 0x0002
    STATUS_DISPATCHING    = 0x0004
    STATUS_STACK_OVERFLOW = 0x0008

    def __init__(
        self,
        bar: XdmaUserBar,
        h2c: XdmaH2C,
        c2h: XdmaC2H,
        *,
        mock: bool = False,
        verbose: bool = False,
    ):
        self._bar = bar
        self._h2c = h2c
        self._c2h = c2h
        self.mock = mock
        self.verbose = verbose

    # -- Convenience constructor -------------------------------------------

    @classmethod
    def from_env(
        cls,
        device_id: int = 0,
        *,
        mock: bool = False,
        cosim: bool = False,
        cosim_sock_path: str = "/tmp/mda_cosim.sock",
        cosim_timeout_s: float = 60.0,
        verbose: bool = False,
    ) -> "MiniDice":
        """Build a MiniDice driver with one of three backends.

        - real hardware (default): opens /dev/xdma{device_id}_{user,h2c_0,c2h_0}.
        - `mock=True`: shared in-memory dict (no FPGA, no sim).  Pure host
          control-flow smoke; the chip's behaviour is stubbed by helper
          logic in launch_cta/wait_for_cta_done.
        - `cosim=True`: one Unix socket to a running VCS sim; all reads/
          writes are framed and dispatched to the SV cosim bridge.

        Exactly one of mock/cosim may be set.
        """
        if mock and cosim:
            raise ValueError("MiniDice.from_env: pick at most one of mock=, cosim=")

        if cosim:
            sock = CosimSocket(path=cosim_sock_path, timeout=cosim_timeout_s).connect()
            bar = XdmaCosimBar(sock)
            h2c = XdmaCosimH2C(sock)
            c2h = XdmaCosimC2H(sock)
            instance = cls(bar, h2c, c2h, mock=False, verbose=verbose)
            instance._cosim_sock = sock  # so close() can quit the sim
            return instance

        shared_mock_mem = {} if mock else None
        bar = XdmaUserBar(path=f"/dev/xdma{device_id}_user", mock=mock).open()
        h2c = XdmaH2C(path=f"/dev/xdma{device_id}_h2c_0",
                      mock=mock, mock_mem=shared_mock_mem).open()
        c2h = XdmaC2H(path=f"/dev/xdma{device_id}_c2h_0",
                      mock=mock, mock_mem=shared_mock_mem).open()
        return cls(bar, h2c, c2h, mock=mock, verbose=verbose)

    def close(self) -> None:
        self._bar.close()
        self._h2c.close()
        self._c2h.close()
        sock = getattr(self, "_cosim_sock", None)
        if sock is not None:
            sock.quit()  # also closes the underlying socket
            self._cosim_sock = None

    def __enter__(self) -> "MiniDice":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    # -- CSR access --------------------------------------------------------

    def csr_write(self, chip_offset: int, value: int) -> None:
        """Write a chip CSR.

        The host's AXI-Lite address is `FIFO_BASE | chip_offset` — the
        axi_lite_fifo extracts the low 16 bits of the bus address and
        emits them as the chip's CSR offset inside an OP_WRITE packet
        that reaches cgra_io_csr via axi_link_rx.
        """
        host_addr = self.FIFO_BASE | chip_offset
        if self.verbose:
            print(f"  csr_write [0x{chip_offset:04x}] <= 0x{value & 0xFFFF:04x} "
                  f"(host BAR addr 0x{host_addr:06x})")
        self._bar.write32(host_addr, value & 0xFFFF)

    def csr_read(self, chip_offset: int) -> int:
        """Read a chip CSR.

        Goes through axil_read_packet_former → chip → axil_read_response_handler;
        from the host's perspective it's a regular AXI-Lite read that
        stalls until the chip responds.
        """
        host_addr = self.FIFO_BASE | chip_offset
        v = self._bar.read32(host_addr) & 0xFFFF
        if self.verbose:
            print(f"  csr_read  [0x{chip_offset:04x}] -> 0x{v:04x}")
        return v

    # -- BRAM preload / read-back ------------------------------------------

    def bram_write_meta(self, chip_addr: int, data: bytes) -> None:
        addr = self.BRAM_DMA_BASE + self.META_BRAM_OFF + chip_addr
        self._h2c.write(addr, data)

    def bram_write_bs(self, chip_addr: int, data: bytes) -> None:
        addr = self.BRAM_DMA_BASE + self.BS_BRAM_OFF + chip_addr
        self._h2c.write(addr, data)

    def bram_read_meta(self, chip_addr: int, nbytes: int) -> bytes:
        """Read `nbytes` back from the META (mfetch) BRAM region via c2h."""
        addr = self.BRAM_DMA_BASE + self.META_BRAM_OFF + chip_addr
        return self._c2h.read(addr, nbytes)

    def bram_read_bs(self, chip_addr: int, nbytes: int) -> bytes:
        """Read `nbytes` back from the BS (bsfetch) BRAM region via c2h."""
        addr = self.BRAM_DMA_BASE + self.BS_BRAM_OFF + chip_addr
        return self._c2h.read(addr, nbytes)

    def bram_write_data_word(self, chip_addr: int, value: int) -> None:
        """Write a 32-bit value into the chip dfetch slot for `chip_addr`.

        Each chip dfetch addr maps to an 8-byte BRAM slot (only the low
        32-bit word is read; the upper 4 bytes stay 0).
        """
        addr = self.BRAM_DMA_BASE + self.DATA_BRAM_OFF + 8 * chip_addr
        self._h2c.write(addr, struct.pack("<I", value & 0xFFFF_FFFF) + b"\x00\x00\x00\x00")

    def bram_read_data_word(self, chip_addr: int) -> int:
        """Read the 32-bit value currently in the chip dfetch slot for `chip_addr`.

        Used post-CTA to recover whatever the chip wrote.
        """
        addr = self.BRAM_DMA_BASE + self.DATA_BRAM_OFF + 8 * chip_addr
        raw = self._c2h.read(addr, 4)
        return struct.unpack("<I", raw)[0]

    def preload_data_echo(self, max_chip_addr: int = 0x400) -> None:
        """Preload the dfetch BRAM region with an address-echo pattern.

        Each chip dfetch read at chip_addr X gets BRAM[8X+0x8000][15:0] back,
        which the dynamic_region's tag-echo wrapper then merges with the
        request's {tid,eblock,regaddr} in bits [28:16].  For the bundled
        test vectors that were authored against the upstream EP's
        `axi_read16(addr) = addr & 0xFFFF` behavior, this echo data IS the
        operand stream the kernel expects.

        For a real workload, the host would write actual operand values
        here instead.
        """
        buf = bytearray(8 * max_chip_addr)
        for x in range(max_chip_addr):
            struct.pack_into("<I", buf, 8 * x, x & 0xFFFF)
        self._h2c.write(self.BRAM_DMA_BASE + self.DATA_BRAM_OFF, bytes(buf))
        # Verify the DATA (operand) region landed — same HW-only XDMA H2C
        # transport as META/BS; the kernel reads its operands from here, so a
        # mis-landed echo silently yields wrong compute results.  Skipped in
        # mock (no real BRAM round-trip).
        if not self.mock:
            got = self._c2h.read(self.BRAM_DMA_BASE + self.DATA_BRAM_OFF, len(buf))
            if got != bytes(buf):
                n = min(len(got), len(buf))
                i = next((k for k in range(n) if got[k] != buf[k]), n)
                base = i & ~7
                got_w = bytes(got[base:base + 8]).hex() if len(got) >= base + 8 else "<short>"
                raise RuntimeError(
                    f"DATA echo preload readback MISMATCH at byte 0x{i:x} "
                    f"(chip_addr 0x{base // 8:x}): wrote {bytes(buf[base:base + 8]).hex()} "
                    f"read {got_w}. The kernel will read wrong operands and "
                    f"compute wrong results."
                )

    # -- CTA launch + completion ------------------------------------------

    def launch_cta(
        self,
        start_pc: int,
        thread_count: int,
        csr_values: Sequence[int],
    ) -> None:
        """Program one CTA's CSRs and pulse START.

        csr_values must be length 8 (csrX0..7).  Caller is responsible
        for resolving per-CTA overrides upstream (test_vector.effective_csrs).
        """
        assert len(csr_values) == 8, "csr_values must be length 8"
        if self.verbose:
            print(f"  launch_cta start_pc=0x{start_pc:04x} "
                  f"tc={thread_count} csrs={[hex(v) for v in csr_values]}")
        self.csr_write(self.REG_STARTPC, start_pc)
        self.csr_write(self.REG_THREAD_COUNT, thread_count)
        for i, v in enumerate(csr_values):
            self.csr_write(self.REG_CSRX_BASE + 2 * i, v)
        if not self.mock:
            # Verify the launch CSRs actually landed in the chip BEFORE START.
            # The CSR WRITE path crosses the AXI-Lite CDC + axi_lite_fifo -> chip
            # link; cosim injects these and may not exercise it.  A dropped
            # STARTPC/THREAD_COUNT/CSRX leaves the dispatcher with garbage and
            # wedges it (STATUS busy+dispatching, kernel never runs).  CSR reads
            # are known-good on this path, so a write/read mismatch isolates the
            # write direction specifically.
            mism = []
            checks = [("STARTPC", self.REG_STARTPC, start_pc),
                      ("THREAD_COUNT", self.REG_THREAD_COUNT, thread_count)]
            checks += [(f"CSRX{i}", self.REG_CSRX_BASE + 2 * i, v)
                       for i, v in enumerate(csr_values)]
            for nm, off, wrote in checks:
                rb = self.csr_read(off) & 0xFFFF
                if rb != (wrote & 0xFFFF):
                    mism.append(f"{nm} w=0x{wrote & 0xFFFF:04x} r=0x{rb:04x}")
            if mism:
                print("  [WARN] launch CSR write-readback MISMATCH (CSR WRITE path "
                      "dropping writes -> dispatcher will hang): " + "; ".join(mism))
        self.csr_write(self.REG_CTRL, self.CTRL_START)
        if self.mock:
            # Mock-only: simulate the chip's clear-on-start.
            # Without this the wait_for_cta_done race-fix would never see
            # complete_sticky drop low.
            self._bar.write32(self.FIFO_BASE | self.REG_STATUS, 0)

    def wait_for_cta_done(
        self,
        timeout_s: float = 5.0,
        poll_interval_s: float = 1e-4,
    ) -> float:
        """Poll REG_STATUS bit 0 until the chip signals CTA completion.

        Two-phase wait (mirrors the sim TB's race fix in
        tb_mini_dice_alveo_cta.sv `wait_for_cta_done`):

          1. Wait for complete_sticky to drop to 0.  This proves the
             prior START pulse has actually propagated to the chip's
             CSR block, clearing the stale "done" from the prior CTA.
             Without this, the very next poll would see the *previous*
             CTA's sticky bit and return spuriously in 0 cycles —
             multi-CTA tests would silently skip half their CTAs.
          2. Wait for complete_sticky to rise to 1 (chip done).

        Returns the total wait time in seconds.
        """
        t0 = time.monotonic()

        # In mock mode, fast-forward the simulated chip through the
        # drop+rise transitions so we exercise both polling loops.
        if self.mock:
            self._bar.write32(self.FIFO_BASE | self.REG_STATUS, 0)

        # Phase 1: drop wait.
        clear_deadline = t0 + timeout_s
        while self.csr_read(self.REG_STATUS) & self.STATUS_COMPLETE:
            if time.monotonic() > clear_deadline:
                raise TimeoutError(
                    "complete_sticky never dropped after CTRL.START pulse "
                    f"(waited {timeout_s}s)"
                )
            time.sleep(poll_interval_s)

        if self.mock:
            # Simulate the chip finishing the CTA.
            self._bar.write32(self.FIFO_BASE | self.REG_STATUS, 1)

        # Phase 2: rise wait.
        done_deadline = t0 + timeout_s
        while not (self.csr_read(self.REG_STATUS) & self.STATUS_COMPLETE):
            if time.monotonic() > done_deadline:
                raise TimeoutError(
                    f"complete_sticky never set after START (timeout {timeout_s}s)"
                )
            time.sleep(poll_interval_s)

        elapsed = time.monotonic() - t0
        if self.verbose:
            print(f"  CTA done in {elapsed * 1e3:.2f} ms")
        return elapsed

    # -- Misc --------------------------------------------------------------

    # Regmap reg #2 bit 0 — SOFT_RESET.  Writing 1 starts the soft-reset
    # FSM in mini_dice_alveo_dynamic_region.sv: holds __alveo_reset__ and
    # chip_async_rst high for SOFT_RST_CYCLES (=32) aclk ticks, then auto-
    # clears the bit via regs_we_i[2]+regs_wd_i[2]=0.  Resets cache
    # hierarchy + chip + dynamic-region plumbing; CSR path (host switch,
    # lite switch/FIFO, regmap itself) stays on aresetn so polling works
    # throughout the pulse.
    SOFT_RESET_OFFSET   = 0x0008   # reg #2 byte offset
    SOFT_RESET_TIMEOUT  = 1.0      # seconds (real pulse is ~128 ns)

    def reset_chip(self) -> None:
        """Pulse the host-driven SOFT_RESET, then wait for hardware auto-clear.

        Real HW / cosim: write 1 to regmap reg #2 bit 0, poll until the
        bit clears (FSM ran its 32-cycle reset pulse).

        Mock backend: there's no FSM to auto-clear, so we just clear the
        bit ourselves — the host-side state still gets exercised.
        """
        addr = self.REGMAP_BASE | self.SOFT_RESET_OFFSET
        self._bar.write32(addr, 0x1)
        if self.mock:
            # No hardware FSM in the mock dict; emulate the auto-clear so
            # callers' poll loops (and our own) terminate cleanly.
            self._bar.write32(addr, 0x0)
            return
        deadline = time.monotonic() + self.SOFT_RESET_TIMEOUT
        while time.monotonic() < deadline:
            if (self._bar.read32(addr) & 0x1) == 0:
                return
        raise TimeoutError(
            f"SOFT_RESET bit at 0x{addr:08x} did not clear within "
            f"{self.SOFT_RESET_TIMEOUT}s"
        )

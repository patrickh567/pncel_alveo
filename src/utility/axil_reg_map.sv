// *************************************************************************
//
// AXI-Lite register map with parameterizable number of registers
//
// Each register is 32-bit, word-aligned (4-byte stride).
// Provides a flat array of register values and per-register write strobes.
//
// *************************************************************************
`timescale 1ns/1ps
module axil_reg_map #(
  parameter int NUM_REGS    = 8,
  parameter int ADDR_W      = $clog2(NUM_REGS) + 2,
  // Reset values for each register (packed array)
  parameter logic [NUM_REGS-1:0][31:0] REG_RESET = '0,
  // Per-register read-only mask: 1 = read-only bit, 0 = read-write bit
  parameter logic [NUM_REGS-1:0][31:0] REG_RO    = '0
) (
  axi_if.slave s_axil,

  // Register interface
  output logic [NUM_REGS-1:0][31:0] reg_out,
  input  logic [NUM_REGS-1:0][31:0] reg_in,
  output logic [NUM_REGS-1:0]       reg_wr
);

  localparam int IDX_W = $clog2(NUM_REGS);

  // =========================================================================
  // Registers
  // =========================================================================
  logic [NUM_REGS-1:0][31:0] regs;

  // =========================================================================
  // Write channel
  // =========================================================================
  typedef enum logic [1:0] {
    W_IDLE,
    W_DATA,
    W_RESP
  } wr_state_t;

  wr_state_t          wr_state;
  logic [ADDR_W-1:0]  wr_addr;

  always_ff @(posedge s_axil.aclk) begin
    if (!s_axil.aresetn) begin
      wr_state       <= W_IDLE;
      wr_addr        <= '0;
      s_axil.awready <= 1'b1;
      s_axil.wready  <= 1'b1;
      s_axil.bvalid  <= 1'b0;
      s_axil.bresp   <= 2'b00;
      reg_wr         <= '0;
      for (int i = 0; i < NUM_REGS; i++) begin
        regs[i] <= REG_RESET[i];
      end
    end else begin
      reg_wr <= '0;

      case (wr_state)
        W_IDLE: begin
          if (s_axil.awvalid && s_axil.wvalid) begin
            // Both address and data available
            s_axil.awready <= 1'b0;
            s_axil.wready  <= 1'b0;
            wr_addr        <= s_axil.awaddr[ADDR_W-1:0];
            // Write register
            if (s_axil.awaddr[ADDR_W-1:2] < NUM_REGS[IDX_W:0]) begin
              for (int b = 0; b < 4; b++) begin
                if (s_axil.wstrb[b]) begin
                  regs[s_axil.awaddr[IDX_W+1:2]][b*8 +: 8] <=
                    (s_axil.wdata[b*8 +: 8] & ~REG_RO[s_axil.awaddr[IDX_W+1:2]][b*8 +: 8]) |
                    (regs[s_axil.awaddr[IDX_W+1:2]][b*8 +: 8] & REG_RO[s_axil.awaddr[IDX_W+1:2]][b*8 +: 8]);
                end
              end
              reg_wr[s_axil.awaddr[IDX_W+1:2]] <= 1'b1;
            end
            s_axil.bvalid <= 1'b1;
            s_axil.bresp  <= (s_axil.awaddr[ADDR_W-1:2] < NUM_REGS[IDX_W:0]) ? 2'b00 : 2'b11;
            wr_state      <= W_RESP;
          end else if (s_axil.awvalid) begin
            s_axil.awready <= 1'b0;
            wr_addr        <= s_axil.awaddr[ADDR_W-1:0];
            wr_state       <= W_DATA;
          end
        end

        W_DATA: begin
          if (s_axil.wvalid) begin
            s_axil.wready <= 1'b0;
            if (wr_addr[ADDR_W-1:2] < NUM_REGS[IDX_W:0]) begin
              for (int b = 0; b < 4; b++) begin
                if (s_axil.wstrb[b]) begin
                  regs[wr_addr[IDX_W+1:2]][b*8 +: 8] <=
                    (s_axil.wdata[b*8 +: 8] & ~REG_RO[wr_addr[IDX_W+1:2]][b*8 +: 8]) |
                    (regs[wr_addr[IDX_W+1:2]][b*8 +: 8] & REG_RO[wr_addr[IDX_W+1:2]][b*8 +: 8]);
                end
              end
              reg_wr[wr_addr[IDX_W+1:2]] <= 1'b1;
            end
            s_axil.bvalid <= 1'b1;
            s_axil.bresp  <= (wr_addr[ADDR_W-1:2] < NUM_REGS[IDX_W:0]) ? 2'b00 : 2'b11;
            wr_state      <= W_RESP;
          end
        end

        W_RESP: begin
          if (s_axil.bready) begin
            s_axil.bvalid  <= 1'b0;
            s_axil.awready <= 1'b1;
            s_axil.wready  <= 1'b1;
            wr_state       <= W_IDLE;
          end
        end

        default: wr_state <= W_IDLE;
      endcase
    end
  end

  // =========================================================================
  // Read channel
  // =========================================================================
  typedef enum logic [1:0] {
    R_IDLE,
    R_RESP
  } rd_state_t;

  rd_state_t rd_state;

  always_ff @(posedge s_axil.aclk) begin
    if (!s_axil.aresetn) begin
      rd_state       <= R_IDLE;
      s_axil.arready <= 1'b1;
      s_axil.rvalid  <= 1'b0;
      s_axil.rdata   <= '0;
      s_axil.rresp   <= 2'b00;
    end else begin
      case (rd_state)
        R_IDLE: begin
          if (s_axil.arvalid) begin
            s_axil.arready <= 1'b0;
            s_axil.rvalid  <= 1'b1;
            if (s_axil.araddr[ADDR_W-1:2] < NUM_REGS[IDX_W:0]) begin
              s_axil.rdata <= reg_in[s_axil.araddr[IDX_W+1:2]];
              s_axil.rresp <= 2'b00;
            end else begin
              s_axil.rdata <= 32'hDEADBEEF;
              s_axil.rresp <= 2'b11;
            end
            rd_state <= R_RESP;
          end
        end

        R_RESP: begin
          if (s_axil.rready) begin
            s_axil.rvalid  <= 1'b0;
            s_axil.arready <= 1'b1;
            rd_state       <= R_IDLE;
          end
        end

        default: rd_state <= R_IDLE;
      endcase
    end
  end

  // =========================================================================
  // Output register values
  // =========================================================================
  assign reg_out = regs;

endmodule: axil_reg_map

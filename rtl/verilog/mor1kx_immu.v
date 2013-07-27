/******************************************************************************
 This Source Code Form is subject to the terms of the
 Open Hardware Description License, v. 1.0. If a copy
 of the OHDL was not distributed with this file, You
 can obtain one at http://juliusbaxter.net/ohdl/ohdl.txt

 Description: Instruction MMU implementation

 Copyright (C) 2013 Stefan Kristiansson <stefan.kristiansson@saunalahti.fi>

 ******************************************************************************/

`include "mor1kx-defines.v"

module mor1kx_immu
  #(
    parameter FEATURE_IMMU_HW_TLB_RELOAD = "NONE",
    parameter OPTION_OPERAND_WIDTH = 32,
    parameter OPTION_IMMU_SET_WIDTH = 6,
    parameter OPTION_IMMU_WAYS = 1
    )
   (
    input 				  clk,
    input 				  rst,

    input 				  enable_i,

    input [OPTION_OPERAND_WIDTH-1:0] 	  virt_addr_i,
    input [OPTION_OPERAND_WIDTH-1:0] 	  virt_addr_match_i,
    output [OPTION_OPERAND_WIDTH-1:0] 	  phys_addr_o,
    output 				  cache_inhibit_o,

    input 				  supervisor_mode_i,

    output 				  tlb_miss_o,
    output 				  pagefault_o,

    output reg 				  tlb_reload_req_o,
    output 				  tlb_reload_busy_o,
    input 				  tlb_reload_ack_i,
    output reg [OPTION_OPERAND_WIDTH-1:0] tlb_reload_addr_o,
    input [OPTION_OPERAND_WIDTH-1:0] 	  tlb_reload_data_i,
    output				  tlb_reload_pagefault_o,
    input				  tlb_reload_pagefault_clear_i,

    // SPR interface
    input [15:0] 			  spr_bus_addr_i,
    input 				  spr_bus_we_i,
    input 				  spr_bus_stb_i,
    input [OPTION_OPERAND_WIDTH-1:0] 	  spr_bus_dat_i,

    output [OPTION_OPERAND_WIDTH-1:0] 	  spr_bus_dat_o,
    output 				  spr_bus_ack_o
    );

   wire [OPTION_OPERAND_WIDTH-1:0]    itlb_match_dout;
   wire [OPTION_IMMU_SET_WIDTH-1:0]   itlb_match_addr;
   reg 				      itlb_match_we;
   reg [OPTION_OPERAND_WIDTH-1:0]     itlb_match_din;

   wire [OPTION_OPERAND_WIDTH-1:0]    itlb_trans_dout;
   wire [OPTION_IMMU_SET_WIDTH-1:0]   itlb_trans_addr;
   reg 				      itlb_trans_we;
   reg [OPTION_OPERAND_WIDTH-1:0]     itlb_trans_din;

   wire [OPTION_IMMU_SET_WIDTH-1:0]   itlb_match_spr_addr;
   wire [OPTION_OPERAND_WIDTH-1:0]    itlb_match_spr_dout;
   wire [OPTION_OPERAND_WIDTH-1:0]    itlb_match_spr_din;
   wire 			      itlb_match_spr_we;

   wire [OPTION_IMMU_SET_WIDTH-1:0]   itlb_trans_spr_addr;
   wire [OPTION_OPERAND_WIDTH-1:0]    itlb_trans_spr_dout;
   wire [OPTION_OPERAND_WIDTH-1:0]    itlb_trans_spr_din;
   wire 			      itlb_trans_spr_we;

   wire 			      itlb_match_spr_cs;
   reg 				      itlb_match_spr_cs_r;
   wire 			      itlb_trans_spr_cs;
   reg 				      itlb_trans_spr_cs_r;

   wire 			      immucr_spr_cs;
   reg 				      immucr_spr_cs_r;
   reg [OPTION_OPERAND_WIDTH-1:0]     immucr;

   reg 				      tlb_reload_pagefault;

   // sxe: supervisor execute enable
   // uxe: user exexute enable
   wire 			      sxe;
   wire 			      uxe;

   reg 				      spr_bus_ack;

   always @(posedge clk `OR_ASYNC_RST)
     if (rst)
       spr_bus_ack <= 0;
     else if (spr_bus_stb_i & spr_bus_addr_i[15:11] == 5'd2)
       spr_bus_ack <= 1;
     else
       spr_bus_ack <= 0;

   assign spr_bus_ack_o = spr_bus_ack & spr_bus_stb_i &
			  spr_bus_addr_i[15:11] == 5'd2;

   assign cache_inhibit_o = itlb_trans_dout[1];
   assign sxe = itlb_trans_dout[6];
   assign uxe = itlb_trans_dout[7];

   assign pagefault_o = (supervisor_mode_i ? !sxe : !uxe) &
			!tlb_reload_busy_o;

   always @(posedge clk `OR_ASYNC_RST)
     if (rst) begin
	itlb_match_spr_cs_r <= 0;
	itlb_trans_spr_cs_r <= 0;
	immucr_spr_cs_r <= 0;
     end else begin
	itlb_match_spr_cs_r <= itlb_match_spr_cs;
	itlb_trans_spr_cs_r <= itlb_trans_spr_cs;
	immucr_spr_cs_r <= immucr_spr_cs;
     end

generate /* verilator lint_off WIDTH */
if (FEATURE_IMMU_HW_TLB_RELOAD == "ENABLED") begin
/* verilator lint_on WIDTH */
   assign immucr_spr_cs = spr_bus_stb_i &
			  spr_bus_addr_i == `OR1K_SPR_IMMUCR_ADDR;

   always @(posedge clk `OR_ASYNC_RST)
     if (rst)
       immucr <= 0;
     else if (immucr_spr_cs & spr_bus_we_i)
       immucr <= spr_bus_dat_i;

end else begin
   assign immucr_spr_cs = 0;
   always @(posedge clk)
     immucr <= 0;
end
endgenerate

   // TODO: optimize this
   assign itlb_match_spr_cs = spr_bus_stb_i &
			      (spr_bus_addr_i >= `OR1K_SPR_ITLBW0MR0_ADDR) &
			      (spr_bus_addr_i < `OR1K_SPR_ITLBW0TR0_ADDR);
   assign itlb_trans_spr_cs = spr_bus_stb_i &
			      (spr_bus_addr_i >= `OR1K_SPR_ITLBW0TR0_ADDR) &
			      (spr_bus_addr_i < `OR1K_SPR_ITLBW1MR0_ADDR);

   assign itlb_match_addr = virt_addr_i[13+(OPTION_IMMU_SET_WIDTH-1):13];
   assign itlb_trans_addr = virt_addr_i[13+(OPTION_IMMU_SET_WIDTH-1):13];

   assign itlb_match_spr_addr = spr_bus_addr_i[OPTION_IMMU_SET_WIDTH-1:0];
   assign itlb_trans_spr_addr = spr_bus_addr_i[OPTION_IMMU_SET_WIDTH-1:0];

   assign itlb_match_spr_we = itlb_match_spr_cs & spr_bus_we_i;
   assign itlb_trans_spr_we = itlb_trans_spr_cs & spr_bus_we_i;

   assign itlb_match_spr_din = spr_bus_dat_i;
   assign itlb_trans_spr_din = spr_bus_dat_i;

   assign spr_bus_dat_o = itlb_match_spr_cs_r ? itlb_match_spr_dout :
			  itlb_trans_spr_cs_r ? itlb_trans_spr_dout :
			  immucr_spr_cs_r ? immucr : 0;

   assign tlb_miss_o = (itlb_match_dout[31:13] != virt_addr_match_i[31:13] |
		       !itlb_match_dout[0]) & // valid bit
		       !tlb_reload_pagefault;

   assign phys_addr_o = {itlb_trans_dout[31:13], virt_addr_match_i[12:0]};

generate /* verilator lint_off WIDTH */
if (FEATURE_IMMU_HW_TLB_RELOAD == "ENABLED") begin
   /* verilator lint_on WIDTH */

   // Hardware TLB refill
   // Not exactly compliant with the spec, instead we follow
   // the PTE layout in Linux and translate that into the match
   // and translate registers.
   //
   // PTE layout in Linux:
   // | 31 ... 12 |  11  | 10 | 9 | 8 | 7 | 6 | 5 | 4 | 3 | 2 | 1 |   0   |
   // |    PPN    |SHARED|EXEC|SWE|SRE|UWE|URE| D | A |WOM|WBC| CI|PRESENT|

   localparam TLB_IDLE		 	= 2'd0;
   localparam TLB_GET_PTE_POINTER	= 2'd1;
   localparam TLB_GET_PTE		= 2'd2;
   localparam TLB_READ			= 2'd3;

   reg [1:0] tlb_reload_state = TLB_IDLE;
   wire      do_reload;

   assign do_reload = enable_i & tlb_miss_o & (immucr[31:10] != 0);
   assign tlb_reload_busy_o = (tlb_reload_state != TLB_IDLE) | do_reload;
   assign tlb_reload_pagefault_o = tlb_reload_pagefault &
				    !tlb_reload_pagefault_clear_i;

   always @(posedge clk) begin
      if (tlb_reload_pagefault_clear_i | rst)
	tlb_reload_pagefault <= 0;
      itlb_trans_we <= 0;
      itlb_trans_din <= 0;
      itlb_match_we <= 0;
      itlb_match_din <= 0;

      case (tlb_reload_state)
	TLB_IDLE: begin
	   tlb_reload_req_o <= 0;
	   if (do_reload) begin
	      tlb_reload_req_o <= 1;
	      tlb_reload_addr_o <= {immucr[31:10],
				    virt_addr_match_i[31:24], 2'b00};
	      tlb_reload_state <= TLB_GET_PTE_POINTER;
	   end
	end

	//
	// Here we get the pointer to the PTE table, next is to fetch
	// the actual pte from the offset in the table.
	// The offset is calculated by:
	// ((virt_addr_match >> PAGE_BITS) & (PTE_CNT-1)) << 2
	// Where PAGE_BITS is 13 (8 kb page) and PTE_CNT is 1024
	// (number of PTEs in the PTE table)
	//
	TLB_GET_PTE_POINTER: begin
	   if (tlb_reload_ack_i) begin
	      if (tlb_reload_data_i[31:13] == 0) begin
		 tlb_reload_pagefault <= 1;
		 tlb_reload_req_o <= 0;
		 tlb_reload_state <= TLB_IDLE;
	      end else begin
		 tlb_reload_addr_o <= {tlb_reload_data_i[31:13],
				       virt_addr_match_i[23:13], 2'b00};
		 tlb_reload_state <= TLB_GET_PTE;
	      end
	   end
	end

	//
	// Here we get the actual PTE, left to do is to translate the
	// PTE data into our translate and match registers.
	//
	TLB_GET_PTE: begin
	   if (tlb_reload_ack_i) begin
	      tlb_reload_req_o <= 0;
	      // Check PRESENT bit
	      if (!tlb_reload_data_i[0]) begin
		 tlb_reload_pagefault <= 1;
		 tlb_reload_state <= TLB_IDLE;
	      end else begin
		 // Translate register generation.
		 // PPN
		 itlb_trans_din[31:13] <= tlb_reload_data_i[31:13];
		 // If EXEC, SWE, SRE, UWE or URE are set,
		 // set UXE and SXE in the translate register.
		 // This is referred to as "itlb_tr_fill_workaround" in the
		 // kernel, were the exec flags are set on all pages with
		 // read or write rights.
		 // Sounds suspicious indeed, needs an overlook (both here
		 // and in the kernel)
		 if (|tlb_reload_data_i[10:6])
		   itlb_trans_din[7:6] <= 2'b11;
		 // Dirty, Accessed, Weakly-Ordered-Memory
		 itlb_trans_din[5:3] <= tlb_reload_data_i[5:3];
		 // Cache inhibit
		 itlb_trans_din[1] <= tlb_reload_data_i[1];
		 itlb_trans_we <= 1;

		 // Match register generation.
		 // VPN
		 itlb_match_din[31:13] <= virt_addr_match_i[31:13];
		 // Valid
		 itlb_match_din[0] <= 1;
		 itlb_match_we <= 1;

		 tlb_reload_state <= TLB_READ;
	      end
	   end
	end

	// Let the just written values propagate out on the read ports
	TLB_READ: begin
	   tlb_reload_state <= TLB_IDLE;
	end

	default:
	  tlb_reload_state <= TLB_IDLE;

      endcase
   end
end else begin // if (FEATURE_IMMU_HW_TLB_RELOAD == "ENABLED")
   assign tlb_reload_pagefault_o = 0;
   assign tlb_reload_busy_o = 0;
   always @(posedge clk) begin
      tlb_reload_req_o <= 0;
      tlb_reload_addr_o <= 0;
      tlb_reload_pagefault <= 0;
      itlb_trans_we <= 0;
      itlb_trans_din <= 0;
      itlb_match_we <= 0;
      itlb_match_din <= 0;
   end
end
endgenerate

   // ITLB match registers
   /* mor1kx_true_dpram_sclk AUTO_TEMPLATE (
      // Outputs
      .dout_a			(itlb_match_dout),
      .dout_b			(itlb_match_spr_dout),
      // Inputs
      .addr_a			(itlb_match_addr),
      .we_a			(itlb_match_we),
      .din_a			(itlb_match_din),
      .addr_b			(itlb_match_spr_addr),
      .we_b			(itlb_match_spr_we),
      .din_b			(itlb_match_spr_din),
    );
    */
   mor1kx_true_dpram_sclk
     #(
       .ADDR_WIDTH(OPTION_IMMU_SET_WIDTH),
       .DATA_WIDTH(OPTION_OPERAND_WIDTH)
       )
   itlb_match_regs
     (/*AUTOINST*/
      // Outputs
      .dout_a				(itlb_match_dout),	 // Templated
      .dout_b				(itlb_match_spr_dout),	 // Templated
      // Inputs
      .clk				(clk),
      .addr_a				(itlb_match_addr),	 // Templated
      .we_a				(itlb_match_we),	 // Templated
      .din_a				(itlb_match_din),	 // Templated
      .addr_b				(itlb_match_spr_addr),	 // Templated
      .we_b				(itlb_match_spr_we),	 // Templated
      .din_b				(itlb_match_spr_din));	 // Templated


   // ITLB translate registers
   /* mor1kx_true_dpram_sclk AUTO_TEMPLATE (
      // Outputs
      .dout_a			(itlb_trans_dout),
      .dout_b			(itlb_trans_spr_dout),
      // Inputs
      .addr_a			(itlb_trans_addr),
      .we_a			(itlb_trans_we),
      .din_a			(itlb_trans_din),
      .addr_b			(itlb_trans_spr_addr),
      .we_b			(itlb_trans_spr_we),
      .din_b			(itlb_trans_spr_din),
    );
    */
   mor1kx_true_dpram_sclk
     #(
       .ADDR_WIDTH(OPTION_IMMU_SET_WIDTH),
       .DATA_WIDTH(OPTION_OPERAND_WIDTH)
       )
   itlb_translate_regs
     (/*AUTOINST*/
      // Outputs
      .dout_a				(itlb_trans_dout),	 // Templated
      .dout_b				(itlb_trans_spr_dout),	 // Templated
      // Inputs
      .clk				(clk),
      .addr_a				(itlb_trans_addr),	 // Templated
      .we_a				(itlb_trans_we),	 // Templated
      .din_a				(itlb_trans_din),	 // Templated
      .addr_b				(itlb_trans_spr_addr),	 // Templated
      .we_b				(itlb_trans_spr_we),	 // Templated
      .din_b				(itlb_trans_spr_din));	 // Templated

endmodule

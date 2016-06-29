`timescale 1ns / 1ps 
`include "sd_defines.h"
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/24/2016 01:37:27 AM
// Design Name: 
// Module Name: sd_emmc_controller_dma
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module  sd_emmc_controller_dma (
            input  wire clock,
            input  wire reset,

            // S_AXI
//            input  wire [31:0] init_dma_sys_addr,
//            input  wire [2:0] buf_boundary,
            input  wire [`BLKCNT_W -1:0] block_count,
//            input  wire sys_addr_changed,
            input wire dma_ena_trans_mode,
            input wire dir_dat_trans_mode,
//            input wire blk_count_ena,
//            input wire [11:0] blk_size,
            output reg [1:0] dma_interrupts,
            input wire dat_int_rst,
            input wire cmd_int_rst_pulse,
            input wire data_present,
            input wire [31:0] descriptor_pointer_i,
            input wire blk_gap_req,

            // Data serial
            (* mark_debug = "true" *)input wire xfer_compl,
            input wire is_we_en,
            input wire is_rd_en, 
            (* mark_debug = "true" *)output reg start_write,
//            input wire trans_block_compl,
//            input wire ser_next_blk,
            input wire [1:0] write_timeout,
            
            // Command master
            input wire cmd_compl_puls,
            
            // FIFO Filler
            output reg fifo_dat_rd_ready,
            output wire fifo_dat_wr_ready_o,
            input wire [31:0] read_fifo_data,
            (* mark_debug = "true" *)output reg fifo_rst,

            // M_AXI
            output reg m_axi_wvalid,
            input wire m_axi_wready,
            output wire [31:0] m_axi_awaddr,
            output reg m_axi_awvalid,
            input wire m_axi_awready,
            output wire w_last,
            output wire [31:0] axi_araddr,
            output reg axi_arvalid,
            input wire axi_arready,
            input wire axi_rvalid,
            output wire axi_rready,
            input wire axi_rlast,
            input wire [31:0] m_axi_rdata,
            output wire [7:0] m_axi_arlen,
            output wire [2:0] m_axi_arsize,
            output wire [1:0] m_axi_arburst,
            output wire [1:0] m_axi_awburst,
            output wire [7:0] m_axi_awlen,
            output wire [2:0] m_axi_awsize,
            output wire [31:0] m_axi_wdata,
            output wire [0:0] m_axi_aruser,
            input wire [0:0] m_axi_rid,
            input wire [1:0] m_axi_rresp,
            input wire [0:0] m_axi_ruser
        );

(* mark_debug = "true" *) reg [3:0] state;
(* mark_debug = "true" *) reg [16:0] data_cycle;
reg [16:0] we_counter;
reg [16:0] rd_counter;
reg init_we_ff;
reg init_we_ff2;
reg init_rd_ff;
reg init_rd_ff2;
reg init_rready;
reg init_rready2;
reg init_rvalid;
(* mark_debug = "true" *) reg addr_accepted;
reg we_counter_reset;
reg rd_counter_reset;
wire we_pulse;
wire rd_pulse;
reg data_write_disable;
(* mark_debug = "true" *) reg [2:0] adma_state;
reg sys_addr_sel;
reg [31:0] descriptor_pointer_reg;
reg [63:0] descriptor_line;
reg [11:0] sdma_contr_reg;
reg fifo_dat_wr_ready_reg;
reg [3:0] write_index;
reg axi_wlast;
reg burst_tx;
wire stop_trans;
wire next_data_word;

parameter IDLE                = 4'b0000;
parameter READ_SYSRAM         = 4'b0001;
parameter READ_WAIT           = 4'b0010;
parameter READ_ACT            = 4'b0011;

parameter [2:0] ST_STOP = 3'b000, //State Stop DMA. ADMA2 stays in this state in following cases:
                                  // (1) After Power on reset or software reset.
                                  // (2) All descriptor data transfers are completed.
                                  //If a new ADMA2 operation is started by writing Command register, go to ST_FDS state. 
                ST_FDS  = 3'b001, //State Fetch Descriptor. In this state ADMA2 fetches a descriptor line 
                                  //and set parameters in internal registers.
                ST_CADR = 3'b010, //State Change Address. In this state Link operation loads another Descriptor address
                                  //to ADMA System Address register.
                ST_TFR  = 3'b011; //State Transfer Data. In this state data transfer of one descriptor line is executed 
                                  //between system memory and SD card.
                
  assign m_axi_arsize	     = 3'b010;
  assign m_axi_arburst       = 2'b01;
  assign m_axi_awburst       = 2'b01;
  assign m_axi_awlen	     = sdma_contr_reg[`BurstLen];
  assign m_axi_awsize	     = 3'b010;
  assign stop_trans          = state == IDLE ? 1'b1 : 1'b0;
  assign fifo_dat_wr_ready_o = sdma_contr_reg[`DatTarg] ? 1'b0 : fifo_dat_wr_ready_reg;
  assign axi_araddr          = sdma_contr_reg[`AddrSel] ? descriptor_pointer_reg : descriptor_line [63:32];
  assign m_axi_arlen         = sdma_contr_reg[`BurstLen];
  assign Tran = (descriptor_line[5:4] == 2'b10) ? 1'b1 : 1'b0;
  assign Link = (descriptor_line[5:4] == 2'b11) ? 1'b1 : 1'b0;
  assign next_data_word = m_axi_wready & m_axi_wvalid;
  assign w_last = axi_wlast;
  assign m_axi_awaddr = descriptor_line [63:32];
  assign m_axi_wdata  = read_fifo_data;
  assign m_axi_aruser = 'b0;


    always @(posedge clock)
    begin: WRITE_DATA_BEAT_COUNTER
      if (reset == 1'b0 || burst_tx == 1'b1) begin
        write_index <= 0;
      end
      else if (next_data_word && (write_index != sdma_contr_reg[`BurstLen])) begin
        write_index <= write_index + 1;
      end
      else
        write_index <= write_index;
    end

	always @(posedge clock)
	begin: WLAST_GENERATION
	  if (reset == 1'b0 || burst_tx == 1'b1) begin
	    axi_wlast <= 1'b0;
	  end
	  else if (((write_index == sdma_contr_reg[`BurstLen] -1 && sdma_contr_reg[`BurstLen] >= 2) && next_data_word) || (sdma_contr_reg[`BurstLen] == 1 )) begin
	    axi_wlast <= 1'b1;
	  end
	  else if (next_data_word)
	    axi_wlast <= 1'b0;
	  else if (axi_wlast && sdma_contr_reg[`BurstLen] == 1)
	    axi_wlast <= 1'b0;
	  else
	    axi_wlast <= axi_wlast;
	end


    /*
    *  SDMA
    */
    always @(posedge clock)
    begin: STATE_TRANSITION
      if (reset == 1'b0) begin
        state <= IDLE;
        m_axi_awvalid <= 0;
        m_axi_wvalid <= 0;
        data_cycle <= 0;
        fifo_dat_rd_ready <= 0;
        fifo_dat_wr_ready_reg <= 0;
        addr_accepted <= 0;
        axi_arvalid <= 0;
        fifo_rst <= 0;
        descriptor_line <= 0;
      end
      else begin
        case (state)
          IDLE: begin
                   data_cycle <= 0;
                   fifo_dat_rd_ready <= 0;
                   fifo_dat_wr_ready_reg <= 0;
                   data_write_disable <= 0;
                   we_counter_reset <= 1;
                   rd_counter_reset <= 1;
                  if (sdma_contr_reg[`DatTransDir] == 2'b01) begin
                    state <= READ_WAIT;
                    fifo_rst <= 1;
                  end
                  else if (sdma_contr_reg[`DatTransDir] == 2'b10) begin
                    state <= READ_SYSRAM;
                    fifo_rst <= 1;
                  end
                  else begin
                    state <= IDLE;
                    burst_tx <= 1'b1;
                    start_write <= 1'b0;
                  end
                end
          READ_WAIT: begin
                       fifo_rst <= 0;
                       fifo_dat_rd_ready <= 1'b0;
                       if (we_counter >= (data_cycle + 16)) begin
                         state <= READ_ACT;
                       end
                       else begin
                         state <= READ_WAIT;
                       end 
                       if (data_cycle >= (rd_dat_words/4)) begin
                         data_cycle <= 0;
                         we_counter_reset <= 1'b0;
                         state <= IDLE;
                       end
                     end
          READ_ACT: begin
                      we_counter_reset <= 1'b1;
                      case (addr_accepted)
                          1'b0: begin 
                                  if (m_axi_awvalid && m_axi_awready) begin
                                    m_axi_awvalid <= 1'b0;
                                    addr_accepted <= 1'b1;
//                                    write_addr <= write_addr + 64;
                                    descriptor_line [63:32] <= descriptor_line [63:32] + 64;
//                                    m_axi_wvalid <= 1'b0;
                                    burst_tx <= 1'b0;
                                  end
                                  else begin
                                    m_axi_awvalid <= 1'b1;
                                  end
                                end
                          1'b1: begin
                                  if (next_data_word) begin
                                    data_cycle <= data_cycle + 1;
                                    fifo_dat_rd_ready <= 1'b1;
                                    m_axi_wvalid <= 1'b0;
                                    data_write_disable <= 1'b1;
                                  end
                                  else if (data_write_disable) begin
                                    fifo_dat_rd_ready <= 1'b0;
                                    m_axi_wvalid <= 1'b0;
                                    data_write_disable <= 1'b0;
                                  end
                                  else begin
                                    m_axi_wvalid <= 1'b1;
                                  end
                                  if (w_last & m_axi_wvalid) begin
                                    state <= READ_WAIT;
                                    m_axi_wvalid <= 1'b0;
                                    addr_accepted <= 1'b0;
                                    fifo_dat_rd_ready <= 1'b1;
                                    data_write_disable <= 1'b0;
                                    burst_tx <= 1'b1;
                                  end
                                end
                      endcase 
                    end
          READ_SYSRAM: begin
                          fifo_rst <= 0;
                          case (addr_accepted)
                            1'b0: begin
                              if (data_cycle >= (rd_dat_words / 4)) begin
                                data_cycle <= 0;
                                state <= IDLE;
                              end
                              else begin
                                if (axi_arvalid & axi_arready) begin
                                  axi_arvalid <= 1'b0;
                                  addr_accepted <= 1'b1;
                                  start_write <= 1'b1;
                                  if (~sdma_contr_reg[`AddrSel])
                                    descriptor_line [63:32] <= descriptor_line [63:32] + 64;
                                end
                                else begin
                                  axi_arvalid <= 1'b1;
                                end
                              end
                            end
                            1'b1: begin  //The burst read active
                              if (axi_rvalid && ~fifo_dat_wr_ready_reg) begin
                                fifo_dat_wr_ready_reg <= 1'b1;
                                if (axi_rready) begin
                                  data_cycle <= data_cycle + 1;
                                end
                              end
                              else if (fifo_dat_wr_ready_reg) begin
                                fifo_dat_wr_ready_reg <= 1'b0;
                                if (sdma_contr_reg[`DatTarg]) begin
                                  descriptor_line <= {m_axi_rdata, descriptor_line[63:32]};
                                end

                                if (axi_rlast) begin
                                 addr_accepted <= 1'b0;  //The burst read stopped
                                 data_cycle <= data_cycle + 1;
                                end
                              end
                            end
                          endcase
                        end
        endcase
        // abort the state when timeout on data serializer
        if (write_timeout == 2'b11) begin
          state <= IDLE;
          start_write <= 0;
        end
      end
    end
    
    assign axi_rready = (!init_rready2) && init_rready;

    always @ (posedge clock)
      begin: AXI_RREADY_PULSE_GENERATOR
        if (reset == 1'b0) begin
          init_rready <= 1'b0;
          init_rready2 <= 1'b0;
        end
        else begin
          init_rready <= fifo_dat_wr_ready_reg;
          init_rready2 <= init_rready;
        end
      end

    always @ (posedge clock)
      begin: NUMBER_OF_FIFO_WRITING_COUNTER
        if ((reset == 1'b0) || (we_counter_reset == 1'b0)) begin
          we_counter <= 0;
        end
        else begin
          if (we_pulse)
              we_counter <= we_counter + 16'h0001;
        end
      end

//	assign we_pulse	= (!init_we_ff2) && init_we_ff;
	assign we_pulse	= init_we_ff2 && (!init_we_ff);
	
    always @ (posedge clock)
      begin: WE_PULS_GENERATOR
        if (reset == 1'b0) begin
          init_we_ff <= 1'b0;
          init_we_ff2 <= 1'b0;
        end
        else begin
          init_we_ff <= is_we_en;
          init_we_ff2 <= init_we_ff;
        end
      end
    
    assign rd_pulse = (!init_rd_ff2) && init_rd_ff;

    always @ (posedge clock)
      begin: RD_PULS_GENERATOR
        if (reset == 1'b0) begin
          init_rd_ff <= 1'b0;
          init_rd_ff2 <= 1'b0;
        end
        else begin
          init_rd_ff <= is_rd_en;
          init_rd_ff2 <= init_rd_ff;
        end
      end

    always @ (posedge clock)
      begin: NUMBER_OF_FIFO_READING_COUNTER
        if (reset == 1'b0 || rd_counter_reset == 1'b0) begin
          rd_counter <= 0;
        end
        else begin
          if (rd_pulse)
            rd_counter <= rd_counter + 16'h0001;
        end
      end
      
      /* 
      *   ADMA
      */
      
      // READ_WAIT = dir_dat_trans_mode & dma_ena_trans_mode & !xfer_compl
      // READ_SYSRAM = !dir_dat_trans_mode & dma_ena_trans_mode & !xfer_compl & cmd_int_rst_pulse
      reg [1:0] start_dat_trans;
      reg [2:0] next_state;
      reg [16:0] rd_dat_words;
      reg TFC;
      reg a;
      reg trans_act;
      reg next_trans_act;
      wire Tran;
      wire Link;
      
    always @ (posedge clock)
      begin: adma
        if(reset == 1'b0) begin
          start_dat_trans <= 0;
          sys_addr_sel <= 0;
          descriptor_pointer_reg <= 0;
          dma_interrupts <= 0;
          rd_dat_words <= 0;
          TFC <= 0;
          sdma_contr_reg <= 0;
          a <= 0;
        end
        else begin
          case (adma_state)
            ST_STOP: begin
                       if (dma_ena_trans_mode & cmd_compl_puls & data_present) begin
                         next_state <= ST_FDS;
                         sdma_contr_reg <= 12'h01E; //Read from SysRam, read to descriptor line, read from adma_descriptor_pointer addres, read two beats in burst, start read. 
                         rd_dat_words <= 17'h00008;
                         descriptor_pointer_reg <= descriptor_pointer_i;
                       end
                       else begin
                         TFC <= 0;
                       end
                     end
            ST_FDS: begin
                      sdma_contr_reg[`DatTransDir] <= 0; // Reset start transferring command
                      TFC <= 1'b0;
                      next_trans_act <= 1'b0;
                      a <= 1'b1;
//                      rd_dat_words <= 17'h00008;
                      if (stop_trans) begin
                        if (descriptor_line[`valid] == 1) begin
                          next_state <= ST_CADR;
                        end
                        else begin
                          dma_interrupts[1] <= 1'b1;
                          next_state <= ST_STOP;
                        end
                      end
                    end
            ST_CADR: begin
                       a <= 1'b0;
                       if (Tran) begin
                         next_state <= ST_TFR;
                       end
                       else begin
                         if (descriptor_line[`End] && !Tran && xfer_compl) begin
                           next_state <= ST_STOP;
                           dma_interrupts[0] <= 1'b1;
                         end
                         else if (~descriptor_line[`End] && !Tran) begin
                           next_state <= ST_FDS;
                           sdma_contr_reg <= 12'h01E;
                         end
                       end
                       if (Link)
                         descriptor_pointer_reg <= descriptor_line[63:32];
                       else if (a)
                         descriptor_pointer_reg <= descriptor_pointer_reg + 32'h00000008;
                     end
            ST_TFR: begin
                      if (TFC && xfer_compl && (descriptor_line[`End] || blk_gap_req)) begin
                        next_state <= ST_STOP;
                        dma_interrupts[0] <= 1'b1;
                      end
                      else if (TFC && ~descriptor_line[`End] && !blk_gap_req) begin
                        next_state <= ST_FDS;
                        sdma_contr_reg <= 12'h01E;
                        rd_dat_words <= 17'h00008;
                      end
                      else begin
                        case (trans_act)
                          1'b0: begin
                                  if (dir_dat_trans_mode) begin
                                    sdma_contr_reg <= 12'h0F1;
                                  end
                                  else begin
                                    sdma_contr_reg <= 12'h0F2;
                                  end
                                  next_trans_act <= 1'b1;
                                end
                          1'b1: begin
                                  if (stop_trans) begin
                                    TFC <= 1'b1;
                                  end
                                  else begin
                                  end
                                  sdma_contr_reg[`DatTransDir] <= 0; // Reset start transferring command
                                end
                        endcase
                        if (descriptor_line[31:16] == 16'h0000)
                          rd_dat_words <= 17'h10000;
                        else
                          rd_dat_words <= descriptor_line[31:16];
                      end
                    end
          endcase
          if (dat_int_rst)
            dma_interrupts <= 0;
        end
      end  
      
      always @(posedge clock)
      begin: FSM_SEQ
        if (reset == 1'b0) begin
          adma_state <= ST_STOP;
          trans_act <= 0;
        end
        else begin
          trans_act <= next_trans_act;
          adma_state <= next_state;
        end
      end


endmodule

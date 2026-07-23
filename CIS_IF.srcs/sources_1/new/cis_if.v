`timescale 1ns / 1ps

module cis_if #(
    parameter integer CIS_CYCLES   = 20400,
    parameter integer SAMP_PER_CIS = 20,
    parameter integer TOTAL_SAMP   = CIS_CYCLES * SAMP_PER_CIS  // 408000
)(
    input  wire        clk_in,          // 50 MHz
    input  wire        rst_n,

    // sensor / ADC
    output wire        clk_cis,         // 1.25 MHz
    output wire [1:0]  clk_ad9203,      // 25 MHz
    output wire        trg_cis,
    input  wire [19:0] data_ad9203,

    output wire [2:0]  led,

    // control from PS (AXI-Lite, clk_in domain)
    input  wire        arm,             // level, held high while armed
    input  wire        soft_trig,       // level; write 1 then 0
    output wire        busy,
    output wire        done,

    // AXI4-Stream master -> async FIFO -> AXI DMA
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_aclk      // 25 MHz, drives FIFO write side
);

    // ---------------- Clock generation ----------------
    // Raw dividers, then BUFG onto global clock networks.
    reg clk25_raw = 1'b0;
    always @(posedge clk_in) begin
        if (!rst_n) clk25_raw <= 1'b0;
        else        clk25_raw <= ~clk25_raw;
    end

    reg [4:0] div_cnt     = 5'd0;
    reg       clk1_25_raw = 1'b0;
    always @(posedge clk_in) begin
        if (!rst_n) begin
            div_cnt     <= 5'd0;
            clk1_25_raw <= 1'b0;
        end else if (div_cnt == 5'd19) begin
            div_cnt     <= 5'd0;
            clk1_25_raw <= ~clk1_25_raw;
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
    end

    wire clk25, clk1_25;
    BUFG bufg_clk25   (.I(clk25_raw),   .O(clk25));
    BUFG bufg_clk1_25 (.I(clk1_25_raw), .O(clk1_25));

    assign clk_cis      = clk1_25;
    assign clk_ad9203   = {clk25, clk25};
    assign m_axis_aclk  = clk25;

    // ---------------- Trigger into clk_cis domain ----------------
    reg  trig_req = 1'b0;
    reg  ack_s1 = 1'b0, ack_s2 = 1'b0;
    wire trg_ack;

    always @(posedge clk_in) begin
        if (!rst_n) begin
            trig_req <= 1'b0;
            ack_s1   <= 1'b0;
            ack_s2   <= 1'b0;
        end else begin
            ack_s1 <= trg_ack;
            ack_s2 <= ack_s1;
            if (soft_trig && arm) trig_req <= 1'b1;
            else if (ack_s2)      trig_req <= 1'b0;
        end
    end

    reg req_s1 = 1'b0, req_s2 = 1'b0;
    always @(posedge clk1_25) begin
        req_s1 <= trig_req;
        req_s2 <= req_s1;
    end

    // ---------------- 16-cycle trg_cis pulse ----------------
    reg       trg_active = 1'b0;
    reg [4:0] pulse_cnt  = 5'd0;
    reg       ack_r      = 1'b0;

    always @(posedge clk1_25) begin
        if (!trg_active) begin
            ack_r <= 1'b0;
            if (req_s2) begin
                trg_active <= 1'b1;
                pulse_cnt  <= 5'd0;
                ack_r      <= 1'b1;
            end
        end else begin
            if (pulse_cnt == 5'd15) begin
                trg_active <= 1'b0;
                pulse_cnt  <= 5'd0;
            end else begin
                pulse_cnt <= pulse_cnt + 1'b1;
            end
        end
    end

    assign trg_cis = trg_active;
    assign trg_ack = ack_r;

    // ---------------- Capture FSM in 25 MHz domain ----------------
    reg tc_s1 = 1'b0, tc_s2 = 1'b0, tc_s3 = 1'b0;
    always @(posedge clk25) begin
        tc_s1 <= trg_cis;
        tc_s2 <= tc_s1;
        tc_s3 <= tc_s2;
    end
    wire trg_fall = tc_s3 & ~tc_s2;      // falling edge of trg_cis

    reg [19:0] adc_reg   = 20'd0;
    reg [18:0] samp_cnt  = 19'd0;        // 408000 needs 19 bits
    reg        capturing = 1'b0;
    reg        done_r    = 1'b0;

    always @(posedge clk25) begin
        adc_reg <= data_ad9203;

        if (!rst_n) begin
            capturing <= 1'b0;
            samp_cnt  <= 19'd0;
            done_r    <= 1'b0;
        end else if (!capturing) begin
            if (trg_fall) begin
                capturing <= 1'b1;
                samp_cnt  <= 19'd0;
                done_r    <= 1'b0;
            end
        end else if (m_axis_tready) begin
            if (samp_cnt == TOTAL_SAMP-1) begin
                capturing <= 1'b0;
                samp_cnt  <= 19'd0;
                done_r    <= 1'b1;
            end else begin
                samp_cnt <= samp_cnt + 1'b1;
            end
        end
    end

    assign m_axis_tdata  = {12'd0, adc_reg};
    assign m_axis_tvalid = capturing;
    assign m_axis_tlast  = capturing && (samp_cnt == TOTAL_SAMP-1);

    assign busy = capturing;
    assign done = done_r;

    assign led = {done_r, capturing, 1'b1};

endmodule
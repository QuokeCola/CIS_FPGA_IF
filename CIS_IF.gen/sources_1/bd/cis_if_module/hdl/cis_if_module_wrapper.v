//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2026.1 (win64) Build 6511674 Tue Jun 16 11:02:23 MDT 2026
//Date        : Tue Jul 21 16:54:47 2026
//Host        : Chen-XPS running 64-bit major release  (build 9200)
//Command     : generate_target cis_if_module_wrapper.bd
//Design      : cis_if_module_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module cis_if_module_wrapper
   (MDIO_PHY_0_mdc,
    MDIO_PHY_0_mdio_io,
    RGMII_0_rd,
    RGMII_0_rx_ctl,
    RGMII_0_rxc,
    RGMII_0_td,
    RGMII_0_tx_ctl,
    RGMII_0_txc,
    UART_0_0_rxd,
    UART_0_0_txd,
    clk_ad9203_0,
    clk_cis_0,
    data_ad9203_0,
    led_0,
    trg_cis_0);
  output MDIO_PHY_0_mdc;
  inout MDIO_PHY_0_mdio_io;
  input [3:0]RGMII_0_rd;
  input RGMII_0_rx_ctl;
  input RGMII_0_rxc;
  output [3:0]RGMII_0_td;
  output RGMII_0_tx_ctl;
  output RGMII_0_txc;
  input UART_0_0_rxd;
  output UART_0_0_txd;
  output [1:0]clk_ad9203_0;
  output clk_cis_0;
  input [19:0]data_ad9203_0;
  output [2:0]led_0;
  output trg_cis_0;

  wire MDIO_PHY_0_mdc;
  wire MDIO_PHY_0_mdio_i;
  wire MDIO_PHY_0_mdio_io;
  wire MDIO_PHY_0_mdio_o;
  wire MDIO_PHY_0_mdio_t;
  wire [3:0]RGMII_0_rd;
  wire RGMII_0_rx_ctl;
  wire RGMII_0_rxc;
  wire [3:0]RGMII_0_td;
  wire RGMII_0_tx_ctl;
  wire RGMII_0_txc;
  wire UART_0_0_rxd;
  wire UART_0_0_txd;
  wire [1:0]clk_ad9203_0;
  wire clk_cis_0;
  wire [19:0]data_ad9203_0;
  wire [2:0]led_0;
  wire trg_cis_0;

  IOBUF MDIO_PHY_0_mdio_iobuf
       (.I(MDIO_PHY_0_mdio_o),
        .IO(MDIO_PHY_0_mdio_io),
        .O(MDIO_PHY_0_mdio_i),
        .T(MDIO_PHY_0_mdio_t));
  cis_if_module cis_if_module_i
       (.MDIO_PHY_0_mdc(MDIO_PHY_0_mdc),
        .MDIO_PHY_0_mdio_i(MDIO_PHY_0_mdio_i),
        .MDIO_PHY_0_mdio_o(MDIO_PHY_0_mdio_o),
        .MDIO_PHY_0_mdio_t(MDIO_PHY_0_mdio_t),
        .RGMII_0_rd(RGMII_0_rd),
        .RGMII_0_rx_ctl(RGMII_0_rx_ctl),
        .RGMII_0_rxc(RGMII_0_rxc),
        .RGMII_0_td(RGMII_0_td),
        .RGMII_0_tx_ctl(RGMII_0_tx_ctl),
        .RGMII_0_txc(RGMII_0_txc),
        .UART_0_0_rxd(UART_0_0_rxd),
        .UART_0_0_txd(UART_0_0_txd),
        .clk_ad9203_0(clk_ad9203_0),
        .clk_cis_0(clk_cis_0),
        .data_ad9203_0(data_ad9203_0),
        .led_0(led_0),
        .trg_cis_0(trg_cis_0));
endmodule

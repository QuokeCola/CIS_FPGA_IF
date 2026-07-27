#include <stdio.h>
#include <string.h>
#include "xparameters.h"
#include "xaxidma.h"
#include "xgpio.h"
#include "xil_cache.h"
#include "xil_printf.h"

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "netif/xadapter.h"
#include "xiltimer.h"

/* Required by lwIP now that NO_SYS_NO_TIMERS is disabled (see lwipopts.h) */
u32_t sys_now(void)
{
    XTime now;
    XTime_GetTime(&now);
    return (u32_t)((now * 1000ULL) / COUNTS_PER_SECOND);
}

/* ---------------- capture geometry ---------------- */
#define TOTAL_SAMP      408000
#define CAPTURE_BYTES   (TOTAL_SAMP * 4)

#define TCP_PORT        5001

/* ---------------- GPIO ---------------- */
#define GPIO_CH_CTRL    1
#define GPIO_CH_STAT    2
#define CTRL_ARM        0x1
#define CTRL_TRIG       0x2

static XAxiDma Dma;
static XGpio   Gpio;

static u8 capture_buf[CAPTURE_BYTES] __attribute__((aligned(64)));

/* ---------------- hardware ---------------- */
static int hw_init(void)
{
    XAxiDma_Config *dcfg = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_BASEADDR);
    if (!dcfg) { xil_printf("no DMA config\r\n"); return XST_FAILURE; }
    if (XAxiDma_CfgInitialize(&Dma, dcfg) != XST_SUCCESS) return XST_FAILURE;
    if (XAxiDma_HasSg(&Dma)) { xil_printf("DMA is SG!\r\n"); return XST_FAILURE; }

    XAxiDma_IntrDisable(&Dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&Dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    if (XGpio_Initialize(&Gpio, XPAR_AXI_GPIO_0_BASEADDR) != XST_SUCCESS) {
        xil_printf("gpio init failed\r\n"); return XST_FAILURE;
    }
    XGpio_SetDataDirection(&Gpio, GPIO_CH_CTRL, 0x0);
    XGpio_SetDataDirection(&Gpio, GPIO_CH_STAT, 0x3);
    XGpio_DiscreteWrite(&Gpio, GPIO_CH_CTRL, 0x0);

    return XST_SUCCESS;
}

static int do_capture(void)
{
    u32 t0 = sys_now();

    Xil_DCacheInvalidateRange((UINTPTR)capture_buf, CAPTURE_BYTES);

    if (XAxiDma_SimpleTransfer(&Dma, (UINTPTR)capture_buf,
            CAPTURE_BYTES, XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS) {
        xil_printf("DMA start failed\r\n");
        return XST_FAILURE;
    }

    XGpio_DiscreteWrite(&Gpio, GPIO_CH_CTRL, CTRL_ARM);
    XGpio_DiscreteWrite(&Gpio, GPIO_CH_CTRL, CTRL_ARM | CTRL_TRIG);
    XGpio_DiscreteWrite(&Gpio, GPIO_CH_CTRL, CTRL_ARM);

    volatile u32 spin = 0;
    while (XAxiDma_Busy(&Dma, XAXIDMA_DEVICE_TO_DMA)) {
        if (++spin > 300000000u) {
            u32 sr = XAxiDma_ReadReg(Dma.RegBase + XAXIDMA_RX_OFFSET,
                                     XAXIDMA_SR_OFFSET);
            xil_printf("TIMEOUT dma_sr=0x%08x gpio=0x%x\r\n",
                       (unsigned)sr,
                       (unsigned)XGpio_DiscreteRead(&Gpio, GPIO_CH_STAT));
            XGpio_DiscreteWrite(&Gpio, GPIO_CH_CTRL, 0x0);
            return XST_FAILURE;
        }
    }
    XGpio_DiscreteWrite(&Gpio, GPIO_CH_CTRL, 0x0);

    Xil_DCacheInvalidateRange((UINTPTR)capture_buf, CAPTURE_BYTES);

    xil_printf("capture: %u ms\r\n", (unsigned)(sys_now() - t0));
    return XST_SUCCESS;
}

/* ---------------- TCP server ---------------- */
static u32 send_offset;
static int sending;
static u32 send_t0;

static void try_send(struct tcp_pcb *tpcb)
{
    while (sending && send_offset < CAPTURE_BYTES) {
        u32 remaining = CAPTURE_BYTES - send_offset;
        u16 space = tcp_sndbuf(tpcb);
        if (space == 0) break;

        u32 chunk = (remaining < space) ? remaining : space;

        err_t e = tcp_write(tpcb, capture_buf + send_offset, (u16)chunk,
                            TCP_WRITE_FLAG_COPY);
        if (e != ERR_OK) break;
        send_offset += chunk;
    }
    tcp_output(tpcb);

    if (send_offset >= CAPTURE_BYTES && sending) {
        sending = 0;
        xil_printf("sent %u bytes in %u ms\r\n",
                   (unsigned)CAPTURE_BYTES, (unsigned)(sys_now() - send_t0));
    }
}

static err_t on_sent(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    (void)arg; (void)len;
    try_send(tpcb);
    return ERR_OK;
}

static err_t on_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
    (void)arg;
    if (!p) { tcp_close(tpcb); return ERR_OK; }
    if (err != ERR_OK) { pbuf_free(p); return err; }

    tcp_recved(tpcb, p->tot_len);

    int is_start = (p->len >= 5 && memcmp(p->payload, "START", 5) == 0);
    pbuf_free(p);

    if (is_start) {
        xil_printf("capture requested\r\n");
        if (do_capture() == XST_SUCCESS) {
            send_offset = 0;
            sending = 1;
            send_t0 = sys_now();
            try_send(tpcb);
        } else {
            tcp_write(tpcb, "ERR\n", 4, TCP_WRITE_FLAG_COPY);
            tcp_output(tpcb);
        }
    }
    return ERR_OK;
}

static err_t on_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg; (void)err;
    tcp_recv(newpcb, on_recv);
    tcp_sent(newpcb, on_sent);
    tcp_nagle_disable(newpcb);
    xil_printf("client connected\r\n");
    return ERR_OK;
}

/* ---------------- main ---------------- */
int main(void)
{
    static struct netif server_netif;
    struct netif *netif = &server_netif;

    ip_addr_t ipaddr, netmask, gw;
    unsigned char mac[6] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};

    Xil_DCacheEnable();
    Xil_ICacheEnable();

    xil_printf("\r\n=== CIS capture server ===\r\n");
    xil_printf("buf @ 0x%08x  %u bytes\r\n",
               (unsigned)(UINTPTR)capture_buf, (unsigned)CAPTURE_BYTES);

    if (hw_init() != XST_SUCCESS) { xil_printf("INIT FAILED\r\n"); return -1; }
    xil_printf("hw ok. gpio_stat=0x%x\r\n",
               (unsigned)XGpio_DiscreteRead(&Gpio, GPIO_CH_STAT));

    IP4_ADDR(&ipaddr,  192, 168, 1, 10);
    IP4_ADDR(&netmask, 255, 255, 255, 0);
    IP4_ADDR(&gw,      192, 168, 1, 1);

    lwip_init();

    if (!xemac_add(netif, &ipaddr, &netmask, &gw, mac,
                   XPAR_XEMACPS_0_BASEADDR)) {
        xil_printf("xemac_add failed\r\n");
        return -1;
    }
    netif_set_default(netif);
    netif_set_up(netif);

    xil_printf("IP 192.168.1.10, listening on port %d\r\n", TCP_PORT);

    struct tcp_pcb *pcb = tcp_new();
    tcp_bind(pcb, IP_ANY_TYPE, TCP_PORT);
    pcb = tcp_listen(pcb);
    tcp_accept(pcb, on_accept);

    while (1) {
        xemacif_input(netif);
        sys_check_timeouts();
    }
    return 0;
}
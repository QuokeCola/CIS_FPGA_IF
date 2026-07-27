"""CIS Scanner App: record/stop a line-scan capture into a growing 2D image,
with a live preview, and save the result as PNG/TIFF/JPEG.

Each capture from the board (see cis_stream.read_cis_frame) is one scan line:
CIS_CYCLES sensor positions x SAMP_PER_CIS oversamples. Averaging the
oversamples collapses a capture to a single image row; recording repeatedly
captures and stacks rows to build up the scanned image, the same way a
flatbed/line-scan sensor works.

Controls:
    Record / Stop button, or Spacebar, toggles recording.
    On stop, a save dialog prompts for PNG / TIFF (16-bit) or JPEG (8-bit).

Usage:
    python cis_scanner_app.py
"""
import queue
import socket
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox

import numpy as np
from PIL import Image, ImageTk

from cis_stream import BOARD_IP, BOARD_PORT, CIS_CYCLES, read_cis_frame

PREVIEW_WIDTH = 400
assert CIS_CYCLES % PREVIEW_WIDTH == 0
PREVIEW_POOL = CIS_CYCLES // PREVIEW_WIDTH

CANVAS_W = 400
CANVAS_H = 600

ROW_CHUNK = 512
POLL_MS = 33


class ScannerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("CIS Scanner")

        self.sock = None
        self.recording = threading.Event()
        self.capture_thread = None
        self.row_queue = queue.Queue()

        self.capacity = ROW_CHUNK
        self.rows = np.zeros((self.capacity, CIS_CYCLES), dtype=np.uint32)
        self.preview_rows = np.zeros((self.capacity, PREVIEW_WIDTH), dtype=np.uint8)
        self.n_rows = 0
        self.t_rec_start = 0.0
        self.tk_img = None

        self._build_ui()
        self._connect()
        self._poll_queue()

    # ---------------------------------------------------------------- UI --
    def _build_ui(self):
        top = tk.Frame(self.root)
        top.pack(padx=8, pady=8, fill="x")

        self.record_btn = tk.Button(
            top, text="● Record  (Space)", width=20,
            takefocus=0, command=self.toggle_record,
        )
        self.record_btn.pack(side="left")

        self.status_var = tk.StringVar(value="connecting...")
        tk.Label(top, textvariable=self.status_var, anchor="w").pack(
            side="left", padx=12, fill="x", expand=True
        )

        self.canvas = tk.Canvas(self.root, width=CANVAS_W, height=CANVAS_H, bg="black")
        self.canvas.pack(padx=8, pady=(0, 8))
        self.canvas_img_id = self.canvas.create_image(0, 0, anchor="nw")

        self.root.bind("<KeyPress-space>", self.toggle_record)
        self.root.focus_set()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _connect(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
            s.settimeout(10.0)
            s.connect((BOARD_IP, BOARD_PORT))
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.sock = s
            self.status_var.set(f"connected to {BOARD_IP}:{BOARD_PORT}")
        except OSError as e:
            self.status_var.set("not connected")
            messagebox.showerror("Connection failed", str(e))

    # ------------------------------------------------------------ record --
    def toggle_record(self, event=None):
        if self.recording.is_set():
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        if self.sock is None:
            messagebox.showwarning("Not connected", "No connection to the board.")
            return
        if self.recording.is_set():
            return
        self._reset_buffer()
        self.t_rec_start = time.perf_counter()
        self.recording.set()
        self.record_btn.config(text="■ Stop  (Space)")
        self.capture_thread = threading.Thread(target=self._capture_loop, daemon=True)
        self.capture_thread.start()

    def stop_recording(self):
        if not self.recording.is_set():
            return
        self.recording.clear()
        self.record_btn.config(text="● Record  (Space)")
        # Let the in-flight capture drain into the queue before prompting save.
        self.root.after(100, self._prompt_save)

    def _capture_loop(self):
        while self.recording.is_set():
            try:
                pixels, _raw, timing = read_cis_frame(self.sock)
            except (OSError, ConnectionError) as e:
                self.recording.clear()
                self.row_queue.put(("error", str(e)))
                return
            line = pixels.mean(axis=1)
            self.row_queue.put(("line", line))

    # --------------------------------------------------------------- UI --
    def _poll_queue(self):
        drained = 0
        while True:
            try:
                item = self.row_queue.get_nowait()
            except queue.Empty:
                break
            if item[0] == "error":
                self.recording.clear()
                self.record_btn.config(text="● Record  (Space)")
                messagebox.showerror("Capture error", item[1])
                continue
            self._append_row(item[1])
            drained += 1

        if drained:
            self._update_preview()
        self._update_status()
        self.root.after(POLL_MS, self._poll_queue)

    def _reset_buffer(self):
        self.capacity = ROW_CHUNK
        self.rows = np.zeros((self.capacity, CIS_CYCLES), dtype=np.uint32)
        self.preview_rows = np.zeros((self.capacity, PREVIEW_WIDTH), dtype=np.uint8)
        self.n_rows = 0

    def _grow(self):
        new_cap = self.capacity * 2
        new_rows = np.zeros((new_cap, CIS_CYCLES), dtype=np.uint32)
        new_rows[: self.n_rows] = self.rows[: self.n_rows]
        self.rows = new_rows
        new_preview = np.zeros((new_cap, PREVIEW_WIDTH), dtype=np.uint8)
        new_preview[: self.n_rows] = self.preview_rows[: self.n_rows]
        self.preview_rows = new_preview
        self.capacity = new_cap

    def _append_row(self, line):
        if self.n_rows >= self.capacity:
            self._grow()
        self.rows[self.n_rows] = line.astype(np.uint32)
        pooled = line.reshape(PREVIEW_WIDTH, PREVIEW_POOL).mean(axis=1)
        self.preview_rows[self.n_rows] = np.clip(pooled / (2 ** 20) * 255, 0, 255).astype(np.uint8)
        self.n_rows += 1

    def _update_preview(self):
        if self.n_rows == 0:
            return
        img = Image.fromarray(self.preview_rows[: self.n_rows], mode="L")
        disp = img.resize((CANVAS_W, CANVAS_H), Image.BILINEAR)
        self.tk_img = ImageTk.PhotoImage(disp)
        self.canvas.itemconfig(self.canvas_img_id, image=self.tk_img)

    def _update_status(self):
        base = f"connected to {BOARD_IP}:{BOARD_PORT}"
        if self.recording.is_set() or self.n_rows > 0:
            elapsed = time.perf_counter() - self.t_rec_start
            fps = self.n_rows / elapsed if elapsed > 0 else 0.0
            state = "recording" if self.recording.is_set() else "stopped"
            self.status_var.set(
                f"{base}  |  {state}  |  lines: {self.n_rows}  "
                f"elapsed: {elapsed:.1f}s  avg: {fps:.2f} fps"
            )
        else:
            self.status_var.set(base)

    # ---------------------------------------------------------------- save --
    def _prompt_save(self):
        if self.n_rows == 0:
            return
        path = filedialog.asksaveasfilename(
            title="Save scanned image",
            defaultextension=".png",
            filetypes=[("PNG", "*.png"), ("TIFF", "*.tiff"), ("JPEG", "*.jpg")],
        )
        if not path:
            return
        data = self.rows[: self.n_rows]
        ext = path.rsplit(".", 1)[-1].lower()
        try:
            if ext in ("jpg", "jpeg"):
                arr8 = (data >> 12).astype(np.uint8)
                Image.fromarray(arr8, mode="L").save(path, quality=95)
            else:
                arr16 = (data >> 4).astype(np.uint16)
                Image.fromarray(arr16, mode="I;16").save(path)
            messagebox.showinfo(
                "Saved", f"Saved {self.n_rows} x {CIS_CYCLES} px image to\n{path}"
            )
        except Exception as e:
            messagebox.showerror("Save failed", str(e))

    def _on_close(self):
        self.recording.clear()
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.root.destroy()


def main():
    root = tk.Tk()
    ScannerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()

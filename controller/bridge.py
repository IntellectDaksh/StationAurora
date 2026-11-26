import argparse
import ctypes
from ctypes import wintypes
import re
import time

import serial


class KeyboardInput(ctypes.Structure):
    _fields_ = [
        ("virtual_key", wintypes.WORD),
        ("scan", wintypes.WORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("extra", ctypes.c_size_t),
    ]


class MouseInput(ctypes.Structure):
    _fields_ = [
        ("x", wintypes.LONG),
        ("y", wintypes.LONG),
        ("data", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("extra", ctypes.c_size_t),
    ]


class InputValue(ctypes.Union):
    _fields_ = [("keyboard", KeyboardInput), ("mouse", MouseInput)]


class Input(ctypes.Structure):
    _fields_ = [("kind", wintypes.DWORD), ("value", InputValue)]


# Arduino bit order: A, D, W, S, Left, Right, camera up/down, Space, F, E.
SCANS = (
    0x1E, 0x20, 0x11, 0x1F, 0x14B, 0x14D,
    None, None, 0x39, 0x21, 0x12,
)
CAMERA_UP = 1 << 6
CAMERA_DOWN = 1 << 7
CAMERA_STEP = 6
CAMERA_INTERVAL = 0.016
REPORT = re.compile(rb"GC,([0-9]{1,4})\r?")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="Arduino serial port, for example COM3")
    args = parser.parse_args()

    send_input = ctypes.WinDLL("user32", use_last_error=True).SendInput
    send_input.argtypes = (wintypes.UINT, ctypes.POINTER(Input), ctypes.c_int)
    send_input.restype = wintypes.UINT

    def send_key(scan, pressed):
        flags = 0x0008  # KEYEVENTF_SCANCODE
        if scan & 0x100:
            flags |= 0x0001  # Extended key, such as an arrow.
        if not pressed:
            flags |= 0x0002  # Key release.

        event = Input(
            1, InputValue(keyboard=KeyboardInput(0, scan & 0xFF, flags, 0, 0))
        )
        if send_input(1, ctypes.byref(event), ctypes.sizeof(event)) != 1:
            raise OSError("Windows blocked keyboard input.")

    def move_camera(dy):
        # MOUSEEVENTF_MOVE sends relative mouse movement.
        event = Input(0, InputValue(mouse=MouseInput(0, dy, 0, 0x0001, 0, 0)))
        if send_input(1, ctypes.byref(event), ctypes.sizeof(event)) != 1:
            raise OSError("Windows blocked mouse input.")

    held = set()

    def apply_keys(mask):
        wanted = {
            scan for bit, scan in enumerate(SCANS)
            if scan is not None and mask & (1 << bit)
        }
        for scan in sorted(held - wanted):
            send_key(scan, False)
            held.remove(scan)
        for scan in sorted(wanted - held):
            send_key(scan, True)
            held.add(scan)

    try:
        while True:
            try:
                with serial.Serial(args.port, 115200, timeout=0.02) as port:
                    print(f"Connected to {args.port}. Keep both sticks centered.")
                    print("Click into your game. Press Ctrl+C here to stop.")
                    buffer = b""
                    last_report = time.monotonic()
                    last_camera_move = last_report
                    camera_direction = 0
                    last_mask = 0
        
                    while True:
                        buffer += port.read(min(port.in_waiting or 1, 4096))
                        *lines, buffer = buffer.split(b"\n")
                        if len(buffer) > 32:
                            buffer = b""
        
                        for line in lines:
                            report = REPORT.fullmatch(line)
                            if report:
                                mask = int(report[1])
                                if mask != last_mask:
                                    print(f"mask={mask} bits={[b for b in range(16) if mask >> b & 1]}", flush=True)
                                    last_mask = mask
                                if mask < (1 << len(SCANS)):
                                    apply_keys(mask)
                                    camera_direction = (
                                        bool(mask & CAMERA_DOWN) - bool(mask & CAMERA_UP)
                                    )
                                    last_report = time.monotonic()
        
                        now = time.monotonic()
                        if now - last_report > 0.30:
                            apply_keys(0)
                            camera_direction = 0
        
                        if camera_direction and now - last_camera_move >= CAMERA_INTERVAL:
                            move_camera(camera_direction * CAMERA_STEP)
                            last_camera_move = now
        
            except serial.SerialException as error:
                # USB drops on this console; release keys and reconnect instead of exiting.
                apply_keys(0)
                print(f"Lost {args.port} ({error}). Reconnecting...", flush=True)
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    except (serial.SerialException, OSError) as error:
        parser.exit(1, f"{error}\n")
    finally:
        for scan in sorted(held):
            try:
                send_key(scan, False)
            except OSError:
                print("Windows blocked a key release.")


if __name__ == "__main__":
    main()
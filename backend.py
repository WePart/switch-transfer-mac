"""DBI USB transport for the native macOS companion.

DBI0 wire format follows GuangLun2000/DBI-backend-for-switch and
rashevskyv/dbi (dev#Mikami / duckbill). No network access or auto-install.
The GUI communicates through newline-delimited JSON on stdin/stdout.
"""
from __future__ import annotations

from collections import deque
import json
import os
from pathlib import Path
import signal
import struct
import sys
import threading
import time

import usb.core
import usb.util
import usb.backend.libusb1

VERSION = '1.1.0'
SUPPORTED = {'.nsp', '.nsz', '.xci', '.xcz'}
HEADER = struct.Struct('<4sIII')
CHUNK = 1024 * 1024
SPEED_WINDOW = 3.0  # seconds of recent transfer used for the live speed


class Cancelled(Exception):
    pass


class ProtocolError(Exception):
    pass


def catalog(paths):
    files = {}
    for value in paths:
        path = Path(value).resolve(strict=True)
        if not path.is_file() or path.suffix.lower() not in SUPPORTED:
            raise ValueError(f'不是支持的安装包：{path.name}')
        if path.name.startswith('.') or any(c in path.name for c in '\r\n\x00'):
            raise ValueError(f'文件名包含不支持的字符：{path.name}')
        if path.name in files and files[path.name] != path:
            raise ValueError(f'存在同名文件，请先重命名：{path.name}')
        if path.stat().st_size == 0:
            raise ValueError(f'文件为空：{path.name}')
        with path.open('rb'):
            pass
        files[path.name] = path
    if not files:
        raise ValueError('请先添加安装包。')
    return files


def merged_ranges(ranges, start, end):
    """Track unique bytes requested, avoiding double counting DBI rereads."""
    merged = []
    for left, right in sorted([*ranges, (start, end)]):
        if merged and left <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(right, merged[-1][1]))
        else:
            merged.append((left, right))
    return merged


class Protocol:
    def __init__(self, device, files, stop, emit):
        self.device, self.files, self.stop, self.emit = device, files, stop, emit
        self.ranges = {}
        self.total_sent = 0
        self.began = None
        self.last_progress = 0
        self.last_name = None
        self.completed = set()
        self.samples = deque()

    def speed(self, now):
        while len(self.samples) > 1 and now - self.samples[0][0] > SPEED_WINDOW:
            self.samples.popleft()
        start, base = self.samples[0]
        if now - start >= .5:
            return (self.total_sent - base) / (now - start)
        return self.total_sent / max(now - self.began, .001)

    def check(self):
        if self.stop.is_set():
            raise Cancelled()

    def read(self, size, idle=False):
        deadline = time.monotonic() + 15
        while True:
            self.check()
            try:
                result = bytes(self.device.read(0x81, size, timeout=500))
                if len(result) != size:
                    raise ProtocolError('收到不完整的数据，请在 Switch 上退出并重新进入后端模式。')
                return result
            except usb.core.USBTimeoutError:
                if not idle and time.monotonic() > deadline:
                    raise ProtocolError('Switch 长时间没有响应，请退出并重新进入后端模式。')

    def write(self, data):
        self.check()
        # Never retry a timed-out write: some bytes may already have arrived.
        count = self.device.write(0x01, data, timeout=2000)
        if count != len(data):
            raise ProtocolError('USB 数据未完整发送，请重新连接后再试。')

    def header(self, kind, command, size=0):
        self.write(HEADER.pack(b'DBI0', kind, command, size))

    def ack(self, command):
        magic, kind, received, size = HEADER.unpack(self.read(16))
        if magic != b'DBI0' or kind != 2 or received != command:
            raise ProtocolError('DBI 应答异常，请确认 Switch 已进入“从 DBIbackend 安装”。')

    def list_files(self):
        payload = ''.join(name + '\n' for name in self.files).encode('utf-8')
        self.header(1, 3, len(payload))
        if payload:
            self.ack(3)
            self.write(payload)
        self.emit('state', state='ready', message='文件列表已发送，请在 Switch 上选择安装包并开始安装。')

    def file_range(self, size):
        if not 16 <= size <= 65536:
            raise ProtocolError('DBI 请求长度异常。')
        self.header(2, 2, size)
        request = self.read(size)
        length, offset, name_len = struct.unpack('<IQI', request[:16])
        name_bytes = request[16:]
        if name_len != len(name_bytes):
            raise ProtocolError('DBI 请求中的文件名长度不匹配。')
        name = name_bytes.decode('utf-8')
        if name not in self.files:
            raise ProtocolError('Switch 请求的文件已不在列表中，请刷新 Switch 上的列表。')
        path = self.files[name]
        file_size = path.stat().st_size
        if offset > file_size or length > file_size - offset:
            raise ProtocolError(f'文件大小发生变化或请求超出范围：{name}')
        with path.open('rb') as source:
            source.seek(offset)
            self.header(1, 2, length)
            self.ack(2)
            if self.began is None:
                self.began = time.monotonic()
            if self.last_name != name:
                self.emit('log', message=f'开始发送：{name}')
                self.last_name = name
            current = offset
            remaining = length
            while remaining:
                self.check()
                chunk = source.read(min(CHUNK, remaining))
                if not chunk:
                    raise ProtocolError(f'读取文件提前结束，请检查文件是否完整：{name}')
                self.samples.append((time.monotonic(), self.total_sent))
                self.write(chunk)
                self.total_sent += len(chunk)
                self.ranges[name] = merged_ranges(self.ranges.get(name, []), current, current + len(chunk))
                current += len(chunk)
                remaining -= len(chunk)
                now = time.monotonic()
                if now - self.last_progress >= .2 or remaining == 0:
                    sent = sum(b - a for a, b in self.ranges[name])
                    self.emit('progress', name=name, sent=sent, size=file_size,
                              total_sent=self.total_sent, speed=self.speed(now),
                              avg_speed=self.total_sent / max(now - self.began, .001))
                    self.last_progress = now
                    if sent >= file_size and name not in self.completed:
                        self.completed.add(name)
                        self.emit('file_done', name=name, size=file_size)

    def run(self):
        handshake = False
        while True:
            magic, kind, command, size = HEADER.unpack(self.read(16, idle=True))
            if magic != b'DBI0' or kind != 0:
                raise ProtocolError('USB 模式不匹配，请在 DBI 中选择“从 DBIbackend 安装”。')
            if not handshake:
                handshake = True
                self.emit('state', state='connected', message='已与 DBI 建立连接。')
            if command == 0:
                self.header(1, 0)
                self.emit('state', state='ended', message='Switch 已结束本次会话。安装结果请以 Switch 屏幕为准。')
                return
            if command == 3:
                self.list_files()
            elif command == 2:
                self.file_range(size)
            else:
                raise ProtocolError('此 DBI 协议版本暂不支持，请使用支持 DBI0 文件列表的版本。')


def usb_backend():
    if getattr(sys, 'frozen', False):
        library = Path(sys._MEIPASS) / 'libusb-1.0.dylib'
        backend = usb.backend.libusb1.get_backend(find_library=lambda _: str(library))
    else:
        backend = usb.backend.libusb1.get_backend()
    if backend is None:
        raise RuntimeError('应用内的 USB 组件无法加载，请重新打开或重新安装应用。')
    return backend


def error_message(error):
    code = getattr(error, 'backend_error_code', None)
    if code in (-3, -6) or getattr(error, 'errno', None) in (13, 16):
        return '无法独占访问 Switch。请退出 OpenMTP、Android File Transfer 和其他 DBI 工具，再重新插拔数据线。'
    if isinstance(error, usb.core.USBError):
        return 'USB 连接中断或超时。请检查数据线，退出其他传输工具，并在 Switch 重新进入后端模式。'
    return str(error)


class Worker:
    def __init__(self):
        self.output_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.quit_event = threading.Event()
        self.usb_lock = threading.Lock()
        self.thread = None
        self.backend = usb_backend()

    def emit(self, event, **values):
        with self.output_lock:
            print(json.dumps(dict(event=event, **values), ensure_ascii=False), flush=True)

    def probe(self):
        with self.usb_lock:
            if self.thread and self.thread.is_alive():
                return
            device = usb.core.find(idVendor=0x057e, idProduct=0x3000, backend=self.backend)
            mode = 'unknown'
            if device is not None:
                try:
                    mode = 'mtp' if any(i.bInterfaceClass == 6 for i in device.get_active_configuration()) else 'backend'
                finally:
                    usb.util.dispose_resources(device)
            self.emit('device', present=device is not None, mode=mode)

    def monitor(self):
        while not self.quit_event.is_set():
            try:
                self.probe()
            except Exception as error:
                self.emit('device', present=False, mode='error', message=error_message(error))
            self.quit_event.wait(2)

    def serve(self, files):
        try:
            while not self.stop_event.is_set():
                device = None
                try:
                    self.emit('state', state='waiting', message='服务已启动，等待 Switch。请打开 DBI 的“从 DBIbackend 安装”。')
                    while not self.stop_event.is_set():
                        with self.usb_lock:
                            device = usb.core.find(idVendor=0x057e, idProduct=0x3000, backend=self.backend)
                        if device is not None:
                            break
                        self.stop_event.wait(1)
                    if self.stop_event.is_set():
                        raise Cancelled()
                    cfg = device.get_active_configuration()
                    if any(i.bInterfaceClass == 6 for i in cfg):
                        raise ProtocolError('当前是 MTP 模式。请在 Switch 返回 DBI 主菜单，选择“从 DBIbackend 安装”。')
                    self.emit('state', state='handshake', message='已检测到 Switch，等待 DBI 请求文件列表。')
                    Protocol(device, files, self.stop_event, self.emit).run()
                    break
                except usb.core.USBError as error:
                    if self.stop_event.is_set():
                        break
                    self.emit('state', state='reconnecting', message=error_message(error) + ' 应用将等待重新连接；不会自动续传，重连后请在 Switch 重新选择安装。')
                    self.stop_event.wait(2)
                finally:
                    if device is not None:
                        usb.util.dispose_resources(device)
        except Cancelled:
            pass
        except Exception as error:
            self.emit('error', message=error_message(error))
        finally:
            self.emit('stopped')

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(3)

    def run(self):
        self.emit('boot', version=VERSION, backend='ok')
        threading.Thread(target=self.monitor, daemon=True).start()
        try:
            for line in sys.stdin:
                try:
                    command = json.loads(line)
                    if command['command'] == 'start':
                        if self.thread and self.thread.is_alive():
                            raise ValueError('传输服务仍在运行，请先停止。')
                        files = catalog(command['paths'])
                        self.stop_event.clear()
                        self.thread = threading.Thread(target=self.serve, args=(files,), daemon=True)
                        self.thread.start()
                    elif command['command'] == 'stop':
                        self.stop()
                    elif command['command'] == 'probe':
                        self.probe()
                    elif command['command'] == 'quit':
                        break
                except Exception as error:
                    self.emit('error', message=error_message(error))
        finally:
            self.quit_event.set()
            self.stop()


def main():
    try:
        if '--self-check' in sys.argv:
            backend = usb_backend()
            devices = list(usb.core.find(find_all=True, backend=backend))
            print(json.dumps({'ok': True, 'version': VERSION, 'backend': 'bundled' if getattr(sys, 'frozen', False) else 'system',
                              'switch_present': any(d.idVendor == 0x057e and d.idProduct == 0x3000 for d in devices)}))
        else:
            Worker().run()
    except Exception as error:
        print(json.dumps({'event': 'fatal', 'message': error_message(error)}, ensure_ascii=False), flush=True)
        raise SystemExit(1)


if __name__ == '__main__':
    main()

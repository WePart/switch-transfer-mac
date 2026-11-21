import struct
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import backend as b


class FakeDevice:
    def __init__(self, reads):
        self.reads = list(reads)
        self.writes = []
    def read(self, endpoint, size, timeout):
        assert endpoint == 0x81
        value = self.reads.pop(0)
        if isinstance(value, Exception):
            raise value
        return value
    def write(self, endpoint, data, timeout):
        assert endpoint == 1
        self.writes.append(bytes(data))
        return len(data)


def packet(kind, command, size=0):
    return b.HEADER.pack(b'DBI0', kind, command, size)


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / '中文 安装包.nsp'
        self.content = bytes(range(256)) * 9000
        self.path.write_bytes(self.content)
        self.events = []
        self.stop = threading.Event()

    def tearDown(self):
        self.temp.cleanup()

    def protocol(self, reads):
        self.device = FakeDevice(reads)
        return b.Protocol(self.device, {self.path.name: self.path}, self.stop,
                          lambda event, **data: self.events.append((event, data)))

    def request(self, offset, length, name=None):
        name = (name or self.path.name).encode('utf-8')
        return struct.pack('<IQI', length, offset, len(name)) + name

    def test_unicode_list_and_clean_exit(self):
        p = self.protocol([packet(0, 3), packet(2, 3), packet(0, 0)])
        p.run()
        payload = (self.path.name + '\n').encode()
        self.assertEqual(self.device.writes, [packet(1, 3, len(payload)), payload, packet(1, 0)])
        self.assertEqual(self.events[-1][1]['state'], 'ended')

    def test_real_bytes_offsets_and_chunk_boundaries(self):
        req = self.request(77, 2 * b.CHUNK + 100)
        p = self.protocol([req, packet(2, 2)])
        p.file_range(len(req))
        self.assertEqual(b''.join(self.device.writes[2:]), self.content[77:77 + 2*b.CHUNK + 100])
        self.assertEqual([len(x) for x in self.device.writes[2:]], [b.CHUNK, b.CHUNK, 100])
        self.assertEqual(self.events[-1][1]['sent'], 2*b.CHUNK+100)

    def test_reread_progress_does_not_double_count(self):
        req1, req2 = self.request(10, 100), self.request(50, 100)
        p = self.protocol([req1, packet(2, 2), req2, packet(2, 2)])
        p.file_range(len(req1)); p.file_range(len(req2))
        self.assertEqual(self.events[-1][1]['sent'], 140)
        self.assertEqual(self.events[-1][1]['total_sent'], 200)

    def test_out_of_range_fails_before_sending_payload(self):
        req = self.request(len(self.content)-1, 2)
        p = self.protocol([req])
        with self.assertRaises(b.ProtocolError): p.file_range(len(req))
        self.assertEqual(len(self.device.writes), 1)

    def test_unknown_filename_cannot_escape_catalog(self):
        req = self.request(0, 10, '../../secret.nsp')
        p = self.protocol([req])
        with self.assertRaises(b.ProtocolError): p.file_range(len(req))

    def test_bad_ack_rejected(self):
        p = self.protocol([packet(1, 3)])
        with self.assertRaises(b.ProtocolError): p.list_files()

    def test_short_header_rejected(self):
        p = self.protocol([b'DBI0'])
        with self.assertRaises(b.ProtocolError): p.run()

    def test_mismatched_name_length_rejected(self):
        req = struct.pack('<IQI', 1, 0, 123) + self.path.name.encode()
        p = self.protocol([req])
        with self.assertRaises(b.ProtocolError): p.file_range(len(req))

    def test_cancel_waiting(self):
        p = self.protocol([]); self.stop.set()
        with self.assertRaises(b.Cancelled): p.run()
        self.assertEqual(self.device.writes, [])

    def test_partial_usb_write_not_counted_as_success(self):
        p = self.protocol([])
        self.device.write = lambda *args, **kwargs: 1
        with self.assertRaises(b.ProtocolError): p.write(b'abcd')

    def test_short_source_read_fails_instead_of_looping_forever(self):
        req = self.request(0, 100)
        p = self.protocol([req, packet(2, 2)])
        from io import BytesIO
        with patch.object(Path, 'open', return_value=BytesIO(b'')):
            with self.assertRaises(b.ProtocolError): p.file_range(len(req))

    def test_catalog_filters_archive_empty_missing_and_duplicate_names(self):
        archive = self.root/'file.zip'; archive.write_bytes(b'zip')
        empty = self.root/'empty.nsz'; empty.touch()
        other = self.root/'other'; other.mkdir()
        duplicate = other/self.path.name; duplicate.write_bytes(b'abc')
        for paths in ([archive], [empty], [self.root/'missing.nsp'], [self.path, duplicate], []):
            with self.assertRaises((ValueError, FileNotFoundError)): b.catalog(paths)
        self.assertEqual(len(b.catalog([self.path, self.path])), 1)

    def test_range_merge(self):
        self.assertEqual(b.merged_ranges([(0, 5), (10, 20)], 5, 10), [(0, 20)])
        self.assertEqual(b.merged_ranges([(5, 10)], 1, 2), [(1, 2), (5, 10)])

    def test_idle_timeout_can_be_cancelled(self):
        p = self.protocol([])
        def timeout(*args, **kwargs):
            self.stop.set()
            raise b.usb.core.USBTimeoutError('timeout')
        self.device.read = timeout
        with self.assertRaises(b.Cancelled): p.run()

    def test_worker_can_stop_waiting_and_restart_without_usb(self):
        with patch.object(b, 'usb_backend', return_value=object()), patch.object(b.usb.core, 'find', return_value=None):
            worker = b.Worker()
            worker.emit = lambda event, **data: self.events.append((event, data))
            for _ in range(2):
                worker.stop_event.clear()
                worker.thread = threading.Thread(target=worker.serve, args=({self.path.name: self.path},))
                worker.thread.start()
                worker.stop()
                self.assertFalse(worker.thread.is_alive())
            self.assertEqual(sum(event == 'stopped' for event, _ in self.events), 2)

    def test_mtp_mode_shows_actionable_error_and_stops(self):
        class Interface:
            bInterfaceClass = 6
        class Device:
            def get_active_configuration(self): return [Interface()]
        with patch.object(b, 'usb_backend', return_value=object()), patch.object(b.usb.core, 'find', return_value=Device()), patch.object(b.usb.util, 'dispose_resources'):
            worker = b.Worker()
            worker.emit = lambda event, **data: self.events.append((event, data))
            worker.serve({self.path.name: self.path})
            errors = [data['message'] for event, data in self.events if event == 'error']
            self.assertIn('MTP', errors[0])
            self.assertEqual(self.events[-1][0], 'stopped')

    def test_disconnect_reconnects_and_releases_each_device(self):
        class Interface:
            bInterfaceClass = 255
        class Device:
            def get_active_configuration(self): return [Interface()]
        first, second = Device(), Device()
        with patch.object(b, 'usb_backend', return_value=object()), patch.object(b.usb.core, 'find', side_effect=[first, second]), patch.object(b.usb.util, 'dispose_resources') as release, patch.object(b.Protocol, 'run', side_effect=[b.usb.core.USBError('disconnected'), None]):
            worker = b.Worker()
            worker.emit = lambda event, **data: self.events.append((event, data))
            with patch.object(worker.stop_event, 'wait', return_value=False):
                worker.serve({self.path.name: self.path})
            self.assertTrue(any(data.get('state') == 'reconnecting' for _, data in self.events))
            self.assertEqual(release.call_count, 2)


if __name__ == '__main__':
    unittest.main()

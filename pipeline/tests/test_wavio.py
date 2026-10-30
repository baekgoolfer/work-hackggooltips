"""wavio: lenient reader (header repair) and int16 writer. Needs numpy only."""
import struct
import sys
import tempfile
import unittest
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from mcap import wavio  # noqa: E402


def wav_bytes(pcm: bytes, *, sr=48000, channels=1, bits=16, tag=1, data_size=None, riff_size=None, pre_chunks=b"", post_chunks=b"",
              fmt_extra=b""):
    """Hand-built WAV so every header lie can be reproduced. data_size/riff_size override the honest values."""
    fmt_body = struct.pack("<HHIIHH", tag, channels, sr, sr * channels * bits // 8, channels * bits // 8, bits) + fmt_extra
    fmt = b"fmt " + struct.pack("<I", len(fmt_body)) + fmt_body
    ds = len(pcm) if data_size is None else data_size
    body = b"WAVE" + fmt + pre_chunks + b"data" + struct.pack("<I", ds) + pcm + post_chunks
    rs = len(body) if riff_size is None else riff_size
    return b"RIFF" + struct.pack("<I", rs) + body


def pcm16(n, seed=0):
    return np.random.default_rng(seed).integers(-30000, 30000, n).astype("<i2")


class WavioTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, data: bytes, name="t.wav") -> Path:
        p = self.dir / name
        p.write_bytes(data)
        return p

    def check(self, path, expected_int16, sr=48000):
        x, got_sr = wavio.read_wav_lenient(path)
        self.assertEqual(got_sr, sr)
        self.assertEqual(x.dtype, np.float32)
        np.testing.assert_array_equal(x, expected_int16.astype(np.float32) / 32768.0)

    # ---- well-formed files -----------------------------------------------------------
    def test_roundtrip_and_stdlib_compat(self):
        s = pcm16(1000)
        p = self.dir / "a.wav"
        wavio.write_wav_int16(p, s, 48000)
        self.check(p, s)
        with wave.open(str(p)) as w:                       # the stdlib agrees on what we wrote
            self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (1, 2, 48000, 1000))
            self.assertEqual(np.frombuffer(w.readframes(1000), "<i2").tolist(), s.tolist())
        self.assertFalse((self.dir / "a.wav.tmp").exists())

    def test_reads_stdlib_written_file(self):
        p = self.dir / "b.wav"
        s = pcm16(321)
        with wave.open(str(p), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(s.tobytes())
        self.check(p, s, sr=16000)
        self.assertEqual(wavio.read_wav_info(p).repaired, "")

    # ---- header repair --------------------------------------------------------------
    def test_sizes_zero_as_written_at_open(self):
        s = pcm16(4800)
        p = self.write(wav_bytes(s.tobytes(), data_size=0, riff_size=0))
        self.check(p, s)
        self.assertIn("data size", wavio.read_wav_info(p).repaired)

    def test_sizes_0xffffffff(self):
        s = pcm16(777)
        self.check(self.write(wav_bytes(s.tobytes(), data_size=0xFFFFFFFF, riff_size=0xFFFFFFFF)), s)

    def test_stale_header_smaller_than_file(self):
        """Recorder crashed after the last 5 s header refresh: header says 100 frames, 1000 are on disk."""
        s = pcm16(1000)
        p = self.write(wav_bytes(s.tobytes(), data_size=200, riff_size=236))
        self.check(p, s)
        self.assertIn("stale", wavio.read_wav_info(p).repaired)

    def test_stale_header_followed_by_digital_silence(self):
        s = np.concatenate([pcm16(300), np.zeros(700, "<i2")])
        self.check(self.write(wav_bytes(s.tobytes(), data_size=600)), s)

    def test_header_claims_more_than_file_has(self):
        s = pcm16(500)
        self.check(self.write(wav_bytes(s.tobytes(), data_size=10_000_000, riff_size=10_000_036)), s)

    def test_torn_odd_byte(self):
        s = pcm16(1001)
        p = self.write(wav_bytes(s.tobytes() + b"\x7f", data_size=0))
        self.check(p, s)
        self.assertIn("torn", wavio.read_wav_info(p).repaired)

    def test_torn_byte_with_honest_size(self):
        s = pcm16(10)
        self.check(self.write(wav_bytes(s.tobytes() + b"\x01")), s)

    def test_header_only_file_is_empty_audio(self):
        p = self.write(wav_bytes(b"", data_size=0, riff_size=0))
        x, sr = wavio.read_wav_lenient(p)
        self.assertEqual((len(x), sr), (0, 48000))

    def test_trailing_chunk_after_data_is_not_audio(self):
        s = pcm16(400)
        lst = b"LIST" + struct.pack("<I", 12) + b"INFOISFT\x04\x00\x00\x00"
        self.check(self.write(wav_bytes(s.tobytes(), post_chunks=lst)), s)

    def test_extra_chunk_before_data_with_odd_size(self):
        s = pcm16(64)
        junk = b"JUNK" + struct.pack("<I", 5) + b"abcde" + b"\x00"       # odd size + pad byte
        self.check(self.write(wav_bytes(s.tobytes(), pre_chunks=junk)), s)

    # ---- other formats ---------------------------------------------------------------
    def test_wave_format_extensible(self):
        s = pcm16(50)
        ext = struct.pack("<HHI", 22, 16, 4) + struct.pack("<H", 1) + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
        self.check(self.write(wav_bytes(s.tobytes(), tag=0xFFFE, fmt_extra=ext)), s)

    def test_stereo_is_averaged(self):
        left, right = pcm16(100, 1), pcm16(100, 2)
        inter = np.empty(200, "<i2")
        inter[0::2], inter[1::2] = left, right
        x, _ = wavio.read_wav_lenient(self.write(wav_bytes(inter.tobytes(), channels=2)))
        np.testing.assert_allclose(x, (left.astype(np.float32) + right) / 2 / 32768.0, atol=1e-7)

    def test_24_bit_32_bit_float_and_8_bit(self):
        vals = np.array([0, 1, -1, 8388607, -8388608, 4000000], dtype=np.int32)
        pcm24 = b"".join(int(v & 0xFFFFFF).to_bytes(3, "little") for v in vals)
        x, _ = wavio.read_wav_lenient(self.write(wav_bytes(pcm24, bits=24), "24.wav"))
        np.testing.assert_allclose(x, vals / 8388608.0, atol=1e-7)
        f = np.array([0.0, 0.5, -0.25, 1.0, float("nan")], "<f4")
        x, _ = wavio.read_wav_lenient(self.write(wav_bytes(f.tobytes(), bits=32, tag=3), "f.wav"))
        np.testing.assert_allclose(x, [0.0, 0.5, -0.25, 1.0, 0.0])
        x, _ = wavio.read_wav_lenient(self.write(wav_bytes(bytes([128, 255, 0]), bits=8), "8.wav"))
        np.testing.assert_allclose(x, [0.0, 127 / 128, -1.0])
        i32 = np.array([0, 2**30, -2**31], "<i4")
        x, _ = wavio.read_wav_lenient(self.write(wav_bytes(i32.tobytes(), bits=32), "32.wav"))
        np.testing.assert_allclose(x, [0.0, 0.5, -1.0])

    def test_read_wav_padded(self):
        s = pcm16(1000)
        p = self.write(wav_bytes(s.tobytes(), data_size=0))                       # broken header too
        x, sr = wavio.read_wav_padded(p, front=250, total=1600)
        self.assertEqual((len(x), sr, x.dtype), (1600, 48000, np.float32))
        np.testing.assert_array_equal(x[:250], 0)
        np.testing.assert_array_equal(x[250:1250], s.astype(np.float32) / 32768.0)
        np.testing.assert_array_equal(x[1250:], 0)
        x, _ = wavio.read_wav_padded(p, front=900, total=1000)                     # audio that does not fit is cut
        np.testing.assert_array_equal(x[900:], s[:100].astype(np.float32) / 32768.0)
        x, _ = wavio.read_wav_padded(p, front=2000, total=1500)                    # nothing fits
        self.assertEqual((len(x), float(np.abs(x).max())), (1500, 0.0))
        self.assertEqual(len(wavio.read_wav_padded(p)[0]), 1000)                   # defaults: front 0, all frames
        big = pcm16(wavio._READ_BLOCK * 2 + 123, seed=5)                           # spans several read blocks
        x, _ = wavio.read_wav_padded(self.write(wav_bytes(big.tobytes()), "big.wav"), front=7)
        np.testing.assert_array_equal(x[7:], big.astype(np.float32) / 32768.0)
        stereo = np.repeat(pcm16(50), 2)
        x, _ = wavio.read_wav_padded(self.write(wav_bytes(stereo.tobytes(), channels=2), "st.wav"), front=3, total=60)
        self.assertEqual(len(x), 60)

    def test_writer_handles_blocks(self):
        big = pcm16(wavio._WRITE_BLOCK * 2 + 77, seed=9)
        p = self.dir / "blocks.wav"
        wavio.write_wav_int16(p, big, 48000)
        self.check(p, big)
        wavio.write_wav_int16(p, big.astype(np.float32) / 32768.0, 48000)
        self.check(p, big)

    # ---- garbage ---------------------------------------------------------------------
    def test_not_wav_raises_wavio_error(self):
        cases = {
            "empty": b"",
            "text": b"hello world, definitely not a wav file",
            "riff_only": b"RIFF\x00\x00\x00\x00",
            "no_data": b"RIFF" + struct.pack("<I", 28) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 48000, 96000, 2, 16),
            "short_fmt": b"RIFF\x20\x00\x00\x00WAVEfmt " + struct.pack("<IHH", 4, 1, 1) + b"data\x00\x00\x00\x00",
            "adpcm": wav_bytes(b"\x00" * 8, tag=2),
            "zero_channels": wav_bytes(b"\x00" * 8, channels=0),
            "zero_rate": wav_bytes(b"\x00" * 8, sr=0),
            "odd_bits": wav_bytes(b"\x00" * 8, bits=12),
        }
        for name, data in cases.items():
            with self.subTest(name):
                with self.assertRaises(wavio.WavError):
                    wavio.read_wav_lenient(self.write(data, f"{name}.wav"))

    def test_missing_file_raises_oserror(self):
        with self.assertRaises(OSError):
            wavio.read_wav_lenient(self.dir / "nope.wav")

    # ---- writer ----------------------------------------------------------------------
    def test_writer_clips_rounds_and_handles_nan(self):
        p = self.dir / "w.wav"
        wavio.write_wav_int16(p, np.array([0.0, 0.5, -0.5, 2.0, -3.0, np.nan, np.inf], np.float32), 16000)
        x, sr = wavio.read_wav_lenient(p)
        self.assertEqual(sr, 16000)
        np.testing.assert_allclose(x, [0.0, 0.5, -0.5, 32767 / 32768, -1.0, 0.0, 32767 / 32768], atol=1e-7)

    def test_writer_int16_passthrough_and_empty(self):
        p = self.dir / "w2.wav"
        s = np.array([-32768, 0, 32767], np.int16)
        wavio.write_wav_int16(p, s, 48000)
        self.check(p, s)
        wavio.write_wav_int16(p, np.zeros(0, np.float32), 48000)
        self.assertEqual(len(wavio.read_wav_lenient(p)[0]), 0)

    def test_writer_rejects_2d(self):
        with self.assertRaises(ValueError):
            wavio.write_wav_int16(self.dir / "x.wav", np.zeros((2, 3), np.float32), 16000)

    def test_writer_replaces_atomically(self):
        p = self.dir / "r.wav"
        wavio.write_wav_int16(p, pcm16(100), 48000)
        wavio.write_wav_int16(p, pcm16(50), 48000)
        self.assertEqual(len(wavio.read_wav_lenient(p)[0]), 50)
        self.assertEqual(sorted(q.name for q in self.dir.iterdir()), ["r.wav"])


if __name__ == "__main__":
    unittest.main()

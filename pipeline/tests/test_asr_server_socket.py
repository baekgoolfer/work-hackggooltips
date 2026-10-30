"""One real loopback socket smoke test of the mcap-asr/1 server front end (SPEC 18: the only place that opens a socket; every other
server test uses ``handle_request`` or a socketpair). Skipped unless MCAP_TEST_LOOPBACK=1: the default suite opens no socket.

It binds 127.0.0.1 on a port the OS picks, talks to it with ``http.client`` and raw bytes, and checks the pieces that only a real TCP
connection can show: framing over the wire, ``Connection: close``, an early 413/401 that the client can still read, the rejected raw
request shapes, and TLS 1.2+ with a throw-away certificate (the client connects to 127.0.0.1 and checks the name of the certificate)."""
import hashlib
import http.client
import json
import os
import socket
import ssl
import threading
import unittest
from unittest import mock

from net_guard_support import TEST_PKI, write_test_pki
from test_asr_server import TEXT_CANARY, ServerCase, pcm, read_to_eof, split_answer

from mcap import asr_server as S
from mcap.egress import EgressDenied, EgressGuard
from mcap.policy import HostRule

ENABLED = os.environ.get("MCAP_TEST_LOOPBACK") == "1"


@unittest.skipUnless(ENABLED, "set MCAP_TEST_LOOPBACK=1 to run the real loopback socket smoke test")
class LoopbackSmokeTests(ServerCase):
    def serve(self, state):
        server = S.make_server(state, ("127.0.0.1", 0))
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join(10)

        self.addCleanup(stop)
        return server.server_address[1]

    def raw(self, port, data, context=None, hostname=None):
        sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        if context is not None:
            sock = context.wrap_socket(sock, server_hostname=hostname)
        self.addCleanup(sock.close)
        sock.sendall(data)
        return split_answer(read_to_eof(sock))

    def test_the_wire(self):
        port = self.serve(self.state)
        tok = self.token("mic")
        auth = {"Authorization": f"Bearer {tok}", "X-MCAP-Proto": S.PROTO}

        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("GET", "/v1/health", headers={"X-MCAP-Proto": S.PROTO})
        reply = conn.getresponse()
        self.assertEqual((reply.status, json.loads(reply.read())), (200, {"proto": S.PROTO, "ok": True}))
        self.assertEqual(reply.getheader("Connection"), "close")

        body = pcm(16000)
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("POST", "/v1/chunk", body=body, headers={**auth, "Content-Type": "application/octet-stream", "X-MCAP-Samples": "16000",
                                                              "X-MCAP-Lang": "ko", "X-MCAP-Idem": "smoke-1"})
        reply = conn.getresponse()
        answer = json.loads(reply.read())
        self.assertEqual((reply.status, answer["text"], answer["language"]), (200, TEXT_CANARY, "ko"))

        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)                     # the retry is answered from memory
        conn.request("POST", "/v1/chunk", body=body, headers={**auth, "Content-Type": "application/octet-stream", "X-MCAP-Samples": "16000",
                                                              "X-MCAP-Lang": "ko", "X-MCAP-Idem": "smoke-1"})
        self.assertEqual(json.loads(conn.getresponse().read()), answer)
        self.assertEqual(len(self.backend.calls), 1)

        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)                     # a request body that is far too large: the
        try:                                                                                 # server answers before it reads the body
            conn.request("POST", "/v1/chunk", body=b"\x01\x02" * 1_500_000, headers={
                **auth, "Content-Type": "application/octet-stream", "X-MCAP-Samples": "1500000"})
        except (BrokenPipeError, ConnectionError):
            pass                                                # the send failed because the server already hung up: the answer is still there
        try:
            status = conn.getresponse().status
        except (ConnectionError, http.client.HTTPException):
            status = None                                       # a reset before the status arrived is what the client's guard tolerates too
        self.assertIn(status, (413, None))
        self.assertEqual(len(self.backend.calls), 1)

        head = (f"POST /v1/chunk HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {tok}\r\nX-MCAP-Proto: mcap-asr/1\r\nTransfer-Encoding: chunked\r\n"
                f"Content-Type: application/octet-stream\r\nX-MCAP-Samples: 4\r\n\r\n4\r\nabcd\r\n0\r\n\r\n").encode()
        self.assertEqual(self.raw(port, head)[0], 400)
        self.assertEqual(self.raw(port, b"GET /v1/health HTTP/1.1\r\nX-MCAP-Proto: mcap-asr/1\r\nExpect: 100-continue\r\n\r\n")[0], 400)
        self.assertEqual(len(self.backend.calls), 1)
        self.assertEqual(self.state.quotas.inflight[tok.split("_")[1]], 0)

    def test_tls_1_2_or_newer_with_a_private_certificate(self):
        paths = write_test_pki(self.root / "pki", "a")
        os.chmod(paths["key"], 0o600)
        state = self.make_state(tls_cert=str(paths["cert"]), tls_key=str(paths["key"]))
        port = self.serve(state)
        tok = self.token("mic", state=state)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=TEST_PKI["a"]["cert"])
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        request = f"GET /v1/health?detail=1 HTTP/1.1\r\nHost: asr-a.test\r\nAuthorization: Bearer {tok}\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n".encode()
        status, headers, body = self.raw(port, request, context, paths["host"])
        self.assertEqual((status, json.loads(body)["engine"]), (200, "whisper"))
        wrong = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)                                      # another CA: the handshake must fail
        wrong.load_verify_locations(cadata=TEST_PKI["b"]["cert"])
        with self.assertRaises(ssl.SSLError):
            self.raw(port, request, wrong, paths["host"])
        plain = socket.create_connection(("127.0.0.1", port), timeout=10)                    # plaintext on a TLS port gets no answer
        self.addCleanup(plain.close)
        plain.sendall(b"GET /v1/health HTTP/1.1\r\nX-MCAP-Proto: mcap-asr/1\r\n\r\n")
        plain.settimeout(10)
        try:
            data = plain.recv(100)
        except OSError:
            data = b""
        self.assertNotIn(b"200 OK", data)

    def test_the_real_egress_guard_and_https_transport_talk_to_it(self):
        """The client side of the wire as W3 built it (EgressGuard + HttpsTransport, private CA bound by hash, TLS 1.2+) against this
        server: what the future remote engine sends is what the server accepts, and an early refusal is heard."""
        paths = write_test_pki(self.root / "pki", "a")
        os.chmod(paths["key"], 0o600)
        state = self.make_state(tls_cert=str(paths["cert"]), tls_key=str(paths["key"]))
        port = self.serve(state)
        tok = self.token("mic", state=state)
        rule = HostRule(host=paths["host"], port=port, ca_pem_sha256=hashlib.sha256(paths["cert"].read_bytes()).hexdigest(),
                        ca_file=str(paths["cert"]))
        guard = EgressGuard({paths["host"]: rule}, engine_id="remote", consent_id="org:test", secrets=lambda: (tok,), trust="private")
        base = f"https://{paths['host']}:{port}"
        counter = iter(range(1, 100))

        def headers(**extra):
            return {"Authorization": f"Bearer {tok}", "X-MCAP-Proto": S.PROTO, "X-MCAP-Idem": f"00000000-0000-4000-8000-{next(counter):012d}", **extra}

        def connect(address, timeout=None, source_address=None, *args, **kwargs):          # the test name resolves to the loopback server only
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout if isinstance(timeout, (int, float)) else 10)
            sock.connect(("127.0.0.1", address[1]))
            return sock

        with mock.patch.object(socket, "create_connection", connect):
            health = guard.request("GET", base + "/v1/health?detail=1", headers=headers(), path_label="health")
            self.assertEqual((health.status, json.loads(health.body)["engine"]), (200, "whisper"))
            vocab = {"terms": ["PACS"]}
            put = guard.request("PUT", f"{base}/v1/vocab/{S.canonical_vocab_digest(vocab)}", headers=headers(), body=S._dumps(vocab),
                                path_label="vocab")
            self.assertEqual(put.status, 204)
            chunk = guard.request("POST", base + "/v1/chunk", body=pcm(16000), path_label="chunk", headers=headers(**{
                "Content-Type": "application/octet-stream", "X-MCAP-Samples": "16000", "X-MCAP-Lang": "ko", "X-MCAP-Prompt": "list",
                "X-MCAP-Vocab": S.canonical_vocab_digest(vocab)}))
            self.assertEqual((chunk.status, json.loads(chunk.body)["text"]), (200, TEXT_CANARY))
            refused = guard.request("POST", base + "/v1/chunk", body=b"\x01\x02" * 1_000_000, path_label="chunk", headers=headers(**{
                "Content-Type": "application/octet-stream", "X-MCAP-Samples": "1000000"}))
            self.assertEqual(refused.status, 413)                                            # heard although the body was never read
            self.assertEqual(json.loads(refused.body)["error"]["code"], "payload_too_large")
            anonymous = guard.request("GET", base + "/v1/health?detail=1", headers={"X-MCAP-Proto": S.PROTO}, path_label="health")
            self.assertEqual(anonymous.status, 401)
            with self.assertRaises(EgressDenied):                                            # and the guard still refuses anything else
                guard.request("GET", f"https://other.test:{port}/v1/health", headers=headers(), path_label="health")
        self.assertEqual(len(self.backend.calls), 1)                                          # the refused chunk never reached the engine


if __name__ == "__main__":
    unittest.main()

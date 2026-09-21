#!/usr/bin/env python3
"""A real SMTP server, small enough to read, for proving the Mac's client.

`SmtpClient` speaks a protocol. Parity tests prove the RULES agree with
`lib/smtp-format.js`, and they cannot prove the conversation happens at all:
whether the STARTTLS framer upgrades the socket, whether AUTH LOGIN sends the
user before the password, whether the message body arrives whole and with its
dots doubled. Those need something on the other end of a socket.

So this is that — deliberately strict, because a permissive fake proves
nothing. It refuses anything out of order, records every line it was sent, and
prints the transcript as JSON on the port it was told to report on.

Usage:
    fake-smtp.py --mode starttls|implicit|nostarttls --transcript <path>

It prints one line to stdout — `READY <port>` — then serves exactly one
connection and writes the transcript as JSON.
"""

import argparse
import base64
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile

CRLF = "\r\n"


def self_signed(directory):
    """A certificate for `localhost`, made fresh and thrown away with the test."""
    key = os.path.join(directory, "key.pem")
    cert = os.path.join(directory, "cert.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", "/CN=localhost",
         "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
        check=True, capture_output=True)
    return cert, key


class Conversation:
    """One connection, and everything said on it."""

    def __init__(self, sock, mode, cert, key):
        self.sock = sock
        self.mode = mode
        self.cert = cert
        self.key = key
        self.said = []          # every line the client sent
        self.body = None        # the DATA payload, undotted by the client
        self.upgraded = False
        self.auth = None        # (user, password), each still base64
        self.buffer = b""

    # -- wire ------------------------------------------------------------

    def readline(self):
        while b"\r\n" not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\r\n", 1)
        return line.decode("utf-8", "replace")

    def write(self, text):
        self.sock.sendall((text + CRLF).encode())

    # -- the dialogue ----------------------------------------------------

    def greeting(self):
        self.write("220 fake.khayt.test ESMTP ready")

    def capabilities(self, encrypted):
        # Multi-line on purpose: a client that stops at the first CRLF never
        # sees STARTTLS, which is the exact bug the parity tests guard.
        self.write("250-fake.khayt.test")
        self.write("250-PIPELINING")
        if self.mode == "starttls" and not encrypted:
            self.write("250-STARTTLS")
        # LOGIN only: it is the one mechanism Khayt implements, and a
        # server advertising PLAIN would let a client pick a path this
        # app has no code for — which proves nothing either way.
        self.write("250-AUTH LOGIN")
        self.write("250 8BITMIME")

    def serve(self):
        if self.mode == "implicit":
            self.wrap()
        self.greeting()
        while True:
            line = self.readline()
            if line is None:
                return
            self.said.append(line)
            upper = line.upper()

            if upper.startswith("EHLO") or upper.startswith("HELO"):
                self.capabilities(self.upgraded or self.mode == "implicit")
            elif upper == "STARTTLS":
                if self.mode != "starttls":
                    self.write("502 Command not implemented")
                    continue
                self.write("220 Ready to start TLS")
                self.wrap()
                self.upgraded = True
            elif upper.startswith("AUTH LOGIN"):
                # RFC 4954 allows the username on the AUTH line itself; Khayt
                # does not use that form, but accepting it keeps this server
                # honest enough to be checked with a known-good client.
                initial = line[len("AUTH LOGIN"):].strip()
                if not initial:
                    self.write("334 " + base64.b64encode(b"Username:").decode())
                    initial = self.readline()
                    self.said.append(initial)
                self.write("334 " + base64.b64encode(b"Password:").decode())
                password = self.readline()
                self.said.append(password)
                self.auth = (initial, password)
                self.write("235 2.7.0 Authentication successful")
            elif upper.startswith("MAIL FROM"):
                self.write("250 2.1.0 Sender OK")
            elif upper.startswith("RCPT TO"):
                self.write("250 2.1.5 Recipient OK")
            elif upper == "DATA":
                self.write("354 End data with <CR><LF>.<CR><LF>")
                self.collect()
                self.write("250 2.0.0 Message accepted")
            elif upper == "QUIT":
                self.write("221 2.0.0 Bye")
                return
            elif upper == "RSET":
                self.write("250 2.0.0 OK")
            else:
                self.write("500 5.5.2 Unrecognised command")

    def collect(self):
        """Read to the lone dot, undoing the client's dot-stuffing as a real
        server does — so the transcript holds what the customer would read."""
        lines = []
        while True:
            line = self.readline()
            if line is None or line == ".":
                break
            lines.append(line[1:] if line.startswith("..") else line)
        self.body = CRLF.join(lines)

    def wrap(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, self.key)
        self.sock = context.wrap_socket(self.sock, server_side=True)
        self.buffer = b""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True,
                        choices=["starttls", "implicit", "nostarttls"])
    parser.add_argument("--transcript", required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as directory:
        cert, key = self_signed(directory)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        print("READY %d" % listener.getsockname()[1], flush=True)

        listener.settimeout(30)
        transcript = {"said": [], "body": None, "upgraded": False,
                      "auth": None, "error": None}
        try:
            sock, _ = listener.accept()
            sock.settimeout(30)
            talk = Conversation(sock, args.mode, cert, key)
            try:
                talk.serve()
            finally:
                transcript["said"] = talk.said
                transcript["body"] = talk.body
                transcript["upgraded"] = talk.upgraded
                transcript["auth"] = talk.auth
        except Exception as problem:            # noqa: BLE001 - reported, not raised
            transcript["error"] = "%s: %s" % (type(problem).__name__, problem)

        with open(args.transcript, "w") as out:
            json.dump(transcript, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

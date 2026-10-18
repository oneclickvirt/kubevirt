#!/usr/bin/env python3
"""Manual payload probe against an operator-configured disposable echo guest.

The guest must echo b'ocv:' + request on TCP and UDP. No SSH credentials,
source, guest logs, or endpoint addresses are printed in public Actions logs.
"""
import os
import secrets
import socket
import sys


def probe(host, ports):
    family = socket.AF_INET6 if ':' in host else socket.AF_INET
    failed = False
    for port in ports:
        try:
            with socket.socket(family, socket.SOCK_STREAM) as stream:
                stream.settimeout(8)
                stream.connect((host, port))
                payload = secrets.token_bytes(24)
                stream.sendall(payload)
                received = b''
                while len(received) < len(payload) + 4:
                    chunk = stream.recv(256)
                    if not chunk:
                        break
                    received += chunk
                if received != b'ocv:' + payload:
                    raise ValueError('payload mismatch')
            print(f'port={port} TCP payload=passed')
        except (OSError, ValueError) as error:
            print(f'port={port} TCP failed={type(error).__name__}')
            failed = True
        received = attempts = 0
        for _ in range(10):
            for _ in range(3):
                attempts += 1
                with socket.socket(family, socket.SOCK_DGRAM) as datagram:
                    datagram.settimeout(2)
                    payload = secrets.token_bytes(24)
                    try:
                        datagram.connect((host, port))
                        datagram.send(payload)
                        if datagram.recv(256) == b'ocv:' + payload:
                            received += 1
                            break
                    except OSError:
                        pass
        print(f'port={port} UDP payloads={received}/10 attempts={attempts}')
        failed |= received != 10
    return int(failed)


if __name__ == '__main__':
    host = os.environ.get('RUNTIME_PROBE_HOST', '').strip()
    try:
        socket.inet_pton(socket.AF_INET6 if ':' in host else socket.AF_INET, host)
        ports = [int(p) for p in os.environ.get('RUNTIME_PROBE_PORTS', '').split(',')]
        if not 1 <= len(ports) <= 12 or any(not 1 <= p <= 65535 for p in ports):
            raise ValueError('invalid port range')
    except (OSError, ValueError):
        sys.exit('A numeric host secret and 1-12 valid ports are required')
    sys.exit(probe(host, ports))

#!/usr/bin/env python3
"""Regression: permission-like UI blocking must not interrupt socket heartbeats."""
import os
import secrets
import subprocess
import sys
import time

interface, address = sys.argv[1:]
binary = os.path.abspath('.build/debug/EtherLink')
env = {**os.environ, 'ETHERLINK_TEST_KEY': secrets.token_hex(32)}
processes = []
try:
    server = subprocess.Popen([binary, '--probe', 'listen', interface, address, address],
        env={**env, 'ETHERLINK_PROBE_UI_STALL': '8'}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    processes.append(server)
    time.sleep(1)
    client = subprocess.Popen([binary, '--probe', 'connect', interface, address, address],
        env={**env, 'ETHERLINK_PROBE_HOLD': '12'}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    processes.append(client)
    output_server, _ = server.communicate(timeout=35)
    output_client, _ = client.communicate(timeout=35)
    print('SERVER (UI blocked for longer than the five-second watchdog):\n' + output_server)
    print('CLIENT:\n' + output_client)
    assert 'Pausing UI queue for 8.0 seconds' in output_server
    assert 'UI queue resumed' in output_server
    for output in [output_server, output_client]:
        assert 'PASS: authenticated heartbeats' in output
        assert 'Heartbeat timeout' not in output
        assert 'TLS handshake timed out' not in output
    assert server.returncode == 0 and client.returncode == 0
    print('PASS: TLS and heartbeats survive eight seconds of UI blocking')
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait()

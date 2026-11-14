#!/usr/bin/env python3
"""Two-process TLS role negotiation, with no input capture/injection or privacy grants."""
import os
import secrets
import subprocess
import sys
import time

interface, address = sys.argv[1:]
binary = os.path.abspath('.build/debug/EtherLink')
def run(listener_choice, connector_choice, source):
    env = {**os.environ, 'ETHERLINK_TEST_KEY': secrets.token_hex(32)}
    server = subprocess.Popen([binary, '--probe', 'listen', interface, address, address],
        env={**env, 'ETHERLINK_PROBE_ROLE_CHOICE': listener_choice}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    client = None
    try:
        time.sleep(1)
        client = subprocess.Popen([binary, '--probe', 'connect', interface, address, address],
            env={**env, 'ETHERLINK_PROBE_ROLE_CHOICE': connector_choice}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out_a, _ = server.communicate(timeout=30)
        out_b, _ = client.communicate(timeout=30)
        print('LISTENER:', out_a)
        print('CONNECTOR:', out_b)
        for output in (out_a, out_b):
            assert 'ROLE PROMPT SHOWN' in output
            assert 'PASS: authenticated heartbeats' in output
        assert f'ROLE CONFIRMED: {source}' in out_a
        assert f'ROLE CONFIRMED: {"RECEIVER" if source == "SOURCE" else "SOURCE"}' in out_b
        assert server.returncode == 0 and client.returncode == 0
    finally:
        for process in (server, client):
            if process is not None and process.poll() is None:
                process.terminate(); process.wait()

run('here', 'wait', 'SOURCE')
run('wait', 'here', 'RECEIVER')
run('here', 'here', 'SOURCE')
print('PASS: both prompts, selection from either screen, and simultaneous selections over TLS')

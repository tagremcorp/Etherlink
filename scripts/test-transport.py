#!/usr/bin/env python3
"""Two-process smoke tests on ONE Mac; does not certify a physical cable."""
import os
import secrets
import subprocess
import sys
import time

interface, address = sys.argv[1:]
binary = os.path.abspath('.build/debug/EtherLink')

def run_case(matching):
    key = secrets.token_hex(32)
    server = subprocess.Popen([binary, '--probe', 'listen', interface, address, address],
        env={**os.environ, 'ETHERLINK_TEST_KEY': key}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(1)
        binding = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(server.pid), '-iTCP:49277'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=5)
        print(binding.stdout)
        assert f'{address}:49277 (LISTEN)' in binding.stdout, 'listener must bind selected IPv4 only'
        assert '*:49277' not in binding.stdout, 'wildcard listener forbidden' 
        client = subprocess.run([binary, '--probe', 'connect', interface, address, address],
            env={**os.environ, 'ETHERLINK_TEST_KEY': key if matching else secrets.token_hex(32)},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=25)
        output, _ = server.communicate(timeout=25)
        print('MATCHING KEY' if matching else 'WRONG KEY')
        print('Server:', output)
        print('Client:', client.stdout)
        if matching:
            assert 'PASS: authenticated heartbeats' in client.stdout and 'PASS: authenticated heartbeats' in output
        else:
            assert 'PASS:' not in client.stdout and 'PASS:' not in output
            assert client.returncode != 0
    finally:
        if server.poll() is None:
            server.terminate()
            server.wait()

run_case(True)
run_case(False)


def recovery_case(delayed=False):
    key = secrets.token_hex(32)
    env = {**os.environ, 'ETHERLINK_TEST_KEY': key}
    processes = []
    def start(mode, reconnect=False):
        process = subprocess.Popen([binary, '--probe', mode, interface, address, address],
            env={**env, 'ETHERLINK_PROBE_RECONNECT': '1' if reconnect else '0'},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        processes.append(process)
        return process
    try:
        if delayed:
            client = start('connect')
            time.sleep(2)
            server = start('listen')
            server_output, _ = server.communicate(timeout=35)
            client_output, _ = client.communicate(timeout=35)
            assert 'PASS: authenticated heartbeats' in client_output and 'PASS: authenticated heartbeats' in server_output
            print('PASS: connecting before the listener is ready recovers without another click')
        else:
            first_server = start('listen')
            time.sleep(1)
            client = start('connect', reconnect=True)
            first_output, _ = first_server.communicate(timeout=25)
            assert 'PASS: authenticated heartbeats' in first_output
            second_server = start('listen')
            second_output, _ = second_server.communicate(timeout=35)
            client_output, _ = client.communicate(timeout=35)
            assert 'PASS: authenticated heartbeats' in second_output
            assert 'PASS: automatically reconnected' in client_output
            print('PASS: automatic reconnection after peer exit/restart')
        print(client_output)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait()

recovery_case(delayed=True)
recovery_case()

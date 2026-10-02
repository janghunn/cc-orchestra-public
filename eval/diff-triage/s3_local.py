#!/usr/bin/env python3
"""Optional task-owned local Choice scoring; no network client is imported here."""
import sys
sys.dont_write_bytecode = True

from contextlib import contextmanager
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import time

import triage_lib as lib


def policy():
    # Read assignments as data. Do not source or execute policy text.
    text = (lib.CLONE / 'jev-policy.conf').read_text(encoding='utf-8')
    values = {}
    for line in text.splitlines():
        match = re.fullmatch(r'\s*(JEV_LOCAL_[A-Z_]+)\s*=\s*(?:"([^"\n]*)"|([0-9]+))\s*(?:#.*)?', line)
        if match:
            values[match[1]] = match[2] if match[2] is not None else match[3]
    return values, text


def resources(out_dir=None):
    values, _ = policy()
    state = lib.load_common().state_dir()
    model = state / values['JEV_LOCAL_MODEL_PATH']
    socket = Path(out_dir or lib.default_out()).resolve() / 'llama.sock'
    reasons = []
    if not model.is_file():
        reasons.append('configured GGUF absent')
    if not shutil.which(values['JEV_LOCAL_SERVER_BIN']):
        reasons.append('llama-server unavailable')
    gpu = None
    try:
        result = subprocess.run(['nvidia-smi', '--query-gpu=index,memory.free',
                                 '--format=csv,noheader,nounits'], capture_output=True, text=True,
                                timeout=10, check=False)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                fields = [v.strip() for v in line.split(',')]
                if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit() and int(fields[1]) >= 12288:
                    gpu = fields[0]
                    break
    except (OSError, subprocess.TimeoutExpired):
        pass
    if gpu is None:
        reasons.append('GPU with at least 12288 MiB free unavailable')
    if os.path.lexists(socket):
        reasons.append('task socket already exists')
    return gpu, socket, reasons


def availability(out_dir=None):
    _, _, reasons = resources(out_dir)
    return not reasons, reasons


def launch_spec(chosen_gpu, out_dir):
    """Pure command/env/policy builder; creation and process ownership stay in server()."""
    if not re.fullmatch(r'\d+', str(chosen_gpu)):
        raise ValueError('invalid GPU index')
    out = Path(out_dir).resolve()
    values, original = policy()
    socket = out / 'llama.sock'
    if any(c in str(socket) for c in ('"', '\n', '\r')):
        raise ValueError('invalid task socket path')
    lines = [line for line in original.splitlines()
             if not re.match(r'\s*JEV_LOCAL_(GPU|SOCKET)\s*=', line)]
    lines += [f'JEV_LOCAL_GPU="{chosen_gpu}"', f'JEV_LOCAL_SOCKET="{socket}"']
    config = out / 'local-policy.conf'
    env = dict(os.environ, CC_ORCH_JEV_POLICY=str(config), PYTHONDONTWRITEBYTECODE='1')
    return {'argv': [str(lib.CLONE / 'bin/orch-jev-local'), 'serve'], 'env': env,
            'policy_path': config, 'policy_text': '\n'.join(lines) + '\n', 'socket': socket}


def local_module():
    loader = importlib.machinery.SourceFileLoader('diff_triage_orch_jev_local', str(lib.CLONE / 'bin/orch-jev-local'))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def stop_process(process):
    if process.poll() is None:
        try:
            os.kill(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=30)


@contextmanager
def server(spec, wait_seconds=120):
    """Own exactly one foreground server PID, including every startup/error path."""
    lib.ensure_out_dir(spec['socket'].parent)
    if os.path.lexists(spec['socket']):
        raise ValueError('task socket already exists')
    lib.write_private(spec['policy_path'], spec['policy_text'])
    process = None
    try:
        process = subprocess.Popen(spec['argv'], env=spec['env'], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + min(wait_seconds, 120)
        while True:
            if process.poll() is not None:
                raise RuntimeError('local server exited during startup')
            try:
                if stat.S_ISSOCK(spec['socket'].lstat().st_mode):
                    break
            except FileNotFoundError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError('local server startup timeout')
            time.sleep(.05)
        yield process
    finally:
        if process is not None:
            stop_process(process)
        if os.path.lexists(spec['socket']):
            spec['socket'].unlink()
        spec['policy_path'].unlink(missing_ok=True)


@contextmanager
def transport_session(out_dir=None):
    out = lib.ensure_out_dir(out_dir or lib.default_out())
    gpu, _, reasons = resources(out)
    if reasons:
        raise RuntimeError('; '.join(reasons))
    spec = launch_spec(gpu, out)
    module = local_module()
    values, _ = policy()
    timeout = int(values['JEV_LOCAL_TIMEOUT_SECONDS'])
    with server(spec):
        yield lambda payload: module.post_unix(spec['socket'], payload, timeout)


def run(input_bytes, transport=None, out_dir=None):
    if transport is None:
        with transport_session(out_dir) as client:
            return run(input_bytes, client)
    module = local_module()
    values, _ = policy()
    scores = {}
    for file in lib.input_files(input_bytes):
        prompt = ('A = yes, read this file first / B = no\n'
                  'Path: ' + file['path'] + '\nPatch:\n' + file['patch'][:12000]
                  + '\nAnswer with the letter of the best option only.')
        payload = {'model': module.alias(values['JEV_LOCAL_MODEL_DIGEST']),
                   'messages': [{'role': 'user', 'content': prompt}], 'max_tokens': 1,
                   'temperature': 0, 'logprobs': True, 'top_logprobs': 20,
                   'chat_template_kwargs': {'enable_thinking': False}}
        response = transport(payload)
        if response.get('model') != payload['model']:
            raise ValueError('local model identity mismatch')
        candidates = response['choices'][0]['logprobs']['content'][0]['top_logprobs']
        probs, _, _, _ = module.score_letters(candidates, ['A', 'B'])
        scores[file['path']] = probs['A']
    return scores

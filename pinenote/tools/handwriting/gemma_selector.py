"""Owned, loopback-only llama.cpp CPU process for constrained Gemma choices."""
import atexit
import json
from pathlib import Path
import resource
import socket
import subprocess
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


def request_body(state, question, options):
    prompt = state + '\n\n' + question + '\nChoices:\n' + '\n'.join(
        f'{key}: {text}' for key, text in options.items())
    prompt += '\nReturn only a JSON object with the selected candidate ID in "choice".'
    return dict(messages=[dict(role='user', content=prompt)], temperature=0, seed=0,
        max_tokens=32, cache_prompt=False, chat_template_kwargs=dict(enable_thinking=False),
        response_format=dict(type='json_schema', json_schema=dict(name='reading', strict=True,
            schema=dict(type='object', properties=dict(choice=dict(type='string', enum=list(options))),
                        required=['choice'], additionalProperties=False))))


def parse_answer(response, options):
    if len(response['choices']) != 1 or response['choices'][0]['finish_reason'] != 'stop':
        raise ValueError('incomplete Gemma answer')
    answer = json.loads(response['choices'][0]['message']['content'])
    if set(answer) != {'choice'} or answer['choice'] not in options:
        raise ValueError('Gemma returned an invalid choice')
    # Do not fabricate option probabilities from a deterministic generated ID.
    return dict(choice=answer['choice'], response=response)


class GemmaSelector:
    def __init__(self, weights, server, output, projector=None):
        self.log = (output / 'server.log').open('w')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.url = f'http://127.0.0.1:{port}'
        self.command = [str(server.resolve()), '-m', str(weights.resolve()),
            '--host', '127.0.0.1', '--port', str(port), '--offline', '-ngl', '0',
            '-t', '8', '-tb', '8', '-c', '4096', '-np', '1', '--cache-ram', '0',
            '--jinja', '--reasoning-budget', '0']
        if projector is not None:
            self.command.extend(['--mmproj', str(projector.resolve()), '--no-mmproj-offload'])
        self.process = subprocess.Popen(self.command, stdout=self.log, stderr=subprocess.STDOUT)
        atexit.register(self.close)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('llama-server exited; see server.log')
            try:
                if self.request('/health')['status'] == 'ok':
                    break
            except (URLError, TimeoutError):
                pass
            time.sleep(.2)
        else:
            raise TimeoutError('llama-server startup deadline')
        self.props = self.request('/props')
        (output / 'server-props.json').write_text(json.dumps(self.props, indent=2) + '\n')
        self.version = subprocess.check_output([str(server.resolve()), '--version'],
            text=True, stderr=subprocess.STDOUT).strip()
        self.source_files = [Path(__file__), server.resolve()]
        self.config = dict(command=self.command, thinking=False, temperature=0, max_tokens=32,
            prompt_cache=False, context_size=4096, output='JSON schema enum; no option probabilities')

    def request(self, path, body=None):
        request = Request(self.url + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'Content-Type': 'application/json'})
        with urlopen(request, timeout=120) as response:
            return json.load(response)

    def validate(self, state, question, options):
        body = request_body(state, question, options)
        prompt = self.request('/apply-template', dict(messages=body['messages'],
            chat_template_kwargs=body['chat_template_kwargs']))['prompt']
        tokens = self.request('/tokenize', dict(content=prompt, add_special=True, parse_special=True))['tokens']
        if len(tokens) + body['max_tokens'] > 4096:
            raise ValueError('question exceeds configured context')

    def evaluate(self, state, question, options):
        body = request_body(state, question, options)
        response = self.request('/v1/chat/completions', body)
        return dict(parse_answer(response, options), request=body)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()
        # This runner has only one inference child; report its RSS separately.
        return resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024

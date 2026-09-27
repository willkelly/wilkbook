"""Local CPU selector adapters; no downloads or model-specific prompt tuning."""
import importlib.metadata
import inspect
from pathlib import Path


class VonSelector:
    def __init__(self, weights):
        from von.backends.option_marker_backend import OptionMarkerBackend
        self.backend = OptionMarkerBackend(checkpoint_dir=str(weights.resolve()), device='cpu')
        self.model = self.backend._get_model()
        self.version = importlib.metadata.version('von-sdk')
        self.source_files = [Path(inspect.getfile(OptionMarkerBackend)), Path(inspect.getfile(type(self.model)))]
        self.config = dict(temperature=self.backend.temperature if hasattr(self.backend, 'temperature') else None)

    def validate(self, state, question, options):
        tokens = self.model.tokenizer(self.model.pack_sequence(state, question, list(options.values())))['input_ids']
        if len(tokens) > self.model.encoder.config.max_position_embeddings or tokens.count(self.model.mask_token_id) != len(options):
            raise ValueError('invalid packed question')

    def evaluate(self, state, question, options):
        from von.types import Choice
        return self.backend.evaluate_choice('reading', state,
            Choice(type='choice', instructions=question, criteria=options)).model_dump()


class LayaSelector:
    def __init__(self, weights):
        import laya
        from laya import Agent
        from laya import common
        self.backend = Agent(str(weights.resolve()), device='cpu', fast=False, compile=False)
        self.model = self.backend.model
        if self.backend.amp_enabled:
            raise ValueError('this comparison requires float32 CPU inference')
        self.version = laya.__version__
        self.source_files = [Path(inspect.getfile(Agent)), Path(inspect.getfile(common))]
        self.config = dict(checkpoint=self.backend.cfg, temperature=self.backend.temperature,
                           temperature_by_options=self.backend.temperature_by_options)

    def validate(self, state, question, options):
        from laya.common import build_sequence, encode_text, render_options
        q = dict(t='choice', ins=question, crit=options)
        tok = self.backend.tok
        # Compare the native packing with an unlimited budget to catch silent
        # state/head clipping. Also check the SDK's per-option 48-token cap.
        if any(len(encode_text(tok, ' ' + o, add_special_tokens=False)['input_ids']) > 48
               for o in render_options(q)):
            raise ValueError('option would be truncated')
        packed = build_sequence(tok, state, q, self.backend.cfg['max_len'], self.backend.cfg['head_max_len'])
        full = build_sequence(tok, state, q, 8192, 8192)
        if packed != full or len(packed[1]) != len(options):
            raise ValueError('question would be truncated')

    def evaluate(self, state, question, options):
        result = self.backend.predict(state, {'reading': dict(type='choice', instructions=question, criteria=options)})
        return dict(result['answers']['reading'], usage=result['usage'])

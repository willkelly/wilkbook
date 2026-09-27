"""Incremental KenLM character scorer, with explicit space/punctuation tokens."""
import math


def character_token(character):
    if len(character) != 1:
        raise ValueError('one Unicode character required')
    # Never confuse literal spaces, newlines or reserved KenLM symbols with
    # word delimiters or sentence markers in the character model's vocabulary.
    return f'U{ord(character):06X}'


class CharacterLM:
    def __init__(self, path):
        import kenlm
        self.kenlm = kenlm
        self.model = kenlm.Model(str(path))

    def start(self):
        state = self.kenlm.State()
        self.model.BeginSentenceWrite(state)
        return state

    def extend(self, state, character):
        next_state = self.kenlm.State()
        score = self.model.BaseScore(state, character_token(character), next_state)
        return next_state, score * math.log(10)

    def finish(self, state):
        return self.model.BaseScore(state, '</s>', self.kenlm.State()) * math.log(10)

"""Page-disjoint splits and explicit parameter policies for writer adaptation."""
import string

POLICIES = {'head': .001, 'last-layer': .0003, 'full': .0001}
SEEDS = (0, 1, 2)
MAX_EPOCHS = 25
PATIENCE = 5


def page_of(sample):
    number = int(sample)
    if not 1 <= number <= 19:
        raise ValueError('pilot expects the 19 qualified prose lines')
    return (number - 1) // 4


def split(samples, test_page):
    if test_page not in range(5) or len(set(samples)) != len(samples):
        raise ValueError('invalid fold or duplicate samples')
    validation_page = (test_page + 1) % 5
    groups = {name: [] for name in ('train', 'validation', 'test')}
    for sample in samples:
        page = page_of(sample)
        key = 'test' if page == test_page else 'validation' if page == validation_page else 'train'
        groups[key].append(sample)
    if not all(groups.values()):
        raise ValueError('empty split')
    return groups


def expanded_alphabet(original):
    if len(set(original)) != len(original) or any(len(c) != 1 for c in original):
        raise ValueError('invalid original alphabet')
    # Fixed printable ASCII vocabulary, independent of held-out labels. Appended
    # symbols become representable; that does NOT mean they have been learned.
    return list(original) + [c for c in string.printable[:95] if c not in original]


def trainable(name, policy, layers):
    if policy not in POLICIES:
        raise ValueError('unknown adaptation policy')
    if name.startswith('linear.'):
        return True
    if not name.startswith('lstm_stack.'):
        return False
    return policy == 'full' or (policy == 'last-layer' and f'_l{layers - 1}' in name)


def encode(text, alphabet):
    mapping = {c: i + 1 for i, c in enumerate(alphabet)}
    return [mapping[c] for c in text]  # fail visibly on an unrepresentable target


def greedy(log_probs, alphabet):
    previous, text = 0, []
    for token in log_probs.argmax(-1).tolist():
        if token and token != previous:
            text.append(alphabet[token - 1])
        previous = token
    return ''.join(text)

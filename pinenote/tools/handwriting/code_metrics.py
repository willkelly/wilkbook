"""Whitespace-sensitive block metrics; no formatting or syntax repair."""


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        current = [i]
        for j, right in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


def text_payload(text):
    """Remove one file/message terminator, never leading/inner whitespace."""
    if not isinstance(text, str):
        raise ValueError('missing code text')
    return text[:-2] if text.endswith('\r\n') else text.removesuffix('\n')


def aligned_lines(truth, prediction):
    """Minimum line edits, maximizing exact matches on ties."""
    a, b = truth.split('\n'), prediction.split('\n')
    table = [[None] * (len(b) + 1) for _ in range(len(a) + 1)]
    table[0][0] = (0, 0, [])
    for i in range(len(a) + 1):
        for j in range(len(b) + 1):
            if i == j == 0:
                continue
            choices = []
            if i and j:
                cost, negative_matches, path = table[i - 1][j - 1]
                match = a[i - 1] == b[j - 1]
                choices.append((cost + (not match), negative_matches - match,
                                path + [(a[i - 1], b[j - 1])]))
            if i:
                cost, matches, path = table[i - 1][j]
                choices.append((cost + 1, matches, path + [(a[i - 1], None)]))
            if j:
                cost, matches, path = table[i][j - 1]
                choices.append((cost + 1, matches, path + [(None, b[j - 1])]))
            table[i][j] = min(choices, key=lambda item: item[:2])
    cost, negative_matches, pairs = table[-1][-1]
    return dict(edits=cost, exact=-negative_matches, pairs=pairs)


def scores(rows):
    result = dict(blocks=len(rows), exact_blocks=0, characters=0, character_edits=0,
                  nonspace_characters=0, nonspace_edits=0, reference_lines=0,
                  line_edits=0, exact_aligned_lines=0, indentation_matches=0,
                  indentation_comparisons=0, missing_lines=0, extra_lines=0)
    for row in rows:
        truth, prediction = row['truth'], row['prediction']
        result['exact_blocks'] += truth == prediction
        result['characters'] += len(truth)
        result['character_edits'] += distance(truth, prediction)
        a, b = (''.join(c for c in text if not c.isspace()) for text in (truth, prediction))
        result['nonspace_characters'] += len(a)
        result['nonspace_edits'] += distance(a, b)
        result['reference_lines'] += len(truth.split('\n'))
        alignment = aligned_lines(truth, prediction)
        result['line_edits'] += alignment['edits']
        result['exact_aligned_lines'] += alignment['exact']
        for a, b in alignment['pairs']:
            if a is None:
                result['extra_lines'] += 1
            elif b is None:
                result['missing_lines'] += 1
            else:
                result['indentation_comparisons'] += 1
                result['indentation_matches'] += a[:len(a)-len(a.lstrip(' \t'))] == b[:len(b)-len(b.lstrip(' \t'))]
    result['cer'] = result['character_edits'] / result['characters'] if result['characters'] else None
    result['nonspace_cer'] = result['nonspace_edits'] / result['nonspace_characters'] if result['nonspace_characters'] else None
    return result

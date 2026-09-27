#!/usr/bin/env python3
import json
import unittest
from gemma_selector import request_body, parse_answer


class Gemma(unittest.TestCase):
    def test_choices_probabilities_and_order_survive_prompt(self):
        from focused_candidates import question_state
        span = dict(context='A ___ moved.', original='cot', options=[
            dict(text='cot', ctc_logp=-1), dict(text='cat', ctc_logp=-2)])
        for reverse in [False, True]:
            state, options = question_state(span, reverse)
            request = request_body(state, 'Which reading?', options)
            self.assertIn(state, request['messages'][0]['content'])
            self.assertEqual(request['response_format']['json_schema']['schema']['properties']['choice']['enum'], list(options))
            self.assertFalse(request['chat_template_kwargs']['enable_thinking'])
            self.assertFalse(request['cache_prompt'])

    def test_no_invented_truncated_or_extra_output(self):
        def response(content, reason='stop'):
            return dict(choices=[dict(finish_reason=reason, message=dict(content=content))])
        self.assertEqual(parse_answer(response('{"choice":"a"}'), {'a': 'cat'})['choice'], 'a')
        for value in [response('{"choice":"b"}'), response('{"choice":"a"}', 'length'),
                      response('{"choice":"a","text":"new"}'), response('not JSON')]:
            with self.subTest(value=value), self.assertRaises((ValueError, json.JSONDecodeError)):
                parse_answer(value, {'a': 'cat'})


if __name__ == '__main__':
    unittest.main()

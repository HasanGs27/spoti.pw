"""PC status HTTP tests: synthetic jobs and an ephemeral loopback server only."""
import copy
import http.client
import json
import re
import threading
import unittest
from http.server import ThreadingHTTPServer

from automatic_downloads import handler_for


class ReadOnlyQueue:
    def __init__(self):
        self.lock = threading.RLock()
        self.jobs, self.files = {}, {}
        self.submissions = 0

    def submit(self, request):
        self.submissions += 1
        raise AssertionError('The status page must never submit a job.')

    def snapshot(self, ident):
        with self.lock:
            return copy.deepcopy(self.jobs[ident])


class PCStatusTests(unittest.TestCase):
    def setUp(self):
        self.queue = ReadOnlyQueue()
        self.token = 'test-status-private-route-1234567'
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(self.queue, '127.0.0.1', 0, self.token))
        self.port = self.server.server_port
        self.origin = f'http://127.0.0.1:{self.port}'
        self.server.RequestHandlerClass = handler_for(self.queue, '127.0.0.1', self.port, self.token)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval':0.02}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def get(self, suffix, headers=None, private=True):
        path = '/' + self.token + suffix if private else suffix
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=3)
        try:
            connection.request('GET', path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def job(self, created, state='running', states=('ready', 'running', 'error', 'waiting'), complete=True):
        return {'id':f'{created:032x}', 'created':created, 'name':f'Demande {created}',
            'state':state, 'completeMetadata':complete,
            'url':'https://source.invalid/never-expose-this', 'request_id':'private-request-marker',
            'message':'An internal message with private details',
            'items':[{'state':state, 'id':'private-file-marker', 'source':'private-source-marker',
                'spotify':'private-track-marker'} for state in states]}

    def test_private_route_host_origin_and_query_checks(self):
        for suffix, headers, private in (
            ('/status', None, False),
            ('/wrong-token/status', None, False),
            ('/status?probe=1', None, True),
            ('/status#fragment', None, True),
            ('/status', {'Host':'elsewhere.invalid'}, True),
            ('/status', {'Origin':'https://elsewhere.invalid'}, True),
            ('/status', {'Origin':'null'}, True),
            ('/status', {'Origin':self.origin + '.invalid'}, True),
        ):
            with self.subTest(suffix=suffix, headers=headers):
                self.assertEqual(self.get(suffix, headers, private)[0], 404)
        self.assertEqual(self.get('/status', {'Origin':self.origin})[0], 200)
        self.assertEqual(self.get('/status')[0], 200)
        self.assertEqual(self.queue.submissions, 0)

    def test_status_is_bounded_recent_aggregate_without_private_fields(self):
        self.queue.jobs = {str(i):self.job(i) for i in range(12)}
        before = copy.deepcopy(self.queue.jobs)
        code, headers, payload = self.get('/status')
        data = json.loads(payload)
        self.assertEqual(code, 200)
        self.assertEqual(headers['Content-Type'], 'application/json; charset=utf-8')
        self.assertEqual(headers['Cache-Control'], 'no-store')
        self.assertEqual(headers['Referrer-Policy'], 'no-referrer')
        self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
        self.assertEqual(data['limit'], 10)
        self.assertEqual([job['name'] for job in data['jobs']], [f'Demande {i}' for i in range(11, 1, -1)])
        self.assertEqual(data['totals'], {'ready':10, 'active':10, 'failed':10})
        for job in data['jobs']:
            self.assertEqual({key:job[key] for key in ('total','ready','running','failed','waiting')},
                             {'total':4,'ready':1,'running':1,'failed':1,'waiting':1})
            self.assertEqual(job['label'], 'Préparation en cours')
            self.assertEqual(set(job), {'name','state','label','tone','total','ready','running','failed','waiting','completeMetadata'})
        for private in (self.token, 'private-', 'https://', 'internal message', 'source', 'request_id'):
            self.assertNotIn(private.encode(), payload)
        self.assertEqual(self.queue.jobs, before)
        self.assertEqual(self.queue.files, {})
        self.assertEqual(self.queue.submissions, 0)

    def test_incomplete_and_interrupted_states_are_not_false_success_or_activity(self):
        self.queue.jobs = {
            'new':self.job(3, state='complete', states=('ready', 'ready'), complete=False),
            'old':self.job(2, state='interrupted', states=('ready', 'running', 'waiting')),
            'queued':self.job(1, state='queued', states=()),
        }
        data = json.loads(self.get('/status')[2])
        partial, interrupted, queued = data['jobs']
        self.assertEqual(partial['label'], 'Titres accessibles prêts')
        self.assertEqual(partial['tone'], 'partial')
        self.assertFalse(partial['completeMetadata'])
        self.assertEqual(interrupted['running'], 0)
        self.assertEqual(interrupted['waiting'], 2)
        self.assertEqual(interrupted['label'], 'À relancer après redémarrage')
        self.assertEqual(queued['total'], 0)
        self.assertEqual(queued['label'], 'En attente')
        self.assertEqual(data['totals'], {'ready':3,'active':1,'failed':0})

    def test_page_is_french_self_contained_and_renders_untrusted_names_as_text(self):
        attack = '<img src=x onerror=alert(1)>'
        self.queue.jobs = {'one':self.job(1)}
        self.queue.jobs['one']['name'] = attack
        code, headers, payload = self.get('/')
        html = payload.decode('utf-8')
        self.assertEqual(code, 200)
        self.assertEqual(headers['Content-Type'], 'text/html; charset=utf-8')
        self.assertEqual(headers['X-Frame-Options'], 'DENY')
        self.assertIn('<html lang="fr">', html)
        self.assertIn('PC connecté', html)
        self.assertIn('flèche de téléchargement', html)
        self.assertIn('prêts sur le PC', html)
        self.assertIn('uniquement lorsqu’elle est visible', html)
        self.assertIn('textContent', html)
        self.assertIn("document.addEventListener('visibilitychange'", html)
        self.assertIn('if (document.hidden || request) return', html)
        self.assertIn('request.abort()', html)
        self.assertIn("redirect:'error'", html)
        self.assertNotIn('innerHTML', html)
        self.assertNotIn('setInterval(', html)
        self.assertNotRegex(html, r'<(?:script|link|img)\b[^>]*(?:src|href)=')
        self.assertNotIn(attack, html)
        self.assertNotIn(self.token, html)
        nonce = re.search(r'<script nonce="([^"]+)"', html).group(1)
        self.assertIn(f"script-src 'nonce-{nonce}'", headers['Content-Security-Policy'])
        self.assertIn("connect-src 'self'", headers['Content-Security-Policy'])
        self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
        self.assertEqual(json.loads(self.get('/status')[2])['jobs'][0]['name'], attack)
        self.assertEqual(self.get('')[2], payload) # Both capability URL forms serve the same page.

    def test_empty_status_and_existing_hello_and_job_protocol_remain_available(self):
        self.assertEqual(json.loads(self.get('/status')[2]),
                         {'jobs':[],'limit':10,'totals':{'ready':0,'active':0,'failed':0}})
        self.assertEqual(json.loads(self.get('/hello')[2]), {'version':2,'service':'spoti-auto-downloads'})
        job = self.job(1)
        self.queue.jobs[job['id']] = job
        self.assertEqual(json.loads(self.get('/jobs/' + job['id'])[2]), job)
        self.assertEqual(self.get('/file/' + 'f' * 64)[0], 404)
        self.assertEqual(self.get('/hello', {'Origin':'https://elsewhere.invalid'})[0], 404)
        self.assertEqual(self.get('/')[0], 200)


if __name__ == '__main__':
    unittest.main()

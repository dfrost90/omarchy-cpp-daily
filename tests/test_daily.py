import importlib.util
import json
from datetime import datetime, timedelta
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('daily', Path(__file__).resolve().parents[1] / 'scripts/cpp_daily.py')
daily = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daily)


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        daily.DATA = Path(self.temp.name)
        daily.STATE = daily.DATA / 'progress.json'
        self.state = daily.fresh()
        self.state['track'] = 'returning'
        self.now = datetime(2026, 9, 29, 19, 30)

    def test_tracks_and_resume(self):
        self.assertEqual(len(daily.curriculum(self.state)), 16)
        self.assertEqual(daily.recommend(self.state, '2026-09-29'), 'initialization')
        daily.rate(self.state, 'initialization', 'good', self.now)
        self.assertEqual(daily.recommend(self.state, '2026-09-29'), 'division')
        self.assertEqual(daily.recommend(self.state, '2026-10-02'), 'initialization')
        self.state['track'] = 'beginner'
        self.assertEqual(len(daily.curriculum(self.state)), 18)
        self.assertEqual(daily.snapshot(self.state, self.now)['completed'], 1)

    def test_review_spacing_and_streak(self):
        daily.rate(self.state, 'initialization', 'good', self.now)
        daily.rate(self.state, 'initialization', 'good', self.now)
        self.assertEqual(self.state['records']['initialization']['interval'], 3)
        self.assertEqual(len(self.state['activity']), 1)
        daily.rate(self.state, 'division', 'again', self.now + timedelta(days=1))
        self.assertEqual(daily.snapshot(self.state, self.now + timedelta(days=1))['streak'], 2)
        self.assertEqual(daily.snapshot(self.state, self.now + timedelta(days=2))['streak'], 2)
        self.assertEqual(daily.snapshot(self.state, self.now + timedelta(days=3))['streak'], 0)
        self.assertEqual(self.state['records']['division']['due'], '2026-10-01')

    def test_reminder_once_daily_after_time(self):
        self.assertTrue(daily.should_remind(self.state, self.now, True, '19:00'))
        self.assertFalse(daily.should_remind(self.state, self.now, True, '20:00'))
        self.assertFalse(daily.should_remind(self.state, self.now, False, '19:00'))
        self.state['reminded'] = '2026-09-29'
        self.assertFalse(daily.should_remind(self.state, self.now, True, '19:00'))
        self.state['reminded'] = None
        self.state['snooze'] = (self.now + timedelta(hours=1)).timestamp()
        self.assertFalse(daily.should_remind(self.state, self.now, True, '19:00'))
        self.assertTrue(daily.should_remind(self.state, self.now + timedelta(hours=1), True, '19:00'))
        self.state['snooze'] = None
        daily.rate(self.state, 'division', 'good', self.now)
        self.assertFalse(daily.should_remind(self.state, self.now, True, '19:00'))

    def test_atomic_persistence_and_corruption_preservation(self):
        with daily.transaction() as state:
            state['track'] = 'returning'
        with daily.transaction() as state:
            self.assertEqual(state['track'], 'returning')
        daily.STATE.write_text('broken')
        with self.assertRaises(ValueError):
            with daily.transaction():
                pass
        self.assertEqual(daily.STATE.read_text(), 'broken')

    def test_prepare_never_overwrites_answer(self):
        task = daily.BY_ID['division']
        folder = daily.prepare(task)
        (folder / 'answer.cpp').write_text('// my work')
        daily.prepare(task)
        self.assertEqual((folder / 'answer.cpp').read_text(), '// my work')

    def test_solution_not_in_snapshot(self):
        self.assertNotIn('solution', daily.snapshot(self.state, self.now)['task'])

    def test_every_solution_passes_and_starters_fail(self):
        for task in daily.TASKS:
            with self.subTest(task=task['id']):
                folder = daily.prepare(task)
                passed, message = daily.check(task, folder)
                self.assertFalse(passed, 'Starter should require work')
                (folder / 'answer.cpp').write_text(task['solution'])
                passed, message = daily.check(task, folder)
                self.assertTrue(passed, message)

    def test_runtime_timeout(self):
        task = daily.BY_ID['division']
        folder = daily.prepare(task)
        (folder / 'answer.cpp').write_text('double seconds(int) { while(true) {} }')
        passed, message = daily.check(task, folder)
        self.assertFalse(passed)
        self.assertIn('Timed out', message)


if __name__ == '__main__':
    unittest.main()

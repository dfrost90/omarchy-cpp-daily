import importlib.util
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
import tempfile
import unittest
from unittest import mock

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
        self.assertEqual(len(daily.curriculum(self.state)), 98)
        self.assertEqual(daily.recommend(self.state, '2026-09-29'), 'initialization')
        daily.rate(self.state, 'initialization', 'good', self.now)
        self.assertEqual(daily.recommend(self.state, '2026-09-29'), 'division')
        self.assertEqual(daily.recommend(self.state, '2026-10-02'), 'initialization')
        self.state['track'] = 'beginner'
        self.assertEqual(len(daily.curriculum(self.state)), 100)
        self.assertEqual(daily.snapshot(self.state, self.now)['completed'], 1)

    def test_catalog_integrity(self):
        self.assertEqual(len(daily.TASKS), 100)
        self.assertEqual(len(daily.BY_ID), 100)
        for task in daily.TASKS:
            with self.subTest(task=task['id']):
                self.assertRegex(task['id'], r'^[a-z0-9-]+$')
                for field in ('topic', 'title', 'prompt', 'hints', 'explanation', 'starter', 'solution', 'tests'):
                    self.assertTrue(task[field], field)
                self.assertTrue(task['url'].startswith('https://www.learncpp.com/cpp-tutorial/'))
                self.assertNotRegex(task['explanation'], r'(?i)\b(javascript|typescript|JS|PHP|react)\b')

    def test_existing_completion_survives_expansion(self):
        self.state['selected'] = 'division'
        daily.rate(self.state, 'initialization', 'good', self.now)
        before = json.dumps(self.state, sort_keys=True)
        report = daily.snapshot(self.state, self.now)
        self.assertEqual((report['completed'], report['total'], report['catalogTotal']), (1, 98, 100))
        self.assertEqual(report['task']['id'], 'division')
        self.assertFalse(report['nextAvailable'])
        self.assertEqual(json.dumps(self.state, sort_keys=True), before)

    def test_finished_catalog_waits_for_due_reviews(self):
        for task in daily.curriculum(self.state):
            daily.rate(self.state, task['id'], 'good', self.now)
        self.state['selected'] = daily.curriculum(self.state)[-1]['id']
        report = daily.snapshot(self.state, self.now)
        self.assertTrue(report['allPracticed'])
        self.assertFalse(report['nextAvailable'])
        self.assertIsNone(daily.recommend(self.state, '2026-09-29'))
        self.assertEqual(report['task']['id'], self.state['selected'])
        self.assertEqual(daily.recommend(self.state, '2026-10-02'), 'initialization')
        self.assertTrue(daily.snapshot(self.state, self.now + timedelta(days=3))['nextAvailable'])

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

    def test_prepare_preserves_existing_readme_and_hardlinks(self):
        task = daily.BY_ID['division']
        folder = daily.prepare(task)
        notes = folder / 'README.md'
        notes.write_text('My notes')
        other = daily.DATA / 'other.txt'
        os.link(notes, other)
        daily.prepare(task)
        self.assertEqual(notes.read_text(), 'My notes')
        self.assertEqual(other.read_text(), 'My notes')

    def test_prepare_refuses_symlinks_and_nonregular_collisions(self):
        task = daily.BY_ID['division']
        for name in ('answer.cpp', 'README.md'):
            for kind in ('symlink', 'dangling', 'directory', 'fifo'):
                with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as temp:
                    daily.DATA = Path(temp)
                    folder = daily.DATA / 'exercises' / task['id']
                    folder.mkdir(parents=True)
                    victim = daily.DATA / 'victim'
                    if kind != 'dangling':
                        victim.write_text('keep me')
                    collision = folder / name
                    if kind in ('symlink', 'dangling'):
                        collision.symlink_to(victim)
                    elif kind == 'directory':
                        collision.mkdir()
                    else:
                        os.mkfifo(collision)
                    with self.assertRaises((ValueError, OSError)):
                        daily.prepare(task)
                    if kind == 'dangling':
                        self.assertFalse(victim.exists())
                    else:
                        self.assertEqual(victim.read_text(), 'keep me')
                    self.assertEqual([p.name for p in folder.iterdir()], [name])

    def test_prepare_refuses_symlink_directories(self):
        task = daily.BY_ID['division']
        outside = daily.DATA / 'outside'
        outside.mkdir()
        (daily.DATA / 'exercises').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            daily.prepare(task)
        self.assertEqual(list(outside.iterdir()), [])
        (daily.DATA / 'exercises').unlink()
        (daily.DATA / 'exercises').mkdir()
        (daily.DATA / 'exercises' / task['id']).symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            daily.prepare(task)
        self.assertEqual(list(outside.iterdir()), [])

    def test_atomic_create_refuses_destination_race(self):
        victim = daily.DATA / 'victim'
        victim.write_text('keep me')
        real_link = os.link
        def raced_link(source, target, **kwargs):
            os.symlink(str(victim), target, dir_fd=kwargs['dst_dir_fd'])
            return real_link(source, target, **kwargs)
        with daily.directory_fd(daily.DATA) as fd:
            with mock.patch.object(daily.os, 'link', side_effect=raced_link):
                with self.assertRaises(ValueError):
                    daily.create_exercise_file(fd, 'README.md', 'new instructions')
        self.assertEqual(victim.read_text(), 'keep me')
        self.assertTrue((daily.DATA / 'README.md').is_symlink())
        self.assertEqual(list(daily.DATA.glob('.cpp-daily-*')), [])

    def test_failed_write_leaves_no_partial_file(self):
        with daily.directory_fd(daily.DATA) as fd:
            with mock.patch.object(daily.os, 'fsync', side_effect=OSError('write failed')):
                with self.assertRaises(OSError):
                    daily.create_exercise_file(fd, 'answer.cpp', 'partial')
        self.assertEqual(list(daily.DATA.iterdir()), [])

    def test_checker_refuses_link_and_fifo_answers(self):
        folder = daily.DATA / 'exercise'
        folder.mkdir()
        victim = daily.DATA / 'victim'
        victim.write_text('private contents')
        answer = folder / 'answer.cpp'
        answer.symlink_to(victim)
        with self.assertRaises(OSError):
            daily.copy_answer(folder, daily.DATA / 'copy.cpp')
        answer.unlink()
        os.mkfifo(answer)
        with self.assertRaises(ValueError):
            daily.copy_answer(folder, daily.DATA / 'copy.cpp')
        self.assertFalse((daily.DATA / 'copy.cpp').exists())

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

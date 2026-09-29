#!/usr/bin/env python3
"""Local learning state and explicit compiler checks. No network requests."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TASKS = json.loads((ROOT / 'content/tasks.json').read_text())
BY_ID = {t['id']: t for t in TASKS}
DATA = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'cpp-daily'
STATE = DATA / 'progress.json'


def fresh():
    return dict(version=1, track=None, selected=None, records={}, activity=[], reminded=None, snooze=None)


@contextmanager
def transaction():
    DATA.mkdir(parents=True, exist_ok=True)
    with (DATA / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(STATE.read_text()) if STATE.exists() else fresh()
        if not isinstance(state, dict) or state.get('version') != 1 or not isinstance(state.get('records'), dict) or not isinstance(state.get('activity'), list):
            raise ValueError('Unrecognized progress file. Back it up before repairing it; it has not been overwritten.')
        yield state
        fd, name = tempfile.mkstemp(dir=DATA, prefix='.progress-')
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(state, out, indent=2)
                out.flush()
                os.fsync(out.fileno())
            os.replace(name, STATE)
        finally:
            if os.path.exists(name):
                os.unlink(name)


def curriculum(state):
    return [t for t in TASKS if state['track'] != 'returning' or not t['beginnerOnly']]


def recommend(state, today):
    tasks = curriculum(state)
    due = [t for t in tasks if state['records'].get(t['id'], {}).get('due', '9999') <= today]
    if due:
        return min(due, key=lambda t: state['records'][t['id']]['due'])['id']
    return next((t['id'] for t in tasks if not state['records'].get(t['id'], {}).get('completed')), tasks[0]['id'])


def snapshot(state, now=None):
    now = now or datetime.now().astimezone()
    today = now.date().isoformat()
    tasks = curriculum(state)
    selected = state.get('selected')
    if selected not in [t['id'] for t in tasks]:
        selected = recommend(state, today)
    task = dict(BY_ID[selected])
    task.pop('solution')  # only returned by the explicit reveal action
    task.pop('tests')
    dates = set(state['activity'])
    day = now.date() if today in dates else now.date() - timedelta(days=1)
    streak = 0
    while day.isoformat() in dates:
        streak += 1
        day -= timedelta(days=1)
    return dict(track=state['track'], task=task,
                record=state['records'].get(selected, {}),
                completed=sum(bool(state['records'].get(t['id'], {}).get('completed')) for t in tasks),
                total=len(tasks), streak=streak, todayDone=today in dates,
                due=sum(state['records'].get(t['id'], {}).get('due', '9999') <= today for t in tasks),
                workdir=str(DATA / 'exercises' / selected),
                history=[dict(id=t['id'], title=t['title'], completed=bool(state['records'].get(t['id'], {}).get('completed'))) for t in tasks])


def rate(state, task_id, confidence, now=None):
    now = now or datetime.now().astimezone()
    today = now.date().isoformat()
    old = state['records'].get(task_id, {})
    # Repeated button presses in one day never inflate spacing or activity.
    interval = 1 if confidence == 'again' else min(30, max(3, old.get('interval', 0) * 2))
    if old.get('reviewed') == today and confidence != 'again':
        interval = old.get('interval', interval)
    state['records'][task_id] = dict(old, completed=True, reviewed=today, interval=interval,
                                    due=(now.date() + timedelta(days=interval)).isoformat())
    if today not in state['activity']:
        state['activity'].append(today)


def prepare(task):
    folder = DATA / 'exercises' / task['id']
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / 'answer.cpp'
    if not source.exists():
        source.write_text('// C++ Daily — original practice exercise\n' + task['starter'])
    # Only managed instructions are refreshed. Learner code is never replaced.
    (folder / 'README.md').write_text(f"# {task['title']}\n\n{task['prompt']}\n\nReading: {task['url']}\n\nEdit answer.cpp, save, then use Check code in the widget.\nThe checker supplies main() and runs your code locally as your user.\nChecks cover behavior, not every style or explanation requirement.\n")
    return folder


def run_bounded(command, cwd, timeout):
    # File-backed output avoids unbounded RAM use; RLIMIT_FSIZE caps disk output.
    def limits():
        import resource
        resource.setrlimit(resource.RLIMIT_FSIZE, (2 * 1024 * 1024, 2 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryFile() as output:
        proc = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=output,
                                start_new_session=True, preexec_fn=limits)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            return False, f'Timed out after {timeout} seconds. Check for an infinite loop.'
        finally:
            # Also clean up children left behind by an exited practice program.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        output.seek(0)
        message = output.read(12000).decode(errors='replace')
        return code == 0, message


def check(task, folder=None):
    compiler = shutil.which('g++') or shutil.which('clang++')
    if not compiler:
        return False, 'No C++ compiler found. Install gcc or clang with the Omarchy package menu.'
    folder = folder or prepare(task)
    with tempfile.TemporaryDirectory(prefix='cpp-daily-check-') as temp:
        temp = Path(temp)
        # Copy the learner file so includes never require shell quoting.
        shutil.copyfile(folder / 'answer.cpp', temp / 'answer.cpp')
        (temp / 'check.cpp').write_text('#include <cassert>\n#include <cmath>\n#include <string>\n#include <type_traits>\n#include <initializer_list>\n#include "answer.cpp"\nint main() {\n' + task['tests'] + '\n}\n')
        passed, log = run_bounded([compiler, '-std=c++20', '-Wall', '-Wextra', '-Wpedantic', '-Wconversion', '-Wshadow', '-g', 'check.cpp', '-o', 'check'], temp, 30)
        if not passed:
            return False, 'Compilation needs attention:\n' + log
        passed, output = run_bounded([str(temp / 'check')], folder, 3)
        if not passed:
            return False, 'A check failed:\n' + output
        return True, 'All behavior checks passed. Review the explanation, then rate your confidence.' + ('\nCompiler warnings:\n' + log if log else '')


def should_remind(state, now, enabled, time):
    hour, minute = map(int, time.split(':'))
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ValueError('Reminder time must be HH:MM (00:00–23:59).')
    today = now.date().isoformat()
    return (enabled and state['track'] is not None and today not in state['activity']
            and state.get('reminded') != today
            and now.hour * 60 + now.minute >= hour * 60 + minute
            and (not state.get('snooze') or now.timestamp() >= state['snooze']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'track', 'select', 'next', 'start', 'check', 'solution', 'rate', 'snooze', 'tick'])
    parser.add_argument('value', nargs='?')
    parser.add_argument('--task', choices=list(BY_ID))
    parser.add_argument('--reminders', choices=['true', 'false'], default='false')
    parser.add_argument('--time', default='19:00')
    args = parser.parse_args()
    message = ''
    extra = {}
    with transaction() as state:
        task = BY_ID[args.task or snapshot(state)['task']['id']]
        now = datetime.now().astimezone()
        if args.action == 'track':
            if args.value not in ('beginner', 'returning'):
                raise ValueError('Choose beginner or returning.')
            state['track'] = args.value
            state['selected'] = recommend(state, now.date().isoformat())
        elif args.action == 'select':
            if args.value not in [t['id'] for t in curriculum(state)]:
                raise ValueError('Unknown task in this track.')
            state['selected'] = args.value
        elif args.action == 'next':
            state['selected'] = recommend(state, now.date().isoformat())
        elif args.action == 'start':
            folder = prepare(task)
            subprocess.Popen(['omarchy', 'launch', 'editor', str(folder / 'answer.cpp')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            message = 'Opened answer.cpp. Save your code, then choose Check code.'
        elif args.action == 'check':
            passed, message = check(task)
            extra['passed'] = passed
        elif args.action == 'solution':
            extra['solution'] = task['solution']
            message = 'One possible solution. Compare the reasoning with your own approach.'
        elif args.action == 'rate':
            if args.value not in ('again', 'good'):
                raise ValueError('Choose again or good.')
            rate(state, task['id'], args.value, now)
            message = 'Review saved. Choose Next task when you are ready.'
        elif args.action == 'snooze':
            state['snooze'] = now.timestamp() + 3600
            state['reminded'] = None
            message = 'Reminder postponed for one hour.'
        elif args.action == 'tick' and should_remind(state, now, args.reminders == 'true', args.time):
            result = subprocess.run(['notify-send', '--app-name=C++ Daily', 'A little C++ today?', 'Your next practice task is ready in the C++ bar widget.'], timeout=5, capture_output=True)
            if result.returncode == 0:
                state['reminded'] = now.date().isoformat()
        result = dict(snapshot(state), message=message, **extra)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError) as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)

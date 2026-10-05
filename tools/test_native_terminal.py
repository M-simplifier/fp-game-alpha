"""Actual POSIX shell/TTY checks for native interactive exec delegation.

Captured cancellation is tested separately. Windows retains its console/job
implementation and is exercised by the cross-platform native acceptance lane.
"""

import errno
import json
import os
import re
import select
import signal
import subprocess
import time


def terminal_checks(binary, project, require):
    if os.name != 'nt':
        job_control_checks(binary, project, require)


def job_control_checks(binary, project, require):
    """Use a real interactive shell: it must see and resume its own child job."""
    import pty
    import shlex
    import shutil
    import termios

    prompt = b'__FP_JOB_PROMPT__ '
    bash = shutil.which('bash')
    require('job-control-interactive-shell-present', bash is not None)

    class ShellFailure(AssertionError):
        pass

    class Shell:
        def __init__(self):
            self.pid, self.master = pty.fork()
            if self.pid == 0:
                os.environ.update(PS1=prompt.decode(), PS2='__FP_MORE__ ', TERM='dumb')
                os.execv(bash, [bash, '--noprofile', '--norc', '-i'])
            self.buffer = bytearray()
            self.transcript = bytearray()
            self.events = []
            self.case = 'unknown'
            self.command_number = 0
            self.groups = set()
            self.read_until(prompt)
            self.attributes = termios.tcgetattr(self.master)

        def read_until(self, marker):
            deadline = time.monotonic() + 20
            while marker not in self.buffer and time.monotonic() < deadline:
                if select.select([self.master], [], [], 0.05)[0]:
                    try:
                        part = os.read(self.master, 65536)
                    except OSError as problem:
                        if problem.errno != errno.EIO:
                            raise
                        part = b''
                    if not part:
                        break
                    self.buffer.extend(part)
                    self.transcript.extend(part)
            if marker not in self.buffer:
                raise AssertionError('shell did not return expected output: ' + repr(bytes(self.buffer)))
            end = self.buffer.index(marker) + len(marker)
            result = bytes(self.buffer[:end])
            del self.buffer[:end]
            return result

        def send(self, text):
            self.events.append({'time': time.monotonic(), 'send': text,
                                'foreground': os.tcgetpgrp(self.master)})
            os.write(self.master, text.encode())

        def command(self, text):
            # A job notification may redraw a prompt before this command runs.
            # Await its own completion line, not an arbitrary buffered prompt.
            self.command_number += 1
            marker = '__FP_COMMAND_' + str(self.command_number) + '__'
            self.send(text + "; printf '\\n" + marker + "\\n'\n")
            output = self.read_until(marker.encode() + b'\r\n')
            return output + self.read_until(prompt)

        def start(self, background=False):
            launch = ['sh', '-c', 'printf "__FP_NATIVE__%s\\n" "$$"; exec "$@"',
                      'sh', str(binary), 'run', '--project', str(project)]
            self.send(shlex.join(launch) + (' &\n' if background else '\n'))
            output = self.read_until(b'north/south/east/west, exit, look, save, load, new, quit')
            match = re.search(rb'__FP_NATIVE__(\d+)', output)
            if match is None:
                raise AssertionError('shell did not identify native job: ' + repr(output))
            native_group = int(match.group(1))
            self.groups.add(native_group)
            if background:
                return None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                group = os.tcgetpgrp(self.master)
                if group == native_group:
                    self.groups.add(group)
                    state = subprocess.run(['ps', '-p', str(native_group), '-o', 'args='],
                                           capture_output=True, text=True, timeout=3)
                    require('job-' + self.case + '-exec-preserves-shell-job-pid',
                            state.returncode == 0 and '--config-file=' in state.stdout
                            and '--offline' in state.stdout and ' run ' in state.stdout,
                            state.stdout + state.stderr)
                    return group
                time.sleep(0.01)
            raise AssertionError('game did not take its foreground terminal')

        def stopped(self, case, initially_background=False):
            output = b'' if initially_background else self.read_until(prompt)
            require('job-' + case + '-shell-regained-terminal',
                    os.tcgetpgrp(self.master) == self.pid, output.decode(errors='replace'))
            output = self.command("printf '__FP_JOB__'; jobs -p")
            match = re.search(rb'__FP_JOB__(\d+)', output)
            if initially_background and match is None:
                output += self.read_until(prompt)
                match = re.search(rb'__FP_JOB__(\d+)', output)
            require('job-' + case + '-shell-tracks-cli', match is not None,
                    output.decode(errors='replace'))
            job = int(match.group(1))
            self.groups.add(job)
            return job

        def acknowledge_stopped_job(self, job, case):
            # A background terminal read can race Bash's cached job state. Test
            # fg from an acknowledged stopped job, not a pending SIGCHLD update.
            # This is a kernel/shell handshake, not a timing-based sleep.
            os.killpg(job, signal.SIGSTOP)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                output = self.command("printf '__FP_STOPPED_JOB__'; jobs -s -p")
                match = re.search(rb'__FP_STOPPED_JOB__(\d+)', output)
                if match is not None and int(match.group(1)) == job:
                    require('job-' + case + '-shell-acknowledges-stopped-job', True)
                    return
            self.failure('shell did not acknowledge the stopped job', job, job)

        def foreground(self, child_group, native_group=None):
            self.send('fg\n')
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                current = os.tcgetpgrp(self.master)
                if current == child_group or (child_group is None and current not in {self.pid, native_group}):
                    self.groups.add(current)
                    return
                time.sleep(0.01)
            self.failure('fg did not return the terminal to the game', child_group, native_group)

        def failure(self, message, child_group=None, native_group=None):
            from pathlib import Path
            while select.select([self.master], [], [], 0)[0]:
                try:
                    part = os.read(self.master, 65536)
                except OSError:
                    break
                if not part:
                    break
                self.buffer.extend(part)
                self.transcript.extend(part)
            state = subprocess.run(['ps', '-axo', 'pid,ppid,pgid,tpgid,stat,args'],
                                   capture_output=True, text=True, timeout=3)
            owned = self.groups | {self.pid}
            processes = [line for line in state.stdout.splitlines()
                         if len(line.split(None, 5)) == 6 and line.split(None, 5)[2].lstrip('-').isdigit()
                         and int(line.split(None, 5)[2]) in owned]
            detail = {'case': self.case, 'message': message, 'shell': self.pid,
                      'native': native_group, 'child': child_group,
                      'foreground': os.tcgetpgrp(self.master), 'processes': processes,
                      'events': self.events,
                      'transcript': self.transcript.decode('utf-8', errors='replace')}
            output = Path(__file__).resolve().parents[1] / '.build/native-cli-logs/job-control-failure.json'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(detail, indent=2), encoding='utf-8')
            raise ShellFailure(message + '; diagnostic: ' + str(output) + '\n' + json.dumps(detail))

        def finished(self, case, expected):
            self.read_until(prompt)
            output = self.command("printf '__FP_STATUS__%s\\n' \"$?\"")
            match = re.search(rb'__FP_STATUS__(\d+)', output)
            actual = int(match.group(1)) if match is not None else None
            require('job-' + case + '-exit-code', actual is not None
                    and (actual != 0 if expected is None else actual == expected),
                    output.decode(errors='replace'))
            require('job-' + case + '-terminal-restored', os.tcgetpgrp(self.master) == self.pid)
            require('job-' + case + '-terminal-settings-restored',
                    termios.tcgetattr(self.master) == self.attributes)
            output = self.command("printf '__FP_JOBS__'; jobs -p")
            require('job-' + case + '-no-stopped-job-left',
                    re.search(rb'__FP_JOBS__(\d+)', output) is None, output.decode(errors='replace'))
            return actual

        def close(self):
            # These are only groups launched in this private PTY session.
            for group in self.groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
            os.close(self.master)

    for case in ['input', 'control-c', 'control-z-input', 'sigstop-resume-cancel', 'stopped-cancel', 'background-read', 'background-tty-stop', 'background-start']:
        shell = Shell()
        shell.case = case
        child_group = None
        job = None
        try:
            child_group = shell.start(background=case == 'background-start')
            if case in {'input', 'control-c'}:
                shell.send('look\nquit\n' if case == 'input' else '\x03')
                shell.finished(case, 0 if case == 'input' else 130)
                continue
            if case == 'sigstop-resume-cancel':
                os.killpg(child_group, signal.SIGSTOP)
            elif case != 'background-start':
                shell.send('\x1a')
            job = shell.stopped(case, initially_background=case == 'background-start')
            if case == 'stopped-cancel':
                # As with a normal stopped shell job, TERM is pending until
                # CONT permits it to run its cleanup. Do not put it in fg.
                shell.send('kill -TERM %+; kill -CONT %+\n')
                shell.read_until(prompt)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    output = shell.command("printf '__FP_RUNNING__'; jobs -p")
                    if re.search(rb'__FP_RUNNING__(\d+)', output) is None:
                        break
                    time.sleep(0.05)
                require('job-stopped-cancel-no-job-left',
                        re.search(rb'__FP_RUNNING__(\d+)', output) is None, output.decode(errors='replace'))
                require('job-stopped-cancel-did-not-steal-terminal', os.tcgetpgrp(shell.master) == shell.pid)
                require('job-stopped-cancel-settings-restored', termios.tcgetattr(shell.master) == shell.attributes)
                continue
            if case in {'background-read', 'background-tty-stop'}:
                shell.command('bg')
                if case == 'background-tty-stop':
                    # Exercise the kernel terminal-read stop explicitly, then
                    # foreground immediately, without a timing-based wait.
                    os.killpg(child_group, signal.SIGCONT)
                    os.killpg(child_group, signal.SIGTTIN)
                output = shell.command("printf '__FP_BACKGROUND__'; jobs -p")
                match = re.search(rb'__FP_BACKGROUND__(\d+)', output)
                require('job-' + case + '-keeps-shell-foreground',
                        os.tcgetpgrp(shell.master) == shell.pid
                        and match is not None and int(match.group(1)) == job,
                        output.decode(errors='replace'))
            if case in {'background-read', 'background-tty-stop', 'background-start'}:
                shell.acknowledge_stopped_job(job, case)
            shell.foreground(job, job)
            if case == 'sigstop-resume-cancel':
                # Cancel the shell job, as a terminal signal does. A signal to
                # Cabal's PID alone is not a process-tree termination contract.
                os.killpg(job, signal.SIGTERM)
                # Cabal owns cancellation status (baseline Linux Cabal returns
                # 1 here); normal explicit exit statuses are checked exactly.
                expected = None
            else:
                shell.send('look\nquit\n')
                expected = 0
            shell.finished(case, expected)
        except ShellFailure:
            raise
        except AssertionError as failure:
            shell.failure(str(failure), child_group, job)
        finally:
            shell.close()

    # A genuine exit 19 must never be mistaken for SIGSTOP 19. Use the actual
    # generated game's executable and restore its source before continuation.
    main = project / 'app/Main.hs'
    original = main.read_bytes()

    def rebuild():
        completed = subprocess.run([str(binary), 'build', '--project', str(project), '--json'],
                                   capture_output=True, text=True, timeout=120)
        if completed.returncode:
            raise AssertionError('job-control exit fixture build: ' + completed.stdout + completed.stderr)

    try:
        main.write_text('module Main where\nimport System.Exit\nmain :: IO ()\n'
                        'main = exitWith (ExitFailure 19)\n', encoding='utf-8')
        rebuild()
        shell = Shell()
        try:
            shell.send(shlex.join([str(binary), 'run', '--project', str(project)]) + '\n')
            shell.finished('genuine-exit19', 19)
        finally:
            shell.close()
    finally:
        main.write_bytes(original)
        rebuild()

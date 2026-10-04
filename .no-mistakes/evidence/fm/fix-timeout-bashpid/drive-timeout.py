import os, pathlib, subprocess, tempfile, time, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/purnakanagala/.no-mistakes/evidence/01M4283YJCPA09EHCC4AYMF046')
rows=[]
def run(name, script, lib, expected, limit=10):
    t=time.monotonic()
    p=subprocess.run(['/bin/bash','-uc',script,'_',str(lib)],capture_output=True,text=True,timeout=limit)
    row=dict(scenario=name,exit=p.returncode,stdout=p.stdout,stderr=p.stderr,elapsed_seconds=round(time.monotonic()-t,3))
    rows.append(row)
    assert p.returncode==expected, row
    return row
with tempfile.TemporaryDirectory(prefix='.timeout-live-',dir=root) as temp:
    d=pathlib.Path(temp)
    lib=root/'bin/fm-timeout-lib.sh'
    base=d/'base.sh'
    base.write_bytes(subprocess.check_output(['git','show','65e2aa443a42108689eee260a0d792608ec3540b:bin/fm-timeout-lib.sh']))
    script='unset BASHPID; . "$1"; fm_exec_timed 5 1 bash -c \'sleep 0.2; echo dispatched; echo diagnostic >&2; exit 7\''
    b=run('Before fix: unset BASHPID under nounset aborts',script,base,127)
    assert 'BASHPID: unbound variable' in b['stderr']
    for mode in ['direct','subshell']:
        s=script if mode=='direct' else 'unset BASHPID; . "$1"; (fm_exec_timed 5 1 bash -c \'sleep 0.2; echo dispatched; echo diagnostic >&2; exit 7\')'
        r=run('Unset BASHPID preserves output and status: '+mode,s,lib,7)
        assert r['stdout']=='dispatched\n' and r['stderr']=='diagnostic\n'
    for body,minimum in [('exec sleep 30',1),('trap "" TERM; exec sleep 30',2)]:
        r=run('Unset BASHPID enforces deadline: '+body,'unset BASHPID; . "$1"; (fm_exec_timed 1 1 bash -c \''+body+'\')',lib,124)
        assert minimum<=r['elapsed_seconds']<5
    for mode in ['default','unset']:
        for timing in ['startup','running']:
            pidfile=d/(mode+'-'+timing)
            script='set -u; '+('unset BASHPID; ' if mode=='unset' else '')+'. "$1"; ( '
            if timing=='startup':
                script+='while kill -0 "$$" 2>/dev/null; do sleep 0.02; done; '
            script+='fm_exec_timed 30 1 bash -c \'echo bounded-child-started; exec sleep 30\' ) & w=$!; echo "$w" > "$2"; '
            if timing=='running': script+='sleep 0.3; '
            script+='exit 0'
            t=time.monotonic()
            p=subprocess.Popen(['/bin/bash','-c',script,'_',str(lib),str(pidfile)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            p.wait(timeout=3)
            stdout,stderr=p.communicate(timeout=7)
            pid=int(pidfile.read_text())
            gone=False
            for _ in range(100):
                try: os.kill(pid,0)
                except ProcessLookupError: gone=True; break
                time.sleep(.02)
            row=dict(scenario=f'Owner dies {timing}, BASHPID {mode}',owner_exit=p.returncode,stdout=stdout,stderr=stderr,watchdog_pid=pid,watchdog_gone=gone,elapsed_seconds=round(time.monotonic()-t,3))
            rows.append(row)
            assert gone and row['elapsed_seconds']<7,row
(evidence/'live-transcript.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))

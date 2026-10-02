import subprocess, pathlib, time, json, os, signal
root=pathlib.Path.cwd(); lib=str(root/'bin/fm-timeout-lib.sh')
rows=[]
for shell in ['/bin/bash',str(root/'.test-timeout-tmp/bash-5.2.37/bash')]:
 version=subprocess.check_output([shell,'--version'],text=True).splitlines()[0]
 for name,cmd,expected in [('output-status','echo worker-started; echo worker-diagnostic >&2; exit 7',7),('deadline','exec sleep 20',124),('grace','trap "" TERM; exec sleep 20',124)]:
  start=time.monotonic()
  p=subprocess.run([shell,'-u','-c','. "$1"; fm_exec_timed 1 1 "$2" -c "$3"','_',lib,shell,cmd],capture_output=True,text=True,timeout=6)
  elapsed=time.monotonic()-start
  assert p.returncode==expected,(name,p)
  if name=='grace': assert elapsed>=2
  rows.append(dict(shell=version,scenario=name,status=p.returncode,elapsed_seconds=round(elapsed,3),stdout=p.stdout,stderr=p.stderr))
 owner=subprocess.Popen(['sleep','20'])
 env=dict(os.environ,FM_EXEC_TIMED_OWNER_PID=str(owner.pid))
 p=subprocess.Popen([shell,'-u','-c','. "$1"; fm_exec_timed 15 1 "$2" -c \'echo owner-command-started; exec sleep 20\'','_',lib,shell],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 ready=p.stdout.readline(); assert ready=='owner-command-started\n'
 start=time.monotonic(); owner.terminate(); owner.wait()
 out,err=p.communicate(timeout=5); elapsed=time.monotonic()-start
 assert p.returncode==143 and elapsed<5,(p.returncode,err)
 rows.append(dict(shell=version,scenario='explicit-owner-dies-before-deadline',owner_pid=owner.pid,status=p.returncode,elapsed_seconds=round(elapsed,3),stdout=ready+out,stderr=err))
path=pathlib.Path('/Users/purnakanagala/.no-mistakes/evidence/01M3Y4N4RA5GB2ETYWDE73CTSA/live-timeout-results.json')
path.write_text(json.dumps(rows,indent=2)+'\n'); print(path.read_text())

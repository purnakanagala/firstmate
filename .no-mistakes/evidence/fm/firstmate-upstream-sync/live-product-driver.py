import os, pathlib, subprocess, json, shutil, time, pty, fcntl, termios, struct, select, signal
r=pathlib.Path.cwd(); d=r/'.test-phase'; ev=pathlib.Path('/Users/purnakanagala/.no-mistakes/evidence/01M3X85D5GKR3K3MCW7N1RTWGT'); log=open(ev/'live-product.log','w')
env=os.environ.copy(); env.update(XDG_CONFIG_HOME='.test-phase/herdrroot',TMPDIR=str(d/'tmp'),PI_CODING_AGENT_DIR=str(d/'pi'),OPENAI_API_KEY='disposable-not-a-credential')
for k in ['HERDR_SOCKET_PATH','HERDR_SESSION','HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID']: env.pop(k,None)
def run(args, expected=0, extra=None):
 e=env.copy();e.update(extra or {}); p=subprocess.run(args,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n');log.flush();assert p.returncode==expected,p.stdout;return p.stdout
h=d/'live home'; (h/'bin/templates').mkdir(parents=True,exist_ok=True);(h/'config').mkdir(exist_ok=True);(h/'AGENTS.md').touch()
for f in ['fm-install-launcher.sh','herdr-min-protocol']: shutil.copy2(r/'bin'/f,h/'bin'/f)
shutil.copy2(r/'bin/templates/fm-launcher.command',h/'bin/templates/fm-launcher.command')
(h/'config/launcher.conf').write_text('model=openai/gpt-5.4\nthinking=low\npi_bin='+shutil.which('pi')+'\nquota_provider=codex\nworkspace_label=live-product\n')
dest=d/'installed launcher'; run(['/bin/bash',str(h/'bin/fm-install-launcher.sh'),str(dest)])
log.write((dest/'fm-launcher.conf').read_text()); log.write('modes='+oct((dest/'fm-launcher.command').stat().st_mode & 0o777)+','+oct((dest/'fm-launcher.conf').stat().st_mode & 0o777)+'\n')
quota=d/'quota-fixture';quota.write_text('#!/bin/bash\nprintf \'%s\\n\' \'{"providers":[{"source":"oauth","state":{"status":"fresh"},"quotaSemantics":{"status":"known"},"windows":[{"id":"weekly","kind":"weekly","percentRemaining":80}]}]}\'\n');quota.chmod(0o700)
env.update(FM_LAUNCHER_SESSION_OVERRIDE='fm-lab-real-pi',FM_LAUNCHER_QUOTA_BIN_OVERRIDE=str(quota))
run([str(dest/'fm-launcher.command'),'--check'])
run([str(dest/'fm-launcher.command'),'--dry-run'])
# Real interactive launcher and Herdr client; fix dimensions before child starts.
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
def session():
 os.setsid();fcntl.ioctl(0,termios.TIOCSCTTY,0)
p=subprocess.Popen([str(dest/'fm-launcher.command')],env=env,stdin=slave,stdout=slave,stderr=slave,preexec_fn=session);os.close(slave);raw=b''
try:
 end=time.monotonic()+12
 while time.monotonic()<end:
  if select.select([master],[],[],0.2)[0]:
   try: raw+=os.read(master,65536)
   except OSError:break
 run([str(dest/'fm-launcher.command'),'--check'])
 run(['herdr','agent','list','--session','fm-lab-real-pi'])
 journal=(h/'state/.fm-launcher-primary-identity').read_text();log.write('IDENTITY JOURNAL\n'+journal+'\n');log.flush()
 j=dict(x.split('=',1) for x in journal.splitlines() if '=' in x)
 run(['herdr','pane','process-info','--pane',j['pane_id'],'--session','fm-lab-real-pi'])
 run(['herdr','pane','read',j['pane_id'],'--session','fm-lab-real-pi'])
finally:
 (ev/'launcher-pty.ansi').write_bytes(raw)
 if p.poll() is None:os.killpg(p.pid,signal.SIGKILL)
 p.wait(timeout=10);os.close(master);(ev/'launcher-pty.ansi').write_bytes(raw)
 run(['herdr','session','stop','fm-lab-real-pi']);run(['herdr','session','delete','fm-lab-real-pi'])
log.close()

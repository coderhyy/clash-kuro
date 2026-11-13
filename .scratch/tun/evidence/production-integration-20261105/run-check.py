import json,subprocess,sys,time
from pathlib import Path
p=Path(__file__).parent
item=sys.argv[1]
settings=json.loads((p/'commands.json').read_text())
start=time.time()
with (p/(item+'.stdout.log')).open('w') as out, (p/(item+'.stderr.log')).open('w') as err:
    result=subprocess.run(settings['commands'][item],cwd=settings['cwd'],stdout=out,stderr=err)
(p/(item+'.result.json')).write_text(json.dumps({'command':settings['commands'][item],'exitCode':result.returncode,'elapsedSeconds':round(time.time()-start,3)},indent=2)+'\n')
print(item, 'exit', result.returncode)
print((p/(item+'.stdout.log')).read_text()[-5000:])
print((p/(item+'.stderr.log')).read_text()[-3000:])
sys.exit(result.returncode)

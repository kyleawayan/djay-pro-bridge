#!/usr/bin/env python3
"""Read an app bundle; save static evidence to a fresh system temporary directory."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shutil, struct, subprocess, tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=pathlib.Path)
p.add_argument('--objc', action='store_true', help='Save main executable Objective-C metadata and selector stubs per slice')
p.add_argument('--disassemble', action='store_true', help='Save main executable disassembly per slice; can produce hundreds of MB')
a = p.parse_args()
app = a.app.resolve(strict=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
out = pathlib.Path(tempfile.mkdtemp(prefix='djay-static-'))
os.chmod(out, 0o700)
if shutil.which('git') and subprocess.run(['git', '-C', str(out), 'rev-parse', '--show-toplevel'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
    out.rmdir()
    p.error('System temporary directory is inside a Git checkout; select a non-repository TMPDIR')
tools = {n: shutil.which(n) for n in ['file','plutil','shasum','codesign','strings','otool','nm','lipo','objdump','xcrun']}
(out/'tools.json').write_text(json.dumps(tools, indent=2))
def run(name, args, dest):
    if not tools.get(name):
        (out/dest).write_text('TOOL UNAVAILABLE: '+name+'\n'); return
    with (out/dest).open('w') as f:
        r = subprocess.run([tools[name], *args], stdout=f, stderr=subprocess.STDOUT)
        f.write('\nEXIT STATUS: '+str(r.returncode)+'\n')
exe = app/'Contents/MacOS'/info['CFBundleExecutable']
(out/'target.json').write_text(json.dumps({'app':str(app), 'executable':str(exe.relative_to(app)), 'version':info.get('CFBundleShortVersionString'), 'build':info.get('CFBundleVersion'), 'identifier':info.get('CFBundleIdentifier'), 'sha256':hashlib.sha256(exe.read_bytes()).hexdigest()}, indent=2))
run('codesign',['-dv','--verbose=4',str(app)],'signing.txt')
pattern = re.compile(rb'rane|system[ _-]?one|omni[ _-]?source|in[ _-]?music', re.I)
magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
inventory=[]; hits=[]; binaries=[]
for f in sorted(app.rglob('*')):
    if not f.is_file() or f.is_symlink(): continue
    rel=str(f.relative_to(app)); data=f.read_bytes(); inventory.append({'file':rel,'size':len(data)})
    spans=[]
    if data[:4] in magic:
        if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            for i in range(struct.unpack_from('>I',data,4)[0]):
                if data[:4] == b'\xca\xfe\xba\xbf':
                    cpu,sub,off,size,align,reserved=struct.unpack_from('>IIQQII',data,8+32*i)
                else:
                    cpu,sub,off,size,align=struct.unpack_from('>IIIII',data,8+20*i)
                spans.append((off,off+size,{0x1000007:'x86_64',0x100000c:'arm64'}.get(cpu,hex(cpu))))
        elif data[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
            cpu=struct.unpack_from('<I',data,4)[0]; spans=[(0,len(data),{0x1000007:'x86_64',0x100000c:'arm64'}.get(cpu,hex(cpu)))]
        ident=f'binary-{len(binaries):03d}'
        binaries.append({'id':ident,'file':rel,'sha256':hashlib.sha256(data).hexdigest(),'slices':spans})
        run('file',[str(f)],ident+'-file.txt')
        run('otool',['-arch','all','-l',str(f)],ident+'-loads.txt')
        run('otool',['-arch','all','-L',str(f)],ident+'-libraries.txt')
        run('nm',['-arch','all',str(f)],ident+'-symbols.txt')
        if f == exe:
            for _, _, arch in spans:
                if a.objc:
                    run('otool',['-arch',arch,'-ov',str(f)],ident+'-'+arch+'-objc.txt')
                    run('otool',['-arch',arch,'-v','-s','__TEXT','__objc_stubs',str(f)],ident+'-'+arch+'-stubs.txt')
                if a.disassemble:
                    run('otool',['-arch',arch,'-tvV',str(f)],ident+'-'+arch+'-disasm.txt')
    for m in pattern.finditer(data):
        start=max(data.rfind(b'\0',max(0,m.start()-180),m.start())+1,m.start()-180,0)
        end=data.find(b'\0',m.end(),m.end()+220)
        if end<0: end=min(len(data),m.end()+220)
        sl=next((s for s in spans if s[0]<=m.start()<s[1]),None)
        hits.append({'file':rel,'arch':sl[2] if sl else 'resource/unassigned','file_offset':hex(m.start()),'slice_offset':hex(m.start()-sl[0]) if sl else None,'excerpt':data[start:end].decode('utf-8',errors='replace')})
(out/'inventory.json').write_text(json.dumps(inventory,indent=2))
(out/'binaries.json').write_text(json.dumps(binaries,indent=2))
(out/'device-hits.json').write_text(json.dumps(hits,indent=2))
for f in (app/'Contents/Resources/MIDI Mappings').glob('*SYSTEM ONE*.djayMidiMapping'):
    try:
        decoded=plistlib.loads(f.read_bytes())
        (out/(f.name+'.json')).write_text(json.dumps(decoded,indent=2,default=str))
    except (ValueError, plistlib.InvalidFileException) as e:
        (out/(f.name+'.error.txt')).write_text(str(e))
print(out)
print(json.dumps({'files':len(inventory),'binaries':len(binaries),'device_hits':len(hits)}))

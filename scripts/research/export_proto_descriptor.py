#!/usr/bin/env python3
"""Export a FileDescriptorProto and reconstruct source outside Git; never publish it."""
import argparse
import json
from pathlib import Path
import subprocess
from summarize_probe import fields

TYPES = {1:'double',2:'float',3:'int64',4:'uint64',5:'int32',6:'fixed64',7:'fixed32',8:'bool',9:'string',12:'bytes',13:'uint32',15:'sfixed32',16:'sfixed64',17:'sint32',18:'sint64'}
def get(items, number, default=None): return next((v for n,w,v in items if n==number), default)
def repeated(items, number): return [v for n,w,v in items if n==number]
def text(value): return value.decode('utf-8')
def quote(value): return json.dumps(text(value))
def varint(value):
    out=bytearray()
    while value>127: out.append((value&127)|128); value>>=7
    out.append(value); return bytes(out)
def enum(data, indent=''):
    items=fields(data); lines=[indent+'enum '+text(get(items,1))+' {']
    for value in repeated(items,2):
        vs=fields(value); number=get(vs,2)
        if number >= 1<<63: number -= 1<<64
        lines.append(indent+'  '+text(get(vs,1))+' = '+str(number)+';')
    if set(n for n,w,v in items)-{1,2}: raise ValueError('Unsupported enum metadata; preserve raw descriptor')
    return lines+[indent+'}']
def message(data, indent=''):
    items=fields(data); fs=[fields(v) for v in repeated(items,2)]
    oneofs=[text(get(fields(v),1)) for v in repeated(items,8)]
    synthetic={get(f,9) for f in fs if get(f,17,0)}
    lines=[indent+'message '+text(get(items,1))+' {']
    for v in repeated(items,3): lines+=message(v,indent+'  ')
    for v in repeated(items,4): lines+=enum(v,indent+'  ')
    def field(f, pad):
        ty=get(f,5); type_name=text(get(f,6)) if ty in [11,14] else TYPES[ty]
        label='repeated ' if get(f,4)==3 else 'optional ' if get(f,17,0) else ''
        if set(n for n,w,v in f)-{1,3,4,5,6,9,17}: raise ValueError('Unsupported field metadata')
        return pad+label+type_name+' '+text(get(f,1))+' = '+str(get(f,3))+';'
    for f in fs:
        oi=get(f,9)
        if oi is None or oi in synthetic: lines.append(field(f,indent+'  '))
    for i,name in enumerate(oneofs):
        if i in synthetic: continue
        lines.append(indent+'  oneof '+name+' {')
        for f in fs:
            if get(f,9)==i: lines.append(field(f,indent+'    '))
        lines.append(indent+'  }')
    if set(n for n,w,v in items)-{1,2,3,4,8}: raise ValueError('Unsupported message metadata')
    return lines+[indent+'}']

def export_bytes(data, destination):
    destination.mkdir(parents=True,exist_ok=True)
    if subprocess.run(['git','-C',str(destination),'rev-parse','--show-toplevel'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
        raise ValueError('Export must stay outside Git')
    destination.chmod(0o700)
    items=fields(data)
    if set(n for n,w,v in items)-{1,2,3,4,5,8,12}:raise ValueError('Unsupported file metadata')
    name=text(get(items,1))
    if Path(name).name!=name:raise ValueError('Source filename must not contain a path')
    lines=['// Reconstructed from an embedded descriptor; original comments and formatting are unavailable.',
           'syntax = '+quote(get(items,12))+';', 'package '+text(get(items,2))+';', '']
    for dep in repeated(items,3):lines.append('import '+quote(dep)+';')
    options=fields(get(items,8,b''))
    for n,w,v in options:
        if n!=11:raise ValueError('Unsupported file option')
        lines.append('option go_package = '+quote(v)+';')
    for v in repeated(items,5):lines+=['']+enum(v)
    for v in repeated(items,4):lines+=['']+message(v)
    files={name:'\n'.join(lines).encode()+b'\n', 'original.descriptor.pb':data,
           'original.descriptorset.pb':b'\x0a'+varint(len(data))+data}
    for filename,content in files.items():
        path=destination/filename
        with path.open('xb') as handle:handle.write(content)
        path.chmod(0o600)
    print('Exported descriptor, descriptor set, and reconstructed .proto into '+str(destination))

def export(descriptor, destination):
    return export_bytes(descriptor.read_bytes(), destination)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('descriptor',type=Path);p.add_argument('destination',type=Path);a=p.parse_args()
    export(a.descriptor,a.destination)

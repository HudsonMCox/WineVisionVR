#!/usr/bin/env python3
"""Stage or verify the matching native OpenVR/OpenXR guest pair; never execute it."""
import argparse,hashlib,json,shutil,struct
from pathlib import Path
from verify_openvr_bundle import imports

FILES=('OpenComposite/bin/vrclient_x64.dll','wvr_openxr.dll')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def validate(root):
 root=Path(root)
 receipt=root/'AVPPLAY_LOCAL_BUILD_RECEIPT.json'
 if receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_size>65536:raise ValueError('missing/invalid native guest receipt')
 data=json.loads(receipt.read_text())
 if type(data.get('schemaVersion')) is not int or data.get('schemaVersion')!=1 or data.get('architecture')!='arm64ec':raise ValueError('native guest receipt architecture/version mismatch')
 for relative in FILES:
  path=root/relative
  if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):raise ValueError('native guest artifact is missing or unsafe: '+relative)
  dependencies=imports(path,0xa641)
  if set(dependencies)&{'libc++.dll','libc++abi.dll','libunwind.dll','libstdc++-6.dll'}:raise ValueError('native guest C++ runtime must be private/static')
  if data.get('filesSha256',{}).get(relative)!=digest(path):raise ValueError('native guest artifact hash mismatch: '+relative)
 return data

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--openvr',type=Path);p.add_argument('--openxr',type=Path);p.add_argument('--verify',action='store_true');a=p.parse_args()
 if not a.verify:
  if not a.openvr or not a.openxr:p.error('staging requires --openvr and --openxr')
  receipt={'schemaVersion':1,'architecture':'arm64ec','gameTested':False,'filesSha256':{}}
  for relative,source in zip(FILES,[a.openvr,a.openxr]):
   imports(source,0xa641)
   dest=a.output/relative;dest.parent.mkdir(parents=True,exist_ok=True)
   if source.resolve()!=dest.resolve():shutil.copy2(source,dest)
   receipt['filesSha256'][relative]=digest(dest)
  (a.output/'AVPPLAY_LOCAL_BUILD_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n')
 validate(a.output)
 print('ARM64EC OpenVR/OpenXR pair verified against its build receipt.')
if __name__=='__main__':
 try:main()
 except (ValueError,OSError,KeyError,TypeError,struct.error) as error:raise SystemExit('error: '+str(error))

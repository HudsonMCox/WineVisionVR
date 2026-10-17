#!/usr/bin/env python3
"""Production CPU hotpaths: input parity, allocation-free sync, pose equivalence."""
from pathlib import Path
import runpy,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
contract=runpy.run_path(str(root/'windows-vr-openxr/tests/test_input_contract.py'))
source=(root/'windows-vr-openxr/src/WindowsVROpenXR.cpp').read_text()
def function(signature):
 a=source.index(signature);b=source.index('{',a)+1;e=b;d=1
 while d:d+=(source[e]=='{')-(source[e]=='}');e+=1
 return source[a:e]
preamble=contract['preamble'].replace('struct ActionSet {Instance* instance;};','struct ActionSet {Instance* instance;std::vector<XrAction> actions;};').replace('std::vector<std::unique_ptr<Action>> actions;', 'std::vector<std::unique_ptr<Action>> actions;std::vector<std::unique_ptr<ActionSet>> actionSets;').replace('struct Session {Instance* instance;', 'struct Session {bool begun=true;Instance* instance;std::vector<XrActionSet> attachedActionSets;')
extra=r'''
#include <random>
#include <chrono>
#include <cstdlib>
#include <new>
#include <cstring>
size_t allocations=0;
void* operator new(size_t n){++allocations;if(auto*p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void operator delete(void*p) noexcept{std::free(p);}
void operator delete(void*p,size_t) noexcept{std::free(p);}
struct WVRFrameStateRequestV1 {WVRDXMTControllerV1 controllers[2];};
ActionSet*GetActionSet(XrActionSet s){return reinterpret_cast<ActionSet*>(s);}
bool GetSessionFrameState(Session*,WVRFrameStateRequestV1&r){r.controllers[0].trigger=.8;r.controllers[0].flags=7;return true;}
void ObserveSessionExitRequest(Session*,void*,void*,void*,WVRFrameStateRequestV1*){}
void CopyFrameController(const WVRDXMTControllerV1&a,WVRDXMTControllerV1&b){b=a;}
int GetSessionController(Session*,uint32_t,WVRDXMTControllerV1*){return -1;}
'''
math='\n'.join(function(x) for x in ['XrQuaternionf QuaternionFromMatrix(', 'XrPosef PoseFromMatrix(', 'void MultiplyColumnMajor(', 'void MatrixFromPose(', 'void InvertRigid(', 'bool IsUnitRotation(', 'XrQuaternionf MultiplyRotation(', 'XrVector3f RotatePosition(', 'XrPosef ComposePose(', 'XrPosef RelativePose('])
references=r'''
ActionValue ReferenceSampleAction(Action *action,uint32_t role,const WVRDXMTControllerV1 &controller) {
  ActionValue value{};
  value.lastChangeTime=static_cast<XrTime>(controller.timestampNanoseconds);
  if(action->type==XR_ACTION_TYPE_POSE_INPUT){value.boolean=(controller.flags&5u)==5u;return value;}
  Instance*instance=action->set->instance;
  bool hasFloatValue=false,hasVectorValue=false;
  for(XrPath bindingPath:action->bindingPaths){
    if(RoleForPath(instance,bindingPath)!=role)continue;
    auto path=instance->pathStrings.find(bindingPath);if(path==instance->pathStrings.end())continue;
    const std::string&name=path->second;
    if(action->type==XR_ACTION_TYPE_BOOLEAN_INPUT){
      const uint64_t bit=ButtonForBinding(name);
      if(bit)value.boolean=value.boolean||((controller.buttons&bit)!=0);
      else if(AnalogBinding(name,"trigger"))value.boolean=value.boolean||controller.trigger>=0.5f;
      else if(AnalogBinding(name,"squeeze")||AnalogBinding(name,"grip"))value.boolean=value.boolean||controller.grip>=0.5f;
    } else if(action->type==XR_ACTION_TYPE_FLOAT_INPUT){
      float candidate=0.0f;
      if(AnalogBinding(name,"trigger"))candidate=controller.trigger;
      else if(AnalogBinding(name,"squeeze")||AnalogBinding(name,"grip"))candidate=controller.grip;
      else if(name.find("/input/thumbstick/x")!=std::string::npos)candidate=controller.thumbstickX;
      else if(name.find("/input/thumbstick/y")!=std::string::npos)candidate=controller.thumbstickY;
      else {const uint64_t bit=ButtonForBinding(name);if(bit)candidate=(controller.buttons&bit)?1.0f:0.0f;else continue;}
      if(!hasFloatValue||std::fabs(candidate)>std::fabs(value.scalar))value.scalar=candidate;
      hasFloatValue=true;
    } else if(action->type==XR_ACTION_TYPE_VECTOR2F_INPUT&&name.find("/input/thumbstick")!=std::string::npos){
      const float magnitude=controller.thumbstickX*controller.thumbstickX+controller.thumbstickY*controller.thumbstickY;
      const float current=value.vector.x*value.vector.x+value.vector.y*value.vector.y;
      if(!hasVectorValue||magnitude>current)value.vector={controller.thumbstickX,controller.thumbstickY};
      hasVectorValue=true;
    }
  }
  return value;
}
bool ReferenceActionHasBindingForRole(Action *action, uint32_t role) {
  if (!action || !action->set || !action->set->instance) return false;
  Instance *instance=action->set->instance;
  for(XrPath path:action->bindingPaths){
    if(RoleForPath(instance,path)!=role)continue;
    auto found=instance->pathStrings.find(path);if(found==instance->pathStrings.end())continue;
    const std::string&name=found->second;
    if(action->type==XR_ACTION_TYPE_BOOLEAN_INPUT&&(ButtonForBinding(name)!=0||AnalogBinding(name,"trigger")||AnalogBinding(name,"squeeze")||AnalogBinding(name,"grip")))return true;
    if(action->type==XR_ACTION_TYPE_FLOAT_INPUT&&
        (AnalogBinding(name,"trigger")||AnalogBinding(name,"squeeze")||AnalogBinding(name,"grip")||name.find("/input/thumbstick/x")!=std::string::npos||name.find("/input/thumbstick/y")!=std::string::npos||ButtonForBinding(name)!=0))return true;
    if(action->type==XR_ACTION_TYPE_VECTOR2F_INPUT&&name.find("/input/thumbstick")!=std::string::npos)return true;
    if(action->type==XR_ACTION_TYPE_POSE_INPUT&&name.find("/pose")!=std::string::npos)return true;
    if(action->type==XR_ACTION_TYPE_VIBRATION_OUTPUT&&name.find("/output/haptic")!=std::string::npos)return true;
  }
  return false;
}
XrPosef ReferenceComposePose(const XrPosef &a,const XrPosef &b) {
  float am[16],bm[16],result[16];MatrixFromPose(a,am);MatrixFromPose(b,bm);MultiplyColumnMajor(am,bm,result);return PoseFromMatrix(result);
}
XrPosef ReferenceRelativePose(const XrPosef &originFromSpace,const XrPosef &originFromBase) {
  float base[16],space[16],inverse[16],relative[16];MatrixFromPose(originFromBase,base);MatrixFromPose(originFromSpace,space);InvertRigid(base,inverse);MultiplyColumnMajor(inverse,space,relative);return PoseFromMatrix(relative);
}
'''
tests=r'''

int main(){
 Instance i;ActionSet set{&i};Action a;a.set=&set;
 const char* components[]={"trigger","trigger/value","trigger/click","trigger/touch","squeeze/value","grip","thumbstick/x","thumbstick/y","thumbstick","a/click","menu/click","grip/pose","aim/pose","unknown","/output/haptic"};
 for(unsigned role=0;role<2;++role)for(unsigned n=0;n<15;++n)i.pathStrings[1+role*15+n]=std::string(role?"/user/hand/right/input/":"/user/hand/left/input/")+components[n];
 i.pathStrings[15]="/user/hand/left/output/haptic";i.pathStrings[30]="/user/hand/right/output/haptic";
 std::mt19937 gen(41);std::uniform_real_distribution<float> random(-1,1);
 for(auto type:{XR_ACTION_TYPE_BOOLEAN_INPUT,XR_ACTION_TYPE_FLOAT_INPUT,XR_ACTION_TYPE_VECTOR2F_INPUT,XR_ACTION_TYPE_POSE_INPUT,XR_ACTION_TYPE_VIBRATION_OUTPUT}){
  a.type=type;a.plannedBindingPaths.clear();a.bindingPaths.clear();a.rolePlans[0]={};a.rolePlans[1]={};
  for(int n=0;n<5000;++n){
   a.bindingPaths.clear();for(unsigned b=0;b<gen()%8;++b)a.bindingPaths.push_back(1+gen()%32);
   WVRDXMTControllerV1 c;c.trigger=random(gen);c.grip=random(gen);c.thumbstickX=random(gen);c.thumbstickY=random(gen);c.buttons=gen()%256;c.timestampNanoseconds=1234;
   for(unsigned role=0;role<2;++role){assert(ActionHasBindingForRole(&a,role)==ReferenceActionHasBindingForRole(&a,role));auto v=SampleAction(&a,role,c),ref=ReferenceSampleAction(&a,role,c);assert(v.boolean==ref.boolean&&v.scalar==ref.scalar&&v.vector.x==ref.vector.x&&v.vector.y==ref.vector.y&&v.lastChangeTime==ref.lastChangeTime);}
  }
 }
 a.type=XR_ACTION_TYPE_FLOAT_INPUT;a.bindingPaths={1,2,5,6,7,8};a.plannedBindingPaths.clear();CompileActionBindings(&a);
 WVRDXMTControllerV1 c;c.trigger=.7;c.grip=.4;c.thumbstickX=-.8;c.thumbstickY=.8;
 auto before=allocations;for(int n=0;n<10000;++n){assert(ActionHasBindingForRole(&a,0));assert(SampleAction(&a,0,c).scalar==-.8f);}assert(allocations==before);
 set.actions={reinterpret_cast<XrAction>(&a)};
 Session session;session.instance=&i;session.attachedActionSets={reinterpret_cast<XrActionSet>(&set)};
 XrActiveActionSet active{reinterpret_cast<XrActionSet>(&set),XR_NULL_PATH};XrActionsSyncInfo info{XR_TYPE_ACTIONS_SYNC_INFO};info.countActiveActionSets=1;info.activeActionSets=&active;
 assert(SyncActions(reinterpret_cast<XrSession>(&session),&info)==XR_SUCCESS);
 assert(a.values[0].scalar==.8f);
 before=allocations;for(int n=0;n<10000;++n)assert(SyncActions(reinterpret_cast<XrSession>(&session),&info)==XR_SUCCESS);assert(allocations==before);
 XrActiveActionSet duplicate[]={active,active};info.countActiveActionSets=2;info.activeActionSets=duplicate;auto old=session.activeActionSets;
 assert(SyncActions(reinterpret_cast<XrSession>(&session),&info)==XR_ERROR_VALIDATION_FAILURE);assert(session.activeActionSets==old);
 info.countActiveActionSets=0;info.activeActionSets=nullptr;assert(SyncActions(reinterpret_cast<XrSession>(&session),&info)==XR_SUCCESS);assert(session.activeActionSets.empty());
 info.countActiveActionSets=1;info.activeActionSets=&active;session.state=XR_SESSION_STATE_VISIBLE;assert(SyncActions(reinterpret_cast<XrSession>(&session),&info)==XR_SESSION_NOT_FOCUSED);assert(session.activeActionSets.empty());
 session.state=XR_SESSION_STATE_FOCUSED;assert(SyncActions(reinterpret_cast<XrSession>(&session),&info)==XR_SUCCESS);assert(session.activeActionSets.size()==1);
 auto pose=[&]{XrPosef p;auto&q=p.orientation;q={random(gen),random(gen),random(gen),random(gen)};float n=std::sqrt(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w);q.x/=n;q.y/=n;q.z/=n;q.w/=n;p.position={random(gen)*10,random(gen)*10,random(gen)*10};return p;};
 auto compare=[](const XrPosef&a,const XrPosef&b){float am[16],bm[16];MatrixFromPose(a,am);MatrixFromPose(b,bm);for(int n=0;n<16;++n)assert(std::fabs(am[n]-bm[n])<.00006f);};
 for(int n=0;n<30000;++n){auto a=pose(),b=pose();compare(ComposePose(a,b),ReferenceComposePose(a,b));compare(RelativePose(a,b),ReferenceRelativePose(a,b));if(n%10==0){a.orientation.w*=1.4;compare(ComposePose(a,b),ReferenceComposePose(a,b));compare(RelativePose(a,b),ReferenceRelativePose(a,b));}}
 auto chain=pose();const auto step=pose();for(int n=0;n<10000;++n){chain=ComposePose(chain,step);auto&q=chain.orientation;assert(std::fabs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1.f)<.000001f);}
 auto bench=[&](auto fn){volatile float sum=0;auto start=std::chrono::steady_clock::now();for(int n=0;n<300000;++n)sum=sum+fn(n);return double(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count())/300000;};
 ActionValue(*volatile referenceSample)(Action*,uint32_t,const WVRDXMTControllerV1&)=ReferenceSampleAction;
 ActionValue(*volatile optimizedSample)(Action*,uint32_t,const WVRDXMTControllerV1&)=SampleAction;
 XrPosef(*volatile referenceRelative)(const XrPosef&,const XrPosef&)=ReferenceRelativePose;
 XrPosef(*volatile optimizedRelative)(const XrPosef&,const XrPosef&)=RelativePose;
 auto base=bench([&](int n){c.trigger=float(n%100)*.01f;return referenceSample(&a,0,c).scalar;});auto fast=bench([&](int n){c.trigger=float(n%100)*.01f;return optimizedSample(&a,0,c).scalar;});printf("action sampling: reference %.2f optimized %.2f ns/call (%.2fx isolated)\n",base,fast,base/fast);
 auto p=pose(),q=pose();base=bench([&](int n){p.position.x=float(n%100)*.1f;return referenceRelative(p,q).position.x;});fast=bench([&](int n){p.position.x=float(n%100)*.1f;return optimizedRelative(p,q).position.x;});printf("relative pose: reference %.2f optimized %.2f ns/call (%.2fx isolated)\n",base,fast,base/fast);
 puts("PASS: 50000 action/hand parity cases, binding replacement/empty/unsupported paths, zero steady-state input allocations, sync invalidation/focus recovery, 60000 random rigid pose comparisons and non-unit fallback");
}

'''

with tempfile.TemporaryDirectory(prefix='wvr-cpu-') as tmp:
 w=Path(tmp);cpp=w/'probe.cpp';exe=w/'probe'
 cpp.write_text(preamble+extra+'\n'.join(contract['functions'])+math+references+function('XrResult XRAPI_CALL SyncActions(')+tests)
 for label,flags in [('UBSan/bounds',['-fsanitize=undefined,bounds']),('Release',[])]:
  print(label,flush=True)
  subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2',*flags,'-I',str(root/'windows-vr-openxr/include'),'-I',str(root/'third-party/openxr/include'),str(cpp),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)

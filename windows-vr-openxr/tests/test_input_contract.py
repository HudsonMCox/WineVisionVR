#!/usr/bin/env python3
"""Run production input/profile helpers natively; no game or headset required."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'windows-vr-openxr/src/WindowsVROpenXR.cpp').read_text()
def function(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
preamble = r'''
#include <openxr/openxr.h>
#include "WindowsVRActionPlan.h"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
constexpr uint32_t kControllerLeft=0,kControllerRight=1;
struct Instance;struct Action;
struct ActionValue {bool boolean=false;float scalar=0;XrVector2f vector{};XrTime lastChangeTime=0;bool changed=false;};
struct ActionSet {Instance* instance;};
struct Action {std::string name;ActionSet* set;XrActionType type;std::vector<XrPath> subactionPaths,bindingPaths,plannedBindingPaths;WVRActionRolePlan rolePlans[2];std::unordered_map<uint32_t,ActionValue> values;};
struct Instance {std::mutex mutex;std::unordered_map<std::string,XrPath> paths;std::unordered_map<XrPath,std::string> pathStrings;std::vector<std::unique_ptr<Action>> actions;std::unordered_map<XrPath,XrPath> interactionProfiles;std::unordered_map<XrPath,XrAction> bindings;std::unordered_map<XrPath,std::vector<XrActionSuggestedBinding>> profileBindings;XrPath selectedProfile=XR_NULL_PATH;int selectedProfilePriority=-1;bool bindingsAttached=false;uint64_t nextPath=1;};
struct WVRDXMTControllerV1 {uint64_t buttons=0,timestampNanoseconds=0;uint32_t flags=7;float trigger=0,grip=0,thumbstickX=0,thumbstickY=0;};
struct ControllerSample {WVRDXMTControllerV1 left{},right{};};
struct Session {Instance* instance;std::atomic<XrSessionState> state{XR_SESSION_STATE_FOCUSED};std::recursive_mutex actionMutex;bool actionSetsAttached=true;std::vector<XrActionSet> activeActionSets;std::unordered_map<XrActionSet,XrPath> activeSetSubactions;ControllerSample controllers;};
Instance* GetInstance(XrInstance h){return reinterpret_cast<Instance*>(h);}
Action* GetAction(XrAction h){return reinterpret_cast<Action*>(h);}
void TraceLine(const char*){}
struct WVRDXMTHapticV1 {uint32_t role;float amplitude,frequencyHz,durationSeconds;};
std::vector<WVRDXMTHapticV1> sentHaptics;
Session* GetSession(XrSession h){return reinterpret_cast<Session*>(h);}
int SubmitSessionHaptic(Session*,const WVRDXMTHapticV1* request){sentHaptics.push_back(*request);return 0;}
#define FAILED(result) ((result)<0)
uint64_t ButtonForBinding(const std::string&);
'''
functions = [function(x) for x in [
    'bool AnalogBinding(', 'uint32_t RoleForPath(', 'XrPath UserPathForRole(', 'bool ActionAllowsRole(',
    'void CompileActionBindings(', 'bool ActionHasBindingForRole(', 'uint64_t ButtonForBinding(const std::string &binding) {',
    'ActionValue SampleAction(', 'void UpdateActionSnapshot(', 'bool ControllerConnected(', 'bool ActionSetIsActive(', 'XrResult GetActionSnapshot(',
    'XrResult XRAPI_CALL SuggestInteractionProfileBindings(',
    'XrResult XRAPI_CALL ApplyHapticFeedback(', 'XrResult XRAPI_CALL StopHapticFeedback(']]
tests = r'''
int main(){
 Instance i;ActionSet set{&i};
 auto path=[&](const std::string& name){auto found=i.paths.find(name);if(found!=i.paths.end())return found->second;auto p=i.nextPath++;i.paths[name]=p;i.pathStrings[p]=name;return p;};
 auto action=[&](XrActionType type){auto a=std::make_unique<Action>();a->set=&set;a->type=type;auto raw=a.get();i.actions.push_back(std::move(a));return raw;};
 WVRDXMTControllerV1 c;c.buttons=3;c.trigger=.8f;c.grip=.7f;c.thumbstickX=-.6f;c.thumbstickY=.4f;
 auto a=action(XR_ACTION_TYPE_BOOLEAN_INPUT);
 for(auto name:{"x/click","y/click","a/click","b/click","trigger/value","squeeze/value","trigger","squeeze","grip"}){
   a->bindingPaths={path(std::string("/user/hand/left/input/")+name)};
   assert(ActionHasBindingForRole(a,0));assert(SampleAction(a,0,c).boolean);assert(!ActionHasBindingForRole(a,1));
 }
 c.buttons|=1ull<<4;a->bindingPaths={path("/user/hand/left/input/select/click")};assert(SampleAction(a,0,c).boolean);
 c.trigger=.2f;a->bindingPaths={path("/user/hand/left/input/trigger/value")};assert(!SampleAction(a,0,c).boolean);
 auto axis=action(XR_ACTION_TYPE_FLOAT_INPUT);
 axis->bindingPaths={path("/user/hand/left/input/thumbstick/x")};assert(ActionHasBindingForRole(axis,0));assert(SampleAction(axis,0,c).scalar==-.6f);
 axis->bindingPaths={path("/user/hand/left/input/thumbstick/y")};assert(SampleAction(axis,0,c).scalar==.4f);
 auto vector=action(XR_ACTION_TYPE_VECTOR2F_INPUT);vector->bindingPaths={path("/user/hand/left/input/thumbstick")};assert(SampleAction(vector,0,c).vector.x==-.6f);
 UpdateActionSnapshot(axis,0,c);assert(axis->values[0].changed);UpdateActionSnapshot(axis,0,c);assert(!axis->values[0].changed);c.thumbstickY=-.2f;UpdateActionSnapshot(axis,0,c);assert(axis->values[0].changed);
 auto other=action(XR_ACTION_TYPE_FLOAT_INPUT);
 const auto squeeze=path("/user/hand/left/input/squeeze/value");
 const auto touch=path("/interaction_profiles/oculus/touch_controller");
 const auto simple=path("/interaction_profiles/khr/simple_controller");
 XrActionSuggestedBinding bindings[]={{reinterpret_cast<XrAction>(a),squeeze},{reinterpret_cast<XrAction>(other),squeeze}};
 XrInteractionProfileSuggestedBinding info{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};info.interactionProfile=touch;info.countSuggestedBindings=2;info.suggestedBindings=bindings;
 assert(SuggestInteractionProfileBindings(reinterpret_cast<XrInstance>(&i),&info)==XR_SUCCESS);
 assert(i.selectedProfile==touch);assert(a->bindingPaths.size()==1&&other->bindingPaths.size()==1);assert(axis->bindingPaths.empty());
 const auto select=path("/user/hand/left/input/select/click");XrActionSuggestedBinding fallback{reinterpret_cast<XrAction>(a),select};info.interactionProfile=simple;info.countSuggestedBindings=1;info.suggestedBindings=&fallback;
 assert(SuggestInteractionProfileBindings(reinterpret_cast<XrInstance>(&i),&info)==XR_SUCCESS);
 assert(i.selectedProfile==touch);assert(a->bindingPaths[0]==squeeze);
 i.bindingsAttached=true;assert(SuggestInteractionProfileBindings(reinterpret_cast<XrInstance>(&i),&info)==XR_ERROR_ACTIONSETS_ALREADY_ATTACHED);
 Session session;session.instance=&i;session.activeActionSets={reinterpret_cast<XrActionSet>(&set)};
 auto triggerAction=action(XR_ACTION_TYPE_FLOAT_INPUT);
 auto left=UserPathForRole(&i,0),right=UserPathForRole(&i,1);
 triggerAction->subactionPaths={left,right};triggerAction->bindingPaths={path("/user/hand/right/input/trigger/value")};
 session.controllers.right.trigger=1.0f;UpdateActionSnapshot(triggerAction,1,session.controllers.right);
 XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};get.action=reinterpret_cast<XrAction>(triggerAction);get.subactionPath=right;
 Action* actual=nullptr;ActionValue result{};bool active=false;
 assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_FLOAT_INPUT,actual,result,active)==XR_SUCCESS);assert(active&&result.scalar==1.0f);
 get.subactionPath=XR_NULL_PATH;result={};assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_FLOAT_INPUT,actual,result,active)==XR_SUCCESS);assert(active&&result.scalar==1.0f);
 get.subactionPath=left;result={};assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_FLOAT_INPUT,actual,result,active)==XR_SUCCESS);assert(!active&&result.scalar==0);
 session.state=XR_SESSION_STATE_VISIBLE;get.subactionPath=right;result={};assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_FLOAT_INPUT,actual,result,active)==XR_SUCCESS);assert(!active);
 session.state=XR_SESSION_STATE_FOCUSED;
 auto grab=action(XR_ACTION_TYPE_BOOLEAN_INPUT);grab->subactionPaths={left,right};
 for(uint32_t role:{0u,1u}){
   grab->bindingPaths={path(role==0?"/user/hand/left/input/trigger":"/user/hand/right/input/trigger")};
   auto& controller=role==0?session.controllers.left:session.controllers.right;
   for(float amount:{0.0f,0.3f,0.8f,1.0f,0.0f}){
     controller.trigger=amount;UpdateActionSnapshot(grab,role,controller);
     get.action=reinterpret_cast<XrAction>(grab);get.subactionPath=role==0?left:right;result={};
     assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_BOOLEAN_INPUT,actual,result,active)==XR_SUCCESS);assert(active);assert(result.boolean==(amount>=.5f));
   }
 }
 triggerAction->bindingPaths={path("/user/hand/right/input/trigger")};session.controllers.right.trigger=.75f;UpdateActionSnapshot(triggerAction,1,session.controllers.right);get.action=reinterpret_cast<XrAction>(triggerAction);get.subactionPath=right;result={};assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_FLOAT_INPUT,actual,result,active)==XR_SUCCESS);assert(active&&result.scalar==.75f);
 assert(!AnalogBinding("/user/hand/right/input/trigger/touch","trigger"));
 assert(!AnalogBinding("/user/hand/right/input/trigger/click","trigger"));
 auto menu=action(XR_ACTION_TYPE_BOOLEAN_INPUT);menu->subactionPaths={left,right};
 menu->bindingPaths={path("/user/hand/left/input/menu/click"),path("/user/hand/right/input/menu/click")};
 for(uint32_t role:{0u,1u}){
   auto& controller=role==0?session.controllers.left:session.controllers.right;
   for(bool pressed:{true,false}){
     controller.buttons=pressed?(1ull<<2):0;UpdateActionSnapshot(menu,role,controller);
     get.action=reinterpret_cast<XrAction>(menu);get.subactionPath=role==0?left:right;result={};
     assert(GetActionSnapshot(&session,&get,XR_ACTION_TYPE_BOOLEAN_INPUT,actual,result,active)==XR_SUCCESS);
     assert(active&&result.boolean==pressed);
   }
 }
 auto vibration=action(XR_ACTION_TYPE_VIBRATION_OUTPUT);vibration->subactionPaths={left,right};
 vibration->bindingPaths={path("/user/hand/left/output/haptic"),path("/user/hand/right/output/haptic")};
 XrHapticActionInfo hapticInfo{XR_TYPE_HAPTIC_ACTION_INFO};hapticInfo.action=reinterpret_cast<XrAction>(vibration);
 XrHapticVibration pulse{XR_TYPE_HAPTIC_VIBRATION};pulse.amplitude=.7f;pulse.frequency=120;pulse.duration=3000000000LL;
 auto sessionHandle=reinterpret_cast<XrSession>(&session);
 assert(ApplyHapticFeedback(sessionHandle,&hapticInfo,reinterpret_cast<XrHapticBaseHeader*>(&pulse))==XR_SUCCESS);
 assert(sentHaptics.size()==2&&sentHaptics[0].role==0&&sentHaptics[1].role==1&&sentHaptics[0].durationSeconds==3);
 sentHaptics.clear();hapticInfo.subactionPath=right;
 assert(StopHapticFeedback(sessionHandle,&hapticInfo)==XR_SUCCESS);
 assert(sentHaptics.size()==1&&sentHaptics[0].role==1&&sentHaptics[0].amplitude==0&&sentHaptics[0].durationSeconds==0);
 sentHaptics.clear();pulse.duration=XR_MIN_HAPTIC_DURATION;
 assert(ApplyHapticFeedback(sessionHandle,&hapticInfo,reinterpret_cast<XrHapticBaseHeader*>(&pulse))==XR_SUCCESS);
 assert(sentHaptics.size()==1&&sentHaptics[0].durationSeconds==.05f);
 sentHaptics.clear();pulse.amplitude=2;
 assert(ApplyHapticFeedback(sessionHandle,&hapticInfo,reinterpret_cast<XrHapticBaseHeader*>(&pulse))==XR_ERROR_VALIDATION_FAILURE);
 assert(sentHaptics.empty());
 puts("PASS: production input values, hand isolation, change detection, shared-source actions, profile selection, menus, haptic routing/stop/duration and attachment contract");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-input-') as work:
    cpp = Path(work)/'test.cpp'
    cpp.write_text(preamble+'\n'.join(functions)+tests)
    exe = Path(work)/'test'
    subprocess.run(['clang++','-std=c++20','-O2','-fsanitize=undefined,bounds','-I',str(root/'windows-vr-openxr/include'),'-I',str(root/'third-party/openxr/include'),str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)

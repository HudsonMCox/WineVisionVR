"""Local LLDB driver for the isolated simulator runtime probe, never a headset.

Import in LLDB, then call run(debugger, pid, timeout=60). It implements Madeira's
prepare-region contract with LLDB memory allocation/writes and register responses.
It handles the runtime's actual BRK request, without skipping its function.
The page-zero BRK request reports failure, as on the current headset helper.
"""
import lldb
import subprocess
import time

def integer(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()

def prepare(process, address, size):
    if not 0 < size <= 0x80000000:
        raise RuntimeError('Invalid JIT preparation size')
    error = lldb.SBError()
    if not address:
        address = process.AllocateMemory(size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, error)
        if error.Fail() or address in (0, lldb.LLDB_INVALID_ADDRESS):
            raise RuntimeError('RX allocation failed: ' + str(error))
    # Writes through the actual debugger task port; no fake JIT readiness flag.
    page = bytes(0x100000)
    for offset in range(0, size, len(page)):
        data = page[:min(len(page), size-offset)]
        written = process.WriteMemory(address+offset, data, error)
        if error.Fail() or written != len(data):
            raise RuntimeError('JIT page preparation failed: ' + str(error))
    print('SIM JIT: prepared 0x%x, %d bytes' % (address, size), flush=True)
    return address

def run(debugger, pid, timeout=60):
    executable = subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
    if not executable.endswith('/RuntimeProbe.app/RuntimeProbe'):
        raise RuntimeError('Refusing to debug anything except the isolated RuntimeProbe simulator app')
    target = debugger.CreateTarget(executable)
    error = lldb.SBError()
    # Do not share the command interpreter's listener: it can consume a stop
    # before this Python driver sees it and leave the inferior parked forever.
    listener = lldb.SBListener('avpplay.simulator.probe')
    process = target.AttachToProcessWithID(listener, int(pid), error)
    if error.Fail(): raise RuntimeError('Attach failed: ' + str(error))
    print('SIM JIT: handling the runtime BRK protocol',flush=True)
    debugger.HandleCommand('process handle SIGSEGV -s false -n false -p true')
    debugger.SetAsync(True)
    error = process.Continue()
    if error.Fail(): raise RuntimeError('Continue failed: ' + str(error))
    deadline = time.monotonic()+timeout
    preparations = 0
    while time.monotonic() < deadline:
        event = lldb.SBEvent()
        received = listener.WaitForEvent(1,event)
        if received and lldb.SBProcess.EventIsProcessEvent(event):
            state = lldb.SBProcess.GetStateFromEvent(event)
        else:
            # Some LLDB builds route public state notifications elsewhere even
            # with an explicit listener. The current process state is authoritative.
            state = process.GetState()
        if state == lldb.eStateExited:
            print('SIM JIT: host exited %d' % process.GetExitStatus(),flush=True); return
        if state != lldb.eStateStopped: continue
        thread = next((t for t in process if t.GetStopReason() not in (lldb.eStopReasonNone,lldb.eStopReasonInvalid)),process.GetSelectedThread())
        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        memory_error = lldb.SBError()
        instruction = process.ReadUnsignedFromMemory(pc,4,memory_error)
        if instruction == 0xd43e01a0 and memory_error.Success():
            command = integer(frame,'x16')
            if command == 1:
                address = prepare(process,integer(frame,'x0'),integer(frame,'x1'))
                if not frame.FindRegister('x0').SetValueFromCString(hex(address)):
                    raise RuntimeError('Could not return prepared address in x0')
                print('SIM JIT: returning prepared address 0x%x' % integer(frame,'x0'),flush=True)
                preparations += 1
            elif command == 3:
                frame.FindRegister('x0').SetValueFromCString('0')
                print('SIM JIT: page-zero request declined',flush=True)
            elif command == 0:
                print('SIM JIT: detach request acknowledged; keeping helper attached for this probe',flush=True)
            else: raise RuntimeError('Unknown Madeira BRK command %d' % command)
            if not frame.SetPC(pc+4): raise RuntimeError('Could not advance past JIT BRK')
            error = process.Continue()
            if error.Fail(): raise RuntimeError('Continue failed: ' + str(error))
            continue
        print('SIM JIT: unexpected stop: %s at 0x%x' % (thread.GetStopDescription(256),pc),flush=True)
        debugger.HandleCommand('thread backtrace')
        return
    process.Stop()
    process.Detach()
    print('SIM JIT: probe observation ended; preparations=%d' % preparations,flush=True)

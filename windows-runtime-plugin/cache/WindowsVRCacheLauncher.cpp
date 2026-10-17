#include <windows.h>
#include <cstdio>
#include <string>
#include "WindowsCommandLine.h"

static bool Run(const wchar_t* Exe, std::wstring Command, DWORD Timeout, DWORD& ExitCode) {
  STARTUPINFOW Startup {}; Startup.cb = sizeof(Startup);
  PROCESS_INFORMATION Process {};
  if (!CreateProcessW(Exe, Command.data(), nullptr, nullptr, TRUE, 0, nullptr, nullptr, &Startup, &Process)) return false;
  CloseHandle(Process.hThread);
  auto Wait = WaitForSingleObject(Process.hProcess, Timeout);
  if (Wait != WAIT_OBJECT_0) {
    TerminateProcess(Process.hProcess, 124);
    // Do not overlap code generation and gameplay in the shared JIT pool.
    WaitForSingleObject(Process.hProcess, INFINITE);
  }
  bool Okay = GetExitCodeProcess(Process.hProcess, &ExitCode);
  CloseHandle(Process.hProcess);
  return Okay && Wait == WAIT_OBJECT_0;
}

int wmain(int Count, wchar_t** Args) {
  if (Count < 3) return 64;
  DWORD CompilerExit = 0;
  bool Compiled = Run(Args[1], QuoteWindowsArgument(Args[1]) + L" process-all", 120000, CompilerExit);
  std::fprintf(stderr, "[WVR cache] prelaunch compiler finished=%d exit=%lu\n", Compiled, CompilerExit);
  // Caching is an acceleration: failure leaves the normal JIT path usable.
  std::wstring Command = QuoteWindowsArgument(Args[2]);
  for (int I = 3; I < Count; ++I) Command += L" " + QuoteWindowsArgument(Args[I]);
  DWORD GameExit = 0;
  if (!Run(Args[2], Command, INFINITE, GameExit)) {
    std::fprintf(stderr, "[WVR cache] game process failed, error=%lu\n", GetLastError());
    return 70;
  }
  return static_cast<int>(GameExit);
}

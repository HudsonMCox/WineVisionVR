#pragma once
#include <string>
// CommandLineToArgvW/MSVCRT quoting, including empty strings and trailing slashes.
inline std::wstring QuoteWindowsArgument(const std::wstring& Input) {
  std::wstring Out = L"\"";
  size_t Slashes = 0;
  for (wchar_t C : Input) {
    if (C == L'\\') { ++Slashes; continue; }
    Out.append(C == L'"' ? Slashes * 2 + 1 : Slashes, L'\\');
    Slashes = 0; Out += C;
  }
  Out.append(Slashes * 2, L'\\'); Out += L'"'; return Out;
}

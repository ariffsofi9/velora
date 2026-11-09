// Synthetic-only probe: the only executable selected is this binary itself.
#define _WIN32_WINNT 0x0A00
#define NOMINMAX
#include <windows.h>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>
struct H {
  HANDLE h;
  explicit H(HANDLE v = nullptr): h(v) {}
  ~H() { if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h); }
  H(const H&) = delete; H& operator=(const H&) = delete;
};
static unsigned stage = 1;
static void check(bool b) { if (!b) throw std::runtime_error("FAILED"); }
static bool tokenOK(const std::wstring& s) {
  return s.size() == 32 && s.find_first_not_of(L"0123456789abcdef") == s.npos;
}
static std::wstring dec(HANDLE h) { return std::to_wstring((ULONG_PTR)h); }
static HANDLE handle(const wchar_t* s) {
  wchar_t* end; auto n = _wcstoui64(s, &end, 10);
  check(end != s && !*end && n); return (HANDLE)n;
}
static void emit(const std::wstring& token, const char* event, DWORD count = 0) {
  std::string t; for (wchar_t c : token) t.push_back(static_cast<char>(c));
  std::string line = "{\"v\":1,\"token\":\"" + t + "\",\"event\":\"" + event +
    "\",\"count\":" + std::to_string(count) + "}\n";
  DWORD n; check(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line.data(), (DWORD)line.size(), &n, nullptr) && n == line.size());
}
static HANDLE newJob() {
  H j(CreateJobObjectW(nullptr, nullptr)); check(j.h != nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  check(SetInformationJobObject(j.h, JobObjectExtendedLimitInformation, &limits, sizeof(limits)));
  HANDLE value = j.h; j.h = nullptr; return value;
}
static PROCESS_INFORMATION spawnSelf(const std::vector<std::wstring>& args, HANDLE job,
    const std::vector<HANDLE>& inherited, DWORD extra = 0, HANDLE input = nullptr, HANDLE output = nullptr) {
  wchar_t exe[32768]; DWORD n = GetModuleFileNameW(nullptr, exe, 32768); check(n && n < 32768);
  std::wstring command = L"\"" + std::wstring(exe) + L"\"";
  for (auto& arg : args) {
    check(arg.find_first_not_of(L"abcdefghijklmnopqrstuvwxyz-0123456789") == arg.npos);
    command += L" " + arg;
  }
  SIZE_T size = 0; DWORD count = job ? 2 : 1;
  InitializeProcThreadAttributeList(nullptr, count, 0, &size);
  std::vector<unsigned char> memory(size);
  auto attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)memory.data();
  check(InitializeProcThreadAttributeList(attrs, count, 0, &size));
  bool ok = UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
    (void*)inherited.data(), inherited.size() * sizeof(HANDLE), nullptr, nullptr) != FALSE;
  if (ok && job) ok = UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
    &job, sizeof(job), nullptr, nullptr) != FALSE;
  STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = attrs;
  if (input && output) {
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input; startup.StartupInfo.hStdOutput = output;
    startup.StartupInfo.hStdError = output;
  }
  PROCESS_INFORMATION p{}; wchar_t environment[2] = {0, 0};
  if (ok) ok = CreateProcessW(exe, command.data(), nullptr, nullptr, TRUE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | extra,
    environment, nullptr, &startup.StartupInfo, &p) != FALSE;
  DWORD error = GetLastError(); DeleteProcThreadAttributeList(attrs); SetLastError(error); check(ok);
  if (job) {
    BOOL inside = FALSE;
    if (!IsProcessInJob(p.hProcess, job, &inside) || !inside) {
      // This retained handle identifies our own suspended creation, not a PID lookup.
      TerminateProcess(p.hProcess, 99); WaitForSingleObject(p.hProcess, 5000);
      CloseHandle(p.hProcess); CloseHandle(p.hThread); check(false);
    }
  }
  return p;
}
static DWORD active(HANDLE job) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION a{};
  check(QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &a, sizeof(a), nullptr));
  return a.ActiveProcesses;
}
static bool empty(HANDLE job, DWORD ms = 5000) {
  auto end = GetTickCount64() + ms;
  do { if (!active(job)) return true; Sleep(5); } while (GetTickCount64() < end);
  return active(job) == 0;
}
struct Members {
  std::vector<HANDLE> handles;
  ~Members() { for (auto h : handles) CloseHandle(h); }
  void capture(HANDLE job) {
    alignas(JOBOBJECT_BASIC_PROCESS_ID_LIST) unsigned char buffer[4096]{};
    auto ids = (JOBOBJECT_BASIC_PROCESS_ID_LIST*)buffer;
    check(QueryInformationJobObject(job, JobObjectBasicProcessIdList, ids, sizeof(buffer), nullptr));
    for (DWORD i = 0; i < ids->NumberOfProcessIdsInList; ++i) {
      H process(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)ids->ProcessIdList[i]));
      BOOL inside = FALSE;
      check(process.h && IsProcessInJob(process.h, job, &inside) && inside);
      handles.push_back(process.h); process.h = nullptr;
    }
  }
  void wait() {
    const auto end = GetTickCount64() + 5000;
    for (auto h : handles) {
      const auto now = GetTickCount64();
      check(WaitForSingleObject(h, now >= end ? 0 : static_cast<DWORD>(end - now)) == WAIT_OBJECT_0);
    }
  }
};
static int worker(int argc, wchar_t** argv) {
  stage = 10;
  check(argc == 8 && tokenOK(argv[2]));
  BOOL inside = FALSE; check(IsProcessInJob(GetCurrentProcess(), nullptr, &inside) && inside);
  HANDLE stop = handle(argv[3]), rootExit = handle(argv[4]), ready = handle(argv[7]);
  int depth = std::stoi(argv[5]); check(depth >= 0 && depth <= 2);
  // Numeric handle slots can be reused by child startup. Compare object identity,
  // not mere slot validity, against an independently opened synthetic event.
  // Snapshot a preexisting slot before OpenEvent can itself reuse that slot.
  stage = 11; H candidate; DWORD flags;
  if (GetHandleInformation(handle(argv[6]), &flags)) {
    check(DuplicateHandle(GetCurrentProcess(), handle(argv[6]), GetCurrentProcess(),
      &candidate.h, 0, FALSE, DUPLICATE_SAME_ACCESS));
  }
  stage = 12; H excludedReference(OpenEventW(SYNCHRONIZE, FALSE, (L"Local\\velora-excluded-" + std::wstring(argv[2])).c_str()));
  check(excludedReference.h != nullptr);
  using CompareHandles = BOOL (WINAPI*)(HANDLE, HANDLE);
  auto compare = reinterpret_cast<CompareHandles>(GetProcAddress(GetModuleHandleW(L"kernelbase.dll"), "CompareObjectHandles"));
  stage = 13; check(compare != nullptr); // Unsupported API fails closed; no numeric-slot fallback.
  check(!candidate.h || !compare(candidate.h, excludedReference.h));
  stage = 14; H child;
  if (std::wstring(argv[1]) == L"--worker-breakaway") {
    bool rejected = false;
    try {
      auto escaped = spawnSelf({L"--worker", argv[2], dec(stop), dec(rootExit), L"0", argv[6], dec(ready)},
        nullptr, {stop, rootExit, ready}, CREATE_BREAKAWAY_FROM_JOB);
      H process(escaped.hProcess), thread(escaped.hThread);
      // Unexpected suspended escape is never resumed or identified by PID.
      TerminateProcess(process.h, 99); WaitForSingleObject(process.h, 5000);
    } catch (...) { rejected = GetLastError() == ERROR_ACCESS_DENIED; }
    check(rejected);
  }
  if (depth) {
    auto p = spawnSelf({argv[1], argv[2], dec(stop), dec(rootExit), std::to_wstring(depth - 1), argv[6], dec(ready)},
      nullptr, {stop, rootExit, ready});
    child.h = p.hProcess; H thread(p.hThread); check(ResumeThread(thread.h) != DWORD(-1));
  }
  if (std::wstring(argv[1]) != L"--worker-never-ready") check(ReleaseSemaphore(ready, 1, nullptr));
  for (;;) {
    if (child.h && WaitForSingleObject(child.h, 0) == WAIT_OBJECT_0) {
      DWORD code; check(GetExitCodeProcess(child.h, &code)); if (code) return static_cast<int>(code);
    }
    if (WaitForSingleObject(stop, 5) == WAIT_OBJECT_0) return 0;
    if (depth == 2 && WaitForSingleObject(rootExit, 0) == WAIT_OBJECT_0) return 0;
  }
}
static int supervise(const std::wstring& token, const std::wstring& scenario) {
  const std::vector<std::wstring> allowed = {L"forced", L"graceful", L"root-exit", L"close-job",
    L"partial", L"assignment-failure", L"heartbeat-timeout", L"execution-timeout",
    L"owner-crash", L"owner-hang", L"breakaway", L"startup-timeout"};
  check(tokenOK(token) && std::find(allowed.begin(), allowed.end(), scenario) != allowed.end());
  check(GetFileType(GetStdHandle(STD_INPUT_HANDLE)) == FILE_TYPE_PIPE);
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  H job(newJob()), sentinelJob(newJob());
  H stop(CreateEventW(&sa, TRUE, FALSE, nullptr)), rootExit(CreateEventW(&sa, TRUE, FALSE, nullptr));
  H excluded(CreateEventW(&sa, TRUE, FALSE, (L"Local\\velora-excluded-" + token).c_str()));
  H sentinelStop(CreateEventW(&sa, TRUE, FALSE, nullptr));
  H ready(CreateSemaphoreW(&sa, 0, 3, nullptr)), sentinelReady(CreateSemaphoreW(&sa, 0, 1, nullptr));
  check(stop.h && rootExit.h && excluded.h && sentinelStop.h && ready.h && sentinelReady.h);
  auto s = spawnSelf({L"--worker", token, dec(sentinelStop.h), dec(rootExit.h), L"0", dec(excluded.h), dec(sentinelReady.h)},
    sentinelJob.h, {sentinelStop.h, rootExit.h, sentinelReady.h});
  H sentinel(s.hProcess), sentinelThread(s.hThread); check(ResumeThread(sentinelThread.h) != DWORD(-1));
  auto alive = [&] { check(WaitForSingleObject(sentinel.h, 0) == WAIT_TIMEOUT); };
  check(WaitForSingleObject(sentinelReady.h, 3000) == WAIT_OBJECT_0); alive();
  if (scenario == L"assignment-failure") {
    HANDLE invalid = CreateJobObjectW(nullptr, nullptr); check(invalid != nullptr); CloseHandle(invalid);
    bool rejected = false;
    try { auto p = spawnSelf({L"--worker", token, dec(stop.h), dec(rootExit.h), L"0", dec(excluded.h), dec(ready.h)}, invalid, {stop.h, rootExit.h, ready.h});
      H process(p.hProcess), thread(p.hThread); TerminateProcess(process.h, 99); WaitForSingleObject(process.h, 5000);
    } catch (...) { rejected = true; }
    check(rejected && !active(job.h)); emit(token, "ASSIGNMENT_REJECTED");
    alive(); SetEvent(sentinelStop.h); check(WaitForSingleObject(sentinel.h, 5000) == WAIT_OBJECT_0);
    check(empty(sentinelJob.h)); emit(token, "SENTINEL_PRESERVED"); return 0;
  }
  auto mode = scenario == L"breakaway" ? L"--worker-breakaway" :
    scenario == L"startup-timeout" ? L"--worker-never-ready" : L"--worker";
  auto p = spawnSelf({mode, token, dec(stop.h), dec(rootExit.h), L"2", dec(excluded.h), dec(ready.h)}, job.h, {stop.h, rootExit.h, ready.h});
  H first(p.hProcess), thread(p.hThread); emit(token, "ASSIGNED");
  if (scenario == L"partial") {
    // Fault after assigned suspended creation, before any workload instruction.
    const auto cleanupStarted = GetTickCount64(); alive();
    check(TerminateJobObject(job.h, 90)); check(empty(job.h));
    check(WaitForSingleObject(first.h, 5000) == WAIT_OBJECT_0); alive();
    emit(token, "PARTIAL"); emit(token, "CLEANED");
    emit(token, "CLEANUP_MS", static_cast<DWORD>(GetTickCount64() - cleanupStarted));
    SetEvent(sentinelStop.h); check(WaitForSingleObject(sentinel.h, 5000) == WAIT_OBJECT_0);
    check(empty(sentinelJob.h)); emit(token, "SENTINEL_PRESERVED"); return 0;
  }
  check(ResumeThread(thread.h) != DWORD(-1));
  // Three worker acknowledgements follow their own membership/inheritance checks.
  // Job accounting may additionally include OS-created descendants.
  bool readyAll = true;
  for (int i = 0; i < 3; ++i) if (WaitForSingleObject(ready.h, 1000) != WAIT_OBJECT_0) { readyAll = false; break; }
  if (!readyAll) {
    const auto cleanupStarted = GetTickCount64();
    Members pending; pending.capture(job.h); alive(); check(TerminateJobObject(job.h, 90));
    check(empty(job.h)); pending.wait(); alive(); emit(token, "STARTUP_TIMEOUT"); emit(token, "CLEANED");
    emit(token, "CLEANUP_MS", static_cast<DWORD>(GetTickCount64() - cleanupStarted));
    SetEvent(sentinelStop.h); check(WaitForSingleObject(sentinel.h, 5000) == WAIT_OBJECT_0);
    check(empty(sentinelJob.h)); emit(token, "SENTINEL_PRESERVED");
    return scenario == L"startup-timeout" ? 0 : 1;
  }
  Members members; members.capture(job.h); check(members.handles.size() >= 3);
  emit(token, "READY", 3);
  if (scenario == L"breakaway") emit(token, "BREAKAWAY_REJECTED", 3);
  std::string reason = "FORCED", input;
  auto began = GetTickCount64(), heartbeat = began;
  if (scenario == L"root-exit") {
    SetEvent(rootExit.h); check(WaitForSingleObject(first.h, 3000) == WAIT_OBJECT_0);
    check(active(job.h) > 0); reason = "ROOT_EXIT";
  } else if (scenario == L"close-job") reason = "LAST_HANDLE";
  else {
    bool done = false;
    while (!done) {
      DWORD available = 0;
      if (!PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), nullptr, 0, nullptr, &available, nullptr)) {
        reason = "DISCONNECTED"; break;
      }
      if (available) {
        char buffer[128]; DWORD n;
        check(ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer, std::min<DWORD>(available, 128), &n, nullptr));
        input.append(buffer, n); check(input.size() <= 256);
        size_t end;
        while ((end = input.find('\n')) != std::string::npos) {
          auto command = input.substr(0, end); input.erase(0, end + 1);
          if (command == "V1 PING") heartbeat = GetTickCount64();
          else if (command == "V1 SHUTDOWN") { SetEvent(stop.h); reason = "GRACEFUL"; done = true; }
          else if (command == "V1 STOP") { reason = "FORCED"; done = true; }
          else if (command == "V1 CRASH" && scenario == L"owner-crash") {
            TerminateProcess(GetCurrentProcess(), 77);
          }
          else if (command == "V1 HANG" && scenario == L"owner-hang") Sleep(INFINITE);
          else check(false);
        }
      }
      if (GetTickCount64() - heartbeat > 1000) { reason = "HEARTBEAT_TIMEOUT"; break; }
      if (GetTickCount64() - began > (scenario == L"execution-timeout" ? 250 : 5000)) {
        reason = "EXECUTION_TIMEOUT"; break;
      }
      Sleep(5);
    }
  }
  const auto cleanupStarted = GetTickCount64(); alive(); bool zero = false;
  if (reason == "LAST_HANDLE") { CloseHandle(job.h); job.h = nullptr; }
  else {
    if (reason == "GRACEFUL") zero = empty(job.h, 1000);
    if (!zero) check(TerminateJobObject(job.h, 90));
    zero = empty(job.h);
  }
  members.wait(); alive(); emit(token, reason.c_str());
  if (job.h) { check(zero && !active(job.h)); emit(token, "CLEANED"); }
  else emit(token, "HANDLES_SIGNALED", static_cast<DWORD>(members.handles.size()));
  emit(token, "CLEANUP_MS", static_cast<DWORD>(GetTickCount64() - cleanupStarted));
  SetEvent(sentinelStop.h); check(WaitForSingleObject(sentinel.h, 5000) == WAIT_OBJECT_0);
  check(empty(sentinelJob.h)); emit(token, "SENTINEL_PRESERVED"); return 0;
}
// Independent synthetic OS observer. It owns an OUTER job solely for test safety,
// never the supervisor's unnamed workload job. Retained handles witness crash cleanup.
static int observe(const std::wstring& token, const std::wstring& scenario) {
  check(tokenOK(token) && (scenario == L"owner-crash" || scenario == L"owner-hang"));
  H outer(newJob()), sentinelJob(newJob()); SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  H stop(CreateEventW(&sa, TRUE, FALSE, nullptr)), rootExit(CreateEventW(&sa, TRUE, FALSE, nullptr));
  H ready(CreateSemaphoreW(&sa, 0, 1, nullptr));
  H excluded(CreateEventW(&sa, TRUE, FALSE, (L"Local\\velora-excluded-" + token).c_str()));
  check(stop.h && rootExit.h && ready.h && excluded.h);
  auto s = spawnSelf({L"--worker", token, dec(stop.h), dec(rootExit.h), L"0", dec(excluded.h), dec(ready.h)},
    sentinelJob.h, {stop.h, rootExit.h, ready.h});
  H sentinel(s.hProcess), sentinelThread(s.hThread); check(ResumeThread(sentinelThread.h) != DWORD(-1));
  check(WaitForSingleObject(ready.h, 3000) == WAIT_OBJECT_0);
  H inputRead, inputWrite, outputRead, outputWrite;
  check(CreatePipe(&inputRead.h, &inputWrite.h, &sa, 0));
  check(CreatePipe(&outputRead.h, &outputWrite.h, &sa, 0));
  check(SetHandleInformation(inputWrite.h, HANDLE_FLAG_INHERIT, 0));
  check(SetHandleInformation(outputRead.h, HANDLE_FLAG_INHERIT, 0));
  auto p = spawnSelf({L"--supervise", token, scenario}, outer.h, {inputRead.h, outputWrite.h},
    0, inputRead.h, outputWrite.h);
  H supervisor(p.hProcess), thread(p.hThread); check(ResumeThread(thread.h) != DWORD(-1));
  CloseHandle(inputRead.h); inputRead.h = nullptr; CloseHandle(outputWrite.h); outputWrite.h = nullptr;
  std::string transcript; auto end = GetTickCount64() + 5000;
  while (transcript.find("\"event\":\"READY\"") == std::string::npos && GetTickCount64() < end) {
    DWORD n = 0; check(PeekNamedPipe(outputRead.h, nullptr, 0, nullptr, &n, nullptr));
    if (n) { char bytes[256]; check(ReadFile(outputRead.h, bytes, std::min<DWORD>(n, 256), &n, nullptr)); transcript.append(bytes, n); }
    check(transcript.size() < 4096); Sleep(5);
  }
  check(transcript.find("\"event\":\"READY\"") != std::string::npos);
  Members retained; retained.capture(outer.h); check(retained.handles.size() >= 5);
  check(WaitForSingleObject(sentinel.h, 0) == WAIT_TIMEOUT);
  const auto cleanupStarted = GetTickCount64();
  const std::string command = scenario == L"owner-crash" ? "V1 CRASH\n" : "V1 HANG\n"; DWORD n;
  check(WriteFile(inputWrite.h, command.data(), (DWORD)command.size(), &n, nullptr));
  if (scenario == L"owner-hang") {
    check(WaitForSingleObject(supervisor.h, 250) == WAIT_TIMEOUT);
    check(TerminateProcess(supervisor.h, 78)); // Retained creation handle; no PID targeting.
  }
  check(WaitForSingleObject(supervisor.h, 5000) == WAIT_OBJECT_0);
  // Crucially, do NOT terminate the outer job before proving last-inner-handle cleanup.
  check(empty(outer.h)); retained.wait(); check(WaitForSingleObject(sentinel.h, 0) == WAIT_TIMEOUT);
  emit(token, scenario == L"owner-crash" ? "OWNER_CRASH_CLEANED" : "WATCHDOG_CLEANED"); emit(token, "CLEANED");
  emit(token, "CLEANUP_MS", static_cast<DWORD>(GetTickCount64() - cleanupStarted));
  SetEvent(stop.h); check(WaitForSingleObject(sentinel.h, 5000) == WAIT_OBJECT_0);
  check(empty(sentinelJob.h)); emit(token, "SENTINEL_PRESERVED"); return 0;
}
int wmain(int argc, wchar_t** argv) {
  try {
    if (argc > 1 && (std::wstring(argv[1]) == L"--worker" || std::wstring(argv[1]) == L"--worker-breakaway" ||
      std::wstring(argv[1]) == L"--worker-never-ready")) return worker(argc, argv);
    if (argc == 4 && std::wstring(argv[1]) == L"--observe") return observe(argv[2], argv[3]);
    check(argc == 4 && std::wstring(argv[1]) == L"--supervise"); return supervise(argv[2], argv[3]);
  } catch (...) {
    const char message[] = "{\"v\":1,\"event\":\"NATIVE_FAILURE\"}\n"; DWORD n;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof(message) - 1, &n, nullptr); return static_cast<int>(100 + stage);
  }
}

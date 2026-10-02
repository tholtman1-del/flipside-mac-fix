/* Poor-man's sampling profiler for a 32-bit Windows process under Wine (lldb/sample can't attach
 * under Rosetta). Usage: wine-sampler.exe <exe name> [seconds] [interval ms]
 * Suspends every thread of the target periodically, records EIP, and prints per-thread CPU time,
 * hottest modules and hottest addresses (module+offset). Build: i686-w64-mingw32-gcc -O2 -o
 * wine-sampler.exe wine-sampler.c */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { DWORD base, size; char name[64]; } mod_t;
typedef struct { DWORD tid; HANDLE h; ULONGLONG cpu0; int n; } thr_t;
typedef struct { DWORD tid; DWORD eip; int count; } hit_t;

static mod_t mods[512]; static int nmods;
static thr_t thr[256]; static int nthr;
static hit_t *hits; static int nhits, maxhits = 1 << 16;

static void load_modules(DWORD pid)
{
    MODULEENTRY32 me = { sizeof(me) };
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    nmods = 0;
    if (s == INVALID_HANDLE_VALUE) return;
    if (Module32First(s, &me)) do {
        if (nmods >= 512) break;
        mods[nmods].base = (DWORD)(ULONG_PTR)me.modBaseAddr; mods[nmods].size = me.modBaseSize;
        lstrcpynA(mods[nmods].name, me.szModule, 64); nmods++;
    } while (Module32Next(s, &me));
    CloseHandle(s);
}

static const char *mod_of(DWORD a, DWORD *off)
{
    for (int i = 0; i < nmods; i++)
        if (a >= mods[i].base && a < mods[i].base + mods[i].size) { *off = a - mods[i].base; return mods[i].name; }
    *off = a; return a >= 0x7b000000 ? "?wine-high" : "?anon";
}

static ULONGLONG cputime(HANDLE h)
{
    FILETIME c, e, k, u;
    if (!GetThreadTimes(h, &c, &e, &k, &u)) return 0;
    return ((ULONGLONG)k.dwHighDateTime << 32 | k.dwLowDateTime) + ((ULONGLONG)u.dwHighDateTime << 32 | u.dwLowDateTime);
}

static void refresh_threads(DWORD pid)
{
    THREADENTRY32 te = { sizeof(te) };
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (Thread32First(s, &te)) do {
        if (te.th32OwnerProcessID != pid) continue;
        int found = 0;
        for (int i = 0; i < nthr; i++) if (thr[i].tid == te.th32ThreadID) found = 1;
        if (found || nthr >= 256) continue;
        HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
        if (!h) continue;
        thr[nthr].tid = te.th32ThreadID; thr[nthr].h = h; thr[nthr].cpu0 = cputime(h); thr[nthr].n = 0; nthr++;
    } while (Thread32Next(s, &te));
    CloseHandle(s);
}

static void add_hit(DWORD tid, DWORD eip)
{
    for (int i = 0; i < nhits; i++) if (hits[i].tid == tid && hits[i].eip == eip) { hits[i].count++; return; }
    if (nhits < maxhits) { hits[nhits].tid = tid; hits[nhits].eip = eip; hits[nhits].count = 1; nhits++; }
}

static int cmp_hit(const void *a, const void *b) { return ((hit_t *)b)->count - ((hit_t *)a)->count; }

int main(int argc, char **argv)
{
    const char *name = argc > 1 ? argv[1] : "FLIPSIDE.exe";
    int secs = argc > 2 ? atoi(argv[2]) : 10, ms = argc > 3 ? atoi(argv[3]) : 5;
    PROCESSENTRY32 pe = { sizeof(pe) }; DWORD pid = 0;
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (Process32First(s, &pe)) do { if (!lstrcmpiA(pe.szExeFile, name)) pid = pe.th32ProcessID; } while (Process32Next(s, &pe));
    CloseHandle(s);
    if (!pid) { printf("process %s not found\n", name); return 1; }
    hits = calloc(maxhits, sizeof(*hits));
    load_modules(pid); refresh_threads(pid);
    printf("pid %lu, %d modules, %d threads, %d s @ %d ms\n", pid, nmods, nthr, secs, ms);

    DWORD end = GetTickCount() + secs * 1000; int samples = 0;
    timeBeginPeriod(1);
    while (GetTickCount() < end) {
        for (int i = 0; i < nthr; i++) {
            WOW64_CONTEXT c32; CONTEXT c;
            if (SuspendThread(thr[i].h) == (DWORD)-1) continue;
            memset(&c, 0, sizeof(c)); c.ContextFlags = CONTEXT_CONTROL;
            if (GetThreadContext(thr[i].h, &c)) { add_hit(thr[i].tid, c.Eip); thr[i].n++; }
            ResumeThread(thr[i].h);
            (void)c32;
        }
        samples++;
        Sleep(ms);
    }
    timeEndPeriod(1);

    printf("\n%d sample rounds\nthread   cpu-ms (during run)\n", samples);
    ULONGLONG cpu[256];
    for (int i = 0; i < nthr; i++) { cpu[i] = (cputime(thr[i].h) - thr[i].cpu0) / 10000; printf("%6lx %8llu\n", thr[i].tid, cpu[i]); }

    qsort(hits, nhits, sizeof(*hits), cmp_hit);
    for (int t = 0; t < nthr; t++) {
        if (!thr[t].n) continue;
        printf("\n== thread %lx: %llu ms CPU, %d samples\n  modules:\n", thr[t].tid, cpu[t], thr[t].n);
        struct { const char *m; int c; } agg[128]; int na = 0;
        for (int i = 0; i < nhits; i++) {
            if (hits[i].tid != thr[t].tid) continue;
            DWORD off; const char *m = mod_of(hits[i].eip, &off); int j;
            for (j = 0; j < na; j++) if (agg[j].m == m) break;
            if (j == na && na < 128) { agg[na].m = m; agg[na].c = 0; na++; }
            if (j < 128) agg[j].c += hits[i].count;
        }
        for (int a = 0; a < na; a++) for (int b = a + 1; b < na; b++)
            if (agg[b].c > agg[a].c) { const char *m = agg[a].m; int c = agg[a].c; agg[a] = agg[b]; agg[b].m = m; agg[b].c = c; }
        for (int a = 0; a < na && a < 5; a++) printf("    %5.1f%% %s\n", 100.0 * agg[a].c / thr[t].n, agg[a].m);
        printf("  top addresses:\n");
        int shown = 0;
        for (int i = 0; i < nhits && shown < 8; i++) {
            if (hits[i].tid != thr[t].tid) continue;
            DWORD off; const char *m = mod_of(hits[i].eip, &off);
            printf("    %5.1f%% %s+0x%lx\n", 100.0 * hits[i].count / thr[t].n, m, off); shown++;
        }
    }
    return 0;
}

// How many tests may be in flight at once. Set here, when a test bundle is
// loaded, so it holds however the tests are started: `swift test`, the three
// shards CI runs (mac/test-shards.sh), or one suite from an editor.
//
// ── WHY THE TESTS NEED A BOUND ──────────────────────────────────────────────
//
// Swift Testing starts every test it has at once. Nearly every app test is
// `@MainActor` and begins by making a shop or an engine, then waits its turn
// for the main thread. So thousands of tests were IN FLIGHT together, each
// holding an engine while it queued, and an engine is a JavaScript context
// with every shared rule loaded: about 20 MB.
//
// Measured on a full `swift test` (Nov 12 2026, a 32 GB Mac, 4,463 app
// tests): 2,467 engines made, 1,851 of them alive at once at the worst, and
// the process at 33 GB, more than the machine has. Nothing leaked; four were
// alive at the end. They were simply all wanted at the same moment. CI's
// runner has 7 GB and runs three such processes side by side.
//
// A machine out of memory is the likeliest reading of four failures this was
// written after, though the memory was only measured here, afterwards, and
// not on the machines where they happened: the allocator stopping the
// process inside `JSContext()` ten minutes into a CI run (#2432); the invoice
// test that waited nineteen minutes for WebKit and got a blank page, WebKit's
// processes being among the first things the system ends when memory is
// short; and a Python server that needs a tenth of a second to start not
// having started in sixty, on a Mac whose load average was 4 of 10 cores.
//
// With a bound, a test is not started until one in flight has finished.
// Measured on 934 of the app tests: no bound, 382 engines alive at the worst
// and 4.6 GB, 69 s; eight in flight, 9 engines and 94 MB, 65 s; twenty-four,
// 25 engines and 282 MB, 61 s. It is not slower, because the tests were never
// running side by side to begin with: they share one main thread.
//
// ── WHY A C FILE, AND WHY AN ENVIRONMENT VARIABLE ───────────────────────────
//
// The bound is Swift Testing's own (`maximumParallelizationWidth`), and in
// this toolchain the only way to give it one is this variable, read when the
// run is configured. That is after the test bundle has been loaded, so a
// function that runs AS it loads is in time; Swift has no such function and C
// does. Putting it in a script instead would bound CI and leave every
// `swift test` typed by hand as it was, which is where three of the four
// failures above were seen.
//
// The variable says "experimental". If a later toolchain stops reading it
// the bound is gone without a word, so `TestsInFlightAreBoundedTests` does
// not check that the variable is set: it counts how many of its own cases
// are in flight together and fails when that is more than the bound.
#include "KhaytTestWidth.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define KHAYT_WIDTH_VARIABLE "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"

__attribute__((constructor))
static void khayt_bound_tests_in_flight(void) {
    // Two for every core, and never fewer than four: twenty on the Mac the
    // figures above were taken on, six on CI's three cores. The measurements
    // put the best time between eight and twenty-four.
    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores < 2) cores = 2;
    char width[16];
    snprintf(width, sizeof width, "%ld", cores * 2);
    // 0: somebody who set a number on purpose keeps it.
    setenv(KHAYT_WIDTH_VARIABLE, width, 0);
}

int khayt_tests_in_flight_at_most(void) {
    const char *value = getenv(KHAYT_WIDTH_VARIABLE);
    return value ? atoi(value) : 0;
}

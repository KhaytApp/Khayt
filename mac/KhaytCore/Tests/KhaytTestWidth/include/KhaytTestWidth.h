#ifndef KHAYT_TEST_WIDTH_H
#define KHAYT_TEST_WIDTH_H

/// How many tests Swift Testing may have in flight at once in this process,
/// as it will read it: the bound `width.c` sets when the test bundle loads,
/// or the number somebody set on purpose. Zero when there is none.
///
/// Calling this is also what makes the linker keep `width.c` in a test
/// bundle; see the note there.
int khayt_tests_in_flight_at_most(void);

#endif

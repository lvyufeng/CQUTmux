/*
 * Deliberately empty translation unit.
 *
 * CQUTMoshC is a pure header target: the module it exports is mosh_driver.h,
 * and the implementation it describes lives in libmoshclient.a (see
 * scripts/mosh-ios/). SwiftPM still wants at least one source file in a C
 * target, and Xcode's linker wants the resulting object to exist — without
 * this the link fails on a missing CQUTMoshC.o.
 *
 * It must not define anything: the driver's symbols are already in the
 * archive, and a definition here would collide with them at link time.
 */
#include "mosh_driver.h"
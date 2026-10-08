/*
 * Deliberately empty translation unit.
 *
 * CQUTETC is a pure header target: the module it exports is et_driver.h, and
 * the implementation it describes lives in Vendor/etclient/libetcore.a (see
 * scripts/et-ios/). SwiftPM still wants at least one source file in a C target,
 * and Xcode's linker wants the resulting object to exist — without this the
 * link fails on a missing CQUTETC.o.
 *
 * It must not define anything: et_driver.cc's symbols are already in the
 * archive, and a definition here would collide with them at link time.
 */
#include "et_driver.h"

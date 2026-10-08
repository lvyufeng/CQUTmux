/* config.h for building mosh's client-side libraries against the iOS SDK.
 *
 * mosh normally generates this with autoconf. autoconf cannot help here: it
 * probes for libutil/utempter/pty.h, which are the *server's* dependencies
 * and simply do not exist on iOS, so a configure run would either fail or
 * enable code we cannot link. Writing the header states the facts instead of
 * deriving them.
 *
 * Every macro below was checked against the iOS 27 simulator SDK, not assumed.
 * The ones intentionally left undefined are at the bottom with the reason.
 */
#ifndef CQUTMUX_MOSH_CONFIG_H
#define CQUTMUX_MOSH_CONFIG_H

#define PACKAGE_NAME "mosh"
#define PACKAGE_VERSION "1.4.0-ios"
#define VERSION "1.4.0-ios"

/* --- C++ standard library -------------------------------------------------
 * libc++ on iOS is C++11 and later; mosh's compatibility branches for
 * tr1/boost are dead here. */
#define HAVE_CXX11 1
#define HAVE_STD_SHARED_PTR 1
#define HAVE_MEMORY 1

/* --- crypto ---------------------------------------------------------------
 * Mosh has a first-class Apple Common Crypto backend, and configure.ac makes
 * it the default on Apple platforms. This is what removes the OpenSSL and
 * Nettle cross-compiles entirely. OCB comes from the bundled
 * ocb_internal.cc, so no OpenSSL OCB either. */
#define HAVE_COMMONCRYPTO_COMMONCRYPTO_H 1
#define USE_APPLE_COMMON_CRYPTO_AES 1

/* --- curses ---------------------------------------------------------------
 * iOS ships libncurses.tbd but no headers and no terminfo database. We supply
 * our own declarations (terminfo-shim.h) and a compiled-in entry
 * (terminfo-db.h), so HAVE_CURSES_H is declared for mosh's #if ladder while
 * the actual symbols resolve to the shim. Note: no HAVE_TERM_H — there is no
 * term.h on iOS, and mosh only includes it alongside curses.h. */
#define HAVE_CURSES_H 1
#define HAVE_CURSES 1
#define HAVE_TINFO 1

/* --- POSIX, all verified present in the SDK ------------------------------- */
#define HAVE_CLOCK_GETTIME 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_MACH_ABSOLUTE_TIME 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_LOCALE_H 1
#define HAVE_NETDB_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_LANGINFO_H 1
#define HAVE_STDDEF_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_ENDIAN_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_RESOURCE_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_TERMIOS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_WCHAR_H 1
#define HAVE_WCTYPE_H 1
#define HAVE_POSIX_MEMALIGN 1
#define HAVE_PSELECT 1
#define HAVE_IP_RECVTOS 1

/* darwin byte-swap lives in libkern/OSByteOrder.h */
#define HAVE_OSX_SWAP 1
/* BSWAP64/FFS exist as builtins; the decl probes look in headers we don't have. */
#define HAVE_DECL___BUILTIN_BSWAP64 1
#define HAVE_DECL___BUILTIN_CTZ 1
#define HAVE_DECL_FFS 1

/* --- interface defaults --------------------------------------------------- */
#define USE_ENCODING_UTF8 1
#define USE_REPORTING_X10 1

/* --- DELIBERATELY UNDEFINED ----------------------------------------------
 *
 * HAVE_FORKPTY, HAVE_PTY_H, HAVE_LIBUTIL_H, HAVE_UTIL_H*, HAVE_UTEMPTER,
 * HAVE_UTMPX_H  — the server side. iOS has no fork/pty/utmp; the client's
 *                 real PTY is the SwiftTerm side, not this machine.
 * HAVE_PLEDGE    — OpenBSD's pledge(2).
 * HAVE_IP_MTU_DISCOVER — the setter is not in the iOS SDK.
 * HAVE_SYSLOG    — no syslog(3) for apps.
 * USE_OPENSSL_AES / USE_NETTLE_AES — apple-common-crypto is selected.
 *
 * Leaving these undefined is what keeps the client-only build from trying to
 * link server code.
 */
#endif
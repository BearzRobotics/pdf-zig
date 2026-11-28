/* SPDX-License-Identifier: LGPL-2.0-or-later */
/* What pdf_openssl uses of OpenSSL, translated by the build. */
#include <openssl/opensslv.h>

/* The oldest release supported, and the one it is written against: nothing
   newer than 3.5 may be used. */
#if OPENSSL_VERSION_NUMBER < 0x30500000L
#error "pdf_openssl needs OpenSSL 3.5 or later"
#endif

#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/cms.h>
#include <openssl/cmserr.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/objects.h>
#include <openssl/stack.h>
#include <openssl/x509.h>

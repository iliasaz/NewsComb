#ifdef __OBJC__
@import Foundation;

//! Project version number for GRDB.
FOUNDATION_EXPORT double GRDB_VersionNumber;

//! Project version string for GRDB.
FOUNDATION_EXPORT const unsigned char GRDB_VersionString[];
#endif

#ifndef SQLITE_CORE
#define SQLITE_CORE 1
#define _GRDB_UNDEF_SQLITE_CORE
#endif

#import <GRDB/GRDBCustomSQLite-USER.h>
#import <GRDB/sqlite3.h>
#import <GRDB/sqlite3ext.h>
#import "GRDB-Bridging.h"

#ifdef _GRDB_UNDEF_SQLITE_CORE
#undef SQLITE_CORE
#undef _GRDB_UNDEF_SQLITE_CORE
#endif

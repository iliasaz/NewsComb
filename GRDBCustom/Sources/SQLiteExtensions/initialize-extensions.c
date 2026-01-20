#define SQLITE_CORE 1

//#include "extinit.h"
#include <GRDB/sqlite3.h>
#include "sqlite-vec.h"

/// Initializes all SQLite extensions.
int initialize_sqlite3_extensions() {
  // Initialize sqlite-vec: https://github.com/asg017/sqlite-vec
  sqlite3_auto_extension((void *)sqlite3_vec_init);
}

#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"

#include "helix.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(helix_version);

Datum
helix_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(HELIX_VERSION));
}

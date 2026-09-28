// Shim: gives the COstMac target a C source so SPM builds its module.
#include "ostmac_core.h"

// NOTE (R12 ffi-move-now B0): anchor re-pointed at ostmac_free (a STAY
// export) after ostmac_version moved to Swift.
typedef void (*ostmac_free_fn)(char *);
ostmac_free_fn ostmac_shim_anchor(void) { return ostmac_free; }

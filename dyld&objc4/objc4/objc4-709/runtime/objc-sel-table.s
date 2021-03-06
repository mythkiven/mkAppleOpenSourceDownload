#include <TargetConditionals.h>
#include <mach/vm_param.h>

#if __LP64__
# define PTR(x) .quad x
#else
# define PTR(x) .long x
#endif

.section __TEXT,__objc_opt_ro
.align 3
.private_extern __objc_opt_data
__objc_opt_data:
.long 15 /* table.version */
.long 0 /* table.flags */
.long 0 /* table.selopt_offset */
.long 0 /* table.headeropt_ro_offset */
.long 0 /* table.clsopt_offset */	
.long 0 /* table.protocolopt_offset */
.long 0 /* table.headeropt_rw_offset */
.space PAGE_MAX_SIZE-28

/* space for selopt, smax/capacity=524288, blen/mask=262143+1 */
.space 262144    /* mask tab */
.space 524288    /* checkbytes */
.space 524288*4  /* offsets */

/* space for clsopt, smax/capacity=65536, blen/mask=16383+1 */
.space 16384            /* mask tab */
.space 65536            /* checkbytes */
.space 65536*12         /* offsets to name and class and header_info */
.space PAGE_MAX_SIZE    /* some duplicate classes */

/* space for protocolopt, smax/capacity=8192, blen/mask=4095+1 */
.space 4096             /* mask tab */
.space 8192             /* checkbytes */
.space 8192*4           /* offsets */

/* space for header_info (RO) structures */
.space 16384

.section __DATA,__objc_opt_rw
.align 3
.private_extern __objc_opt_rw_data
__objc_opt_rw_data:
/* space for header_info (RW) structures */
.space 16384

/* space for 8192 protocols */
#if __LP64__
.space 8192 * 11 * 8
#else
.space 8192 * 11 * 4
#endif


/* section of pointers that the shared cache optimizer wants to know about */
.section __DATA,__objc_opt_ptrs
.align 3

#if TARGET_OS_OSX  &&  __i386__
// old ABI
.globl .objc_class_name_Protocol
PTR(.objc_class_name_Protocol)
#else
// new ABI
.globl _OBJC_CLASS_$_Protocol
PTR(_OBJC_CLASS_$_Protocol)
#endif

/*
 * Copyright (c) 1999-2007 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/***********************************************************************
* objc-runtime-old.m
* Support for old-ABI classes and images.
**********************************************************************/

/***********************************************************************
 * Class loading and connecting (GrP 2004-2-11)
 *
 * When images are loaded (during program startup or otherwise), the 
 * runtime needs to load classes and categories from the images, connect 
 * classes to superclasses and categories to parent classes, and call 
 * +load methods. 
 * 
 * The Objective-C runtime can cope with classes arriving in any order. 
 * That is, a class may be discovered by the runtime before some 
 * superclass is known. To handle out-of-order class loads, the 
 * runtime uses a "pending class" system. 
 * 
 * (Historical note)
 * Panther and earlier: many classes arrived out-of-order because of 
 *   the poorly-ordered callback from dyld. However, the runtime's 
 *   pending mechanism only handled "missing superclass" and not 
 *   "present superclass but missing higher class". See Radar #3225652. 
 * Tiger: The runtime's pending mechanism was augmented to handle 
 *   arbitrary missing classes. In addition, dyld was rewritten and 
 *   now sends the callbacks in strictly bottom-up link order. 
 *   The pending mechanism may now be needed only for rare and 
 *   hard to construct programs.
 * (End historical note)
 * 
 * A class when first seen in an image is considered "unconnected". 
 * It is stored in `unconnected_class_hash`. If all of the class's 
 * superclasses exist and are already "connected", then the new class 
 * can be connected to its superclasses and moved to `class_hash` for 
 * normal use. Otherwise, the class waits in `unconnected_class_hash` 
 * until the superclasses finish connecting.
 * 
 * A "connected" class is 
 * (1) in `class_hash`, 
 * (2) connected to its superclasses, 
 * (3) has no unconnected superclasses, 
 * (4) is otherwise initialized and ready for use, and 
 * (5) is eligible for +load if +load has not already been called. 
 * 
 * An "unconnected" class is 
 * (1) in `unconnected_class_hash`, 
 * (2) not connected to its superclasses, 
 * (3) has an immediate superclass which is either missing or unconnected, 
 * (4) is not ready for use, and 
 * (5) is not yet eligible for +load.
 * 
 * Image mapping is NOT CURRENTLY THREAD-SAFE with respect to just about 
 *  *  * anything. Image mapping IS RE-ENTRANT in several places: superclass 
 * lookup may cause ZeroLink to load another image, and +load calls may 
 * cause dyld to load another image.
 * 
 * Image mapping sequence:
 * 
 * Read all classes in all new images. 
 *   Add them all to unconnected_class_hash. 
 *   Note any +load implementations before categories are attached.
 *   Fix up any pended classrefs referring to them.
 *   Attach any pending categories.
 * Read all categories in all new images. 
 *   Attach categories whose parent class exists (connected or not), 
 *     and pend the rest.
 *   Mark them all eligible for +load (if implemented), even if the 
 *     parent class is missing.
 * Try to connect all classes in all new images. 
 *   If the superclass is missing, pend the class
 *   If the superclass is unconnected, try to recursively connect it
 *   If the superclass is connected:
 *     connect the class
 *     mark the class eligible for +load, if implemented
 *     connect any pended subclasses of the class
 * Resolve selector refs and class refs in all new images.
 *   Class refs whose classes still do not exist are pended.
 * Fix up protocol objects in all new images.
 * Call +load for classes and categories.
 *   May include classes or categories that are not in these images, 
 *     but are newly eligible because of these image.
 *   Class +loads will be called superclass-first because of the 
 *     superclass-first nature of the connecting process.
 *   Category +load needs to be deferred until the parent class is 
 *     connected and has had its +load called.
 * 
 * Performance: all classes are read before any categories are read. 
 * Fewer categories need be pended for lack of a parent class.
 * 
 * Performance: all categories are attempted to be attached before 
 * any classes are connected. Fewer class caches need be flushed. 
 * (Unconnected classes and their respective subclasses are guaranteed 
 * to be un-messageable, so their caches will be empty.)
 * 
 * Performance: all classes are read before any classes are connected. 
 * Fewer classes need be pended for lack of a superclass.
 * 
 * Correctness: all selector and class refs are fixed before any 
 * protocol fixups or +load methods. libobjc itself contains selector 
 * and class refs which are used in protocol fixup and +load.
 * 
 * Correctness: +load methods are scheduled in bottom-up link order. 
 * This constraint is in addition to superclass order. Some +load 
 * implementations expect to use another class in a linked-to library, 
 * even if the two classes don't share a direct superclass relationship.
 * 
 * Correctness: all classes are scanned for +load before any categories 
 * are attached. Otherwise, if a category implements +load and its class 
 * has no class methods, the class's +load scan would find the category's 
 * +load method, which would then be called twice.
 * 
 **********************************************************************/

#if !__OBJC2__

#include <mach/mach.h>
#include <mach-o/ldsyms.h>
#include <mach-o/dyld.h>
#include <assert.h>

#define OLD 1
#import "objc-private.h"
#import "objc-loadmethod.h"
#import "hashtable2.h"
#import "maptable.h"

/* NXHashTable SPI */
extern unsigned _NXHashCapacity(NXHashTable *table);
extern void _NXHashRehashToCapacity(NXHashTable *table, unsigned newCapacity);


typedef struct _objc_unresolved_category
{
    struct _objc_unresolved_category *next;
    struct old_category *cat;  // may be NULL
    long version;
} _objc_unresolved_category;

typedef struct _PendingSubclass
{
    struct old_class *subclass;  // subclass to finish connecting; may be NULL
    struct _PendingSubclass *next;
} PendingSubclass;

typedef struct _PendingClassRef
{
    struct old_class **ref;  // class reference to fix up; may be NULL
                             // (ref & 1) is a metaclass reference
    struct _PendingClassRef *next;
} PendingClassRef;


static uintptr_t classHash(void *info, Class data);
static int classIsEqual(void *info, Class name, Class cls);
static int _objc_defaultClassHandler(const char *clsName);
static BOOL class_is_connected(struct old_class *cls);
static inline NXMapTable *pendingClassRefsMapTable(void);
static inline NXMapTable *pendingSubclassesMapTable(void);
static void pendClassInstallation(struct old_class *cls, const char *superName);
static void pendClassReference(struct old_class **ref, const char *className, BOOL isMeta);
static void resolve_references_to_class(struct old_class *cls);
static void resolve_subclasses_of_class(struct old_class *cls);
static void really_connect_class(struct old_class *cls, struct old_class *supercls);
static BOOL connect_class(struct old_class *cls);
static inline BOOL map_selrefs(SEL *src, SEL *dst, size_t size, BOOL copy);
static void  map_method_descs (struct objc_method_description_list * methods, BOOL copy);
static void _objcTweakMethodListPointerForClass(struct old_class *cls);
static inline void _objc_add_category(struct old_class *cls, struct old_category *category, int version);
static BOOL _objc_add_category_flush_caches(struct old_class *cls, struct old_category *category, int version);
static _objc_unresolved_category *reverse_cat(_objc_unresolved_category *cat);
static void resolve_categories_for_class(struct old_class *cls);
static BOOL _objc_register_category(struct old_category *cat, int version);


// Function called when a class is loaded from an image
__private_extern__ void (*callbackFunction)(Class, const char *) = 0;

// Lock for class and protocol hashtables
// classLock > cacheUpdateLock
__private_extern__ OBJC_DECLARE_LOCK (classLock);

// Hash table of classes
__private_extern__ NXHashTable *		class_hash NOBSS = 0;
static NXHashTablePrototype	classHashPrototype =
{
    (uintptr_t (*) (const void *, const void *))			classHash,
    (int (*)(const void *, const void *, const void *))	classIsEqual,
    NXNoEffectFree, 0
};

// Hash table of unconnected classes
static NXHashTable *unconnected_class_hash NOBSS = NULL;

// Exported copy of class_hash variable (hook for debugging tools)
NXHashTable *_objc_debug_class_hash = NULL;

// Category and class registries
// Keys are COPIES of strings, to prevent stale pointers with unloaded bundles
// Use NXMapKeyCopyingInsert and NXMapKeyFreeingRemove
static NXMapTable *		category_hash = NULL;

// Keys are COPIES of strings, to prevent stale pointers with unloaded bundles
// Use NXMapKeyCopyingInsert and NXMapKeyFreeingRemove
static NXMapTable *		pendingClassRefsMap = NULL;
static NXMapTable *		pendingSubclassesMap = NULL;

// Protocols
static NXMapTable *protocol_map = NULL;      // name -> protocol
static NXMapTable *protocol_ext_map = NULL;  // protocol -> protocol ext

// Function pointer objc_getClass calls through when class is not found
static int			(*objc_classHandler) (const char *) = _objc_defaultClassHandler;

// Function pointer called by objc_getClass and objc_lookupClass when 
// class is not found. _objc_classLoader is called before objc_classHandler.
static BOOL (*_objc_classLoader)(const char *) = NULL;


/***********************************************************************
* inform_duplicate. Complain about duplicate class implementations.
**********************************************************************/
static void inform_duplicate(struct old_class *oldCls, struct old_class *cls)
{
    const header_info *oldHeader = _headerForClass((Class)oldCls);
    const header_info *newHeader = _headerForClass((Class)cls);
    const char *oldName = _nameForHeader(oldHeader->mhdr);
    const char *newName = _nameForHeader(newHeader->mhdr);
        
    _objc_inform ("Class %s is implemented in both %s and %s. "
                  "Using implementation from %s.",
                  oldCls->name, oldName, newName, newName);
}


/***********************************************************************
* objc_dump_class_hash.  Log names of all known classes.
**********************************************************************/
__private_extern__ void objc_dump_class_hash(void)
{
    NXHashTable *table;
    unsigned count;
    Class data;
    NXHashState state;

    table = class_hash;
    count = 0;
    state = NXInitHashState (table);
    while (NXNextHashState (table, &state, (void **) &data))
        printf ("class %d: %s\n", ++count, _class_getName(data));
}


/***********************************************************************
* _objc_init_class_hash.  Return the class lookup table, create it if
* necessary.
**********************************************************************/
__private_extern__ void _objc_init_class_hash(void)
{
    // Do nothing if class hash table already exists
    if (class_hash)
        return;

    // class_hash starts small, with only enough capacity for libobjc itself. 
    // If a second library is found by map_images(), class_hash is immediately 
    // resized to capacity 1024 to cut down on rehashes. 
    // Old numbers: A smallish Foundation+AppKit program will have
    // about 520 classes.  Larger apps (like IB or WOB) have more like
    // 800 classes.  Some customers have massive quantities of classes.
    // Foundation-only programs aren't likely to notice the ~6K loss.
    class_hash = NXCreateHashTableFromZone (classHashPrototype,
                                            16,
                                            nil,
                                            _objc_internal_zone ());
    _objc_debug_class_hash = class_hash;
}


/***********************************************************************
* objc_getClassList.  Return the known classes.
**********************************************************************/
int objc_getClassList(Class *buffer, int bufferLen) 
{
    NXHashState state;
    Class class;
    int cnt, num;

    OBJC_LOCK(&classLock);
    num = NXCountHashTable(class_hash);
    if (NULL == buffer) {
        OBJC_UNLOCK(&classLock);
        return num;
    }
    cnt = 0;
    state = NXInitHashState(class_hash);
    while (cnt < bufferLen  &&  
           NXNextHashState(class_hash, &state, (void **)&class)) 
    {
        buffer[cnt++] = class;
    }
    OBJC_UNLOCK(&classLock);
    return num;
}


/***********************************************************************
* objc_copyProtocolList
* Returns pointers to all protocols.
* Locking: acquires classLock
**********************************************************************/
Protocol **
objc_copyProtocolList(unsigned int *outCount) 
{
    OBJC_LOCK(&classLock);

    int count, i;
    Protocol *proto;
    const char *name;
    NXMapState state;
    Protocol **result;

    count = NXCountMapTable(protocol_map);
    if (count == 0) {
        OBJC_UNLOCK(&classLock);
        if (outCount) *outCount = 0;
        return NULL;
    }

    result = calloc(1 + count, sizeof(Protocol *));

    i = 0;
    state = NXInitMapState(protocol_map);
    while (NXNextMapState(protocol_map, &state, 
                          (const void **)&name, (const void **)&proto))
    {
        result[i++] = proto;
    }
    
    result[i++] = NULL;
    assert(i == count+1);

    OBJC_UNLOCK(&classLock);

    if (outCount) *outCount = count;
    return result;
}


/***********************************************************************
* objc_getClasses.  Return class lookup table.
*
* NOTE: This function is very dangerous, since you cannot safely use
* the hashtable without locking it, and the lock is private!
**********************************************************************/
void *objc_getClasses(void)
{
    OBJC_WARN_DEPRECATED;

    // Return the class lookup hash table
    return class_hash;
}


/***********************************************************************
* classHash.
**********************************************************************/
static uintptr_t classHash(void *info, Class data)
{
    // Nil classes hash to zero
    if (!data)
        return 0;

    // Call through to real hash function
    return _objc_strhash (_class_getName(data));
}

/***********************************************************************
* classIsEqual.  Returns whether the class names match.  If we ever
* check more than the name, routines like objc_lookUpClass have to
* change as well.
**********************************************************************/
static int classIsEqual(void *info, Class name, Class cls)
{
    // Standard string comparison
    // Our local inlined version is significantly shorter on PPC and avoids the
    // mflr/mtlr and dyld_stub overhead when calling strcmp.
    return _objc_strcmp(_class_getName(name), _class_getName(cls)) == 0;
}


// Unresolved future classes
static NXHashTable *future_class_hash = NULL;

// Resolved future<->original classes
static NXMapTable *future_class_to_original_class_map = NULL;
static NXMapTable *original_class_to_future_class_map = NULL;

// CF requests about 20 future classes; HIToolbox requests one.
#define FUTURE_COUNT 32


/***********************************************************************
* setOriginalClassForFutureClass
* Record resolution of a future class. 
**********************************************************************/
static void setOriginalClassForFutureClass(struct old_class *futureClass, 
                                           struct old_class *originalClass)
{
    if (!future_class_to_original_class_map) {
        future_class_to_original_class_map =
            NXCreateMapTableFromZone (NXPtrValueMapPrototype, FUTURE_COUNT, 
                                      _objc_internal_zone ());
        original_class_to_future_class_map =
            NXCreateMapTableFromZone (NXPtrValueMapPrototype, FUTURE_COUNT, 
                                      _objc_internal_zone ());
    }

    NXMapInsert (future_class_to_original_class_map,
                 futureClass, originalClass);
    NXMapInsert (original_class_to_future_class_map,
                 originalClass, futureClass);

    if (PrintFuture) {
        _objc_inform("FUTURE: using %p instead of %p for %s", futureClass, originalClass, originalClass->name);
    }
}

/***********************************************************************
* getOriginalClassForFutureClass
* getFutureClassForOriginalClass
* Switch between a future class and its corresponding original class.
* The future class is the one actually in use.
* The original class is the one from disk.
**********************************************************************/
/*
static struct old_class *
getOriginalClassForFutureClass(struct old_class *futureClass)
{
    if (!future_class_to_original_class_map) return Nil;
    return NXMapGet (future_class_to_original_class_map, futureClass);
}
*/
static struct old_class *
getFutureClassForOriginalClass(struct old_class *originalClass)
{
    if (!original_class_to_future_class_map) return Nil;
    return NXMapGet (original_class_to_future_class_map, originalClass);
}


/***********************************************************************
* makeFutureClass
* Initialize the memory in *cls with an unresolved future class with the 
* given name. The memory is recorded in future_class_hash.
**********************************************************************/
static void makeFutureClass(struct old_class *cls, const char *name)
{
    // CF requests about 20 future classes, plus HIToolbox has one.
    if (!future_class_hash) {
        future_class_hash = 
            NXCreateHashTableFromZone(classHashPrototype, FUTURE_COUNT, 
                                      NULL, _objc_internal_zone());
    }

    cls->name = _strdup_internal(name);
    NXHashInsert(future_class_hash, cls);

    if (PrintFuture) {
        _objc_inform("FUTURE: reserving %p for %s", cls, name);
    }
}


/***********************************************************************
* _objc_allocateFutureClass
* Allocate an unresolved future class for the given class name.
* Returns any existing allocation if one was already made.
* Assumes the named class doesn't exist yet.
* Not thread safe.
**********************************************************************/
__private_extern__ Class _objc_allocateFutureClass(const char *name)
{
    struct old_class *cls;

    if (future_class_hash) {
        struct old_class query;
        query.name = name;
        if ((cls = NXHashGet(future_class_hash, &query))) {
            // Already have a future class for this name.
            return (Class)cls;
        }
    } 

    cls = _calloc_internal(sizeof(*cls), 1);
    makeFutureClass(cls, name);
    return (Class)cls;
}


/***********************************************************************
* objc_setFutureClass.  
* Like objc_getFutureClass, but uses the provided memory block. 
* If the class already exists, a posing-like substitution is performed.
* Not thread safe.
**********************************************************************/
void objc_setFutureClass(Class cls, const char *name)
{
    struct old_class *oldcls;
    struct old_class *newcls = (struct old_class *)cls;  // Not a real class!

    if ((oldcls = _class_asOld(look_up_class(name, NO/*unconnected*/, NO/*classhandler*/)))) {
        setOriginalClassForFutureClass(newcls, oldcls);
        // fixme hack
        memcpy(newcls, oldcls, sizeof(struct objc_class));
        newcls->info &= ~CLS_EXT;

        OBJC_LOCK(&classLock);
        NXHashRemove(class_hash, oldcls);
        change_class_references(newcls, oldcls, nil, YES);
        NXHashInsert(class_hash, newcls);
        OBJC_UNLOCK(&classLock);
    } else {
        makeFutureClass(newcls, name);
    }
}


/***********************************************************************
* _objc_defaultClassHandler.  Default objc_classHandler.  Does nothing.
**********************************************************************/
static int _objc_defaultClassHandler(const char *clsName)
{
    // Return zero so objc_getClass doesn't bother re-searching
    return 0;
}

/***********************************************************************
* objc_setClassHandler.  Set objc_classHandler to the specified value.
*
* NOTE: This should probably deal with userSuppliedHandler being NULL,
* because the objc_classHandler caller does not check... it would bus
* error.  It would make sense to handle NULL by restoring the default
* handler.  Is anyone hacking with this, though?
**********************************************************************/
void objc_setClassHandler(int (*userSuppliedHandler)(const char *))
{
    OBJC_WARN_DEPRECATED;

    objc_classHandler = userSuppliedHandler;
}


/***********************************************************************
* _objc_setClassLoader
* Similar to objc_setClassHandler, but objc_classLoader is used for 
* both objc_getClass() and objc_lookupClass(), and objc_classLoader 
* pre-empts objc_classHandler. 
**********************************************************************/
void _objc_setClassLoader(BOOL (*newClassLoader)(const char *))
{
    _objc_classLoader = newClassLoader;
}


/***********************************************************************
* objc_getProtocol
* Get a protocol by name, or NULL.
**********************************************************************/
Protocol *objc_getProtocol(const char *name)
{
    Protocol *result;
    if (!protocol_map) return NULL;
    OBJC_LOCK(&classLock);
    result = (Protocol *)NXMapGet(protocol_map, name);
    OBJC_UNLOCK(&classLock);
    return result;
}


/***********************************************************************
* look_up_class
* Map a class name to a class using various methods.
* This is the common implementation of objc_lookUpClass and objc_getClass, 
* and is also used internally to get additional search options.
* Sequence:
* 1. class_hash
* 2. unconnected_class_hash (optional)
* 3. classLoader callback
* 4. classHandler callback (optional)
**********************************************************************/
__private_extern__ id look_up_class(const char *aClassName, BOOL includeUnconnected, BOOL includeClassHandler)
{
    BOOL includeClassLoader = YES; // class loader cannot be skipped
    id result = nil;
    struct old_class query;

    query.name = aClassName;

 retry:

    if (!result  &&  class_hash) {
        // Check ordinary classes
        OBJC_LOCK (&classLock);
        result = (id)NXHashGet(class_hash, &query);
        OBJC_UNLOCK (&classLock);
    }

    if (!result  &&  includeUnconnected  &&  unconnected_class_hash) {
        // Check not-yet-connected classes
        OBJC_LOCK(&classLock);
        result = (id)NXHashGet(unconnected_class_hash, &query);
        OBJC_UNLOCK(&classLock);
    }

    if (!result  &&  includeClassLoader  &&  _objc_classLoader) {
        // Try class loader callback
        if ((*_objc_classLoader)(aClassName)) {
            // Re-try lookup without class loader
            includeClassLoader = NO;
            goto retry;
        }
    }

    if (!result  &&  includeClassHandler  &&  objc_classHandler) {
        // Try class handler callback
        if ((*objc_classHandler)(aClassName)) {
            // Re-try lookup without class handler or class loader
            includeClassLoader = NO;
            includeClassHandler = NO;
            goto retry;
        }
    }

    return result;
}


/***********************************************************************
* class_is_connected.
* Returns TRUE if class cls is connected. 
* A connected class has either a connected superclass or a NULL superclass, 
* and is present in class_hash.
**********************************************************************/
static BOOL class_is_connected(struct old_class *cls)
{
    BOOL result;
    OBJC_LOCK(&classLock);
    result = NXHashMember(class_hash, cls);
    OBJC_UNLOCK(&classLock);
    return result;
}


/***********************************************************************
* _class_isLoadable.
* Returns TRUE if class cls is ready for its +load method to be called. 
* A class is ready for +load if it is connected.
**********************************************************************/
__private_extern__ BOOL _class_isLoadable(Class cls)
{
    return class_is_connected(_class_asOld(cls));
}


/***********************************************************************
* pendingClassRefsMapTable.  Return a pointer to the lookup table for
* pending class refs.
**********************************************************************/
static inline NXMapTable *pendingClassRefsMapTable(void)
{
    // Allocate table if needed
    if (!pendingClassRefsMap) {
        pendingClassRefsMap = 
            NXCreateMapTableFromZone(NXStrValueMapPrototype, 
                                     10, _objc_internal_zone ());
    }
    
    // Return table pointer
    return pendingClassRefsMap;
}


/***********************************************************************
* pendingSubclassesMapTable.  Return a pointer to the lookup table for
* pending subclasses.
**********************************************************************/
static inline NXMapTable *pendingSubclassesMapTable(void)
{
    // Allocate table if needed
    if (!pendingSubclassesMap) {
        pendingSubclassesMap = 
            NXCreateMapTableFromZone(NXStrValueMapPrototype, 
                                     10, _objc_internal_zone ());
    }
    
    // Return table pointer
    return pendingSubclassesMap;
}


/***********************************************************************
* pendClassInstallation
* Finish connecting class cls when its superclass becomes connected.
* Check for multiple pends of the same class because connect_class does not.
**********************************************************************/
static void pendClassInstallation(struct old_class *cls, const char *superName)
{
    NXMapTable *table;
    PendingSubclass *pending;
    PendingSubclass *oldList;
    PendingSubclass *l;
    
    // Create and/or locate pending class lookup table
    table = pendingSubclassesMapTable ();

    // Make sure this class isn't already in the pending list.
    oldList = NXMapGet (table, superName);
    for (l = oldList; l != NULL; l = l->next) {
        if (l->subclass == cls) return;  // already here, nothing to do
    }
    
    // Create entry referring to this class
    pending = _malloc_internal(sizeof(PendingSubclass));
    pending->subclass = cls;
    
    // Link new entry into head of list of entries for this class
    pending->next = oldList;
    
    // (Re)place entry list in the table
    (void) NXMapKeyCopyingInsert (table, superName, pending);
}


/***********************************************************************
* pendClassReference
* Fix up a class ref when the class with the given name becomes connected.
**********************************************************************/
static void pendClassReference(struct old_class **ref, const char *className, BOOL isMeta)
{
    NXMapTable *table;
    PendingClassRef *pending;
    
    // Create and/or locate pending class lookup table
    table = pendingClassRefsMapTable ();
    
    // Create entry containing the class reference
    pending = _malloc_internal(sizeof(PendingClassRef));
    pending->ref = ref;
    if (isMeta) {
        pending->ref = (struct old_class **)((uintptr_t)pending->ref | 1);
    }
    
    // Link new entry into head of list of entries for this class
    pending->next = NXMapGet (table, className);
    
    // (Re)place entry list in the table
    (void) NXMapKeyCopyingInsert (table, className, pending);

    if (PrintConnecting) {
        _objc_inform("CONNECT: pended reference to class '%s%s' at %p", 
                     className, isMeta ? " (meta)" : "", (void *)ref);
    }
}


/***********************************************************************
* resolve_references_to_class
* Fix up any pending class refs to this class.
**********************************************************************/
static void resolve_references_to_class(struct old_class *cls)
{
    PendingClassRef *pending;
    
    if (!pendingClassRefsMap) return;  // no unresolved refs for any class

    pending = NXMapGet(pendingClassRefsMap, cls->name); 
    if (!pending) return;  // no unresolved refs for this class

    NXMapKeyFreeingRemove(pendingClassRefsMap, cls->name);

    if (PrintConnecting) {
        _objc_inform("CONNECT: resolving references to class '%s'", cls->name);
    }

    while (pending) {
        PendingClassRef *next = pending->next;
        if (pending->ref) {
            BOOL isMeta = ((uintptr_t)pending->ref & 1) ? YES : NO;
            struct old_class **ref = 
                (struct old_class **)((uintptr_t)pending->ref & ~(uintptr_t)1);
            *ref = isMeta ? cls->isa : cls;
        }
        _free_internal(pending);
        pending = next;
    }

    if (NXCountMapTable(pendingClassRefsMap) == 0) {
        NXFreeMapTable(pendingClassRefsMap);
        pendingClassRefsMap = NULL;
    }
}


/***********************************************************************
* resolve_subclasses_of_class
* Fix up any pending subclasses of this class.
**********************************************************************/
static void resolve_subclasses_of_class(struct old_class *cls)
{
    PendingSubclass *pending;
    
    if (!pendingSubclassesMap) return;  // no unresolved subclasses 

    pending = NXMapGet(pendingSubclassesMap, cls->name); 
    if (!pending) return;  // no unresolved subclasses for this class

    NXMapKeyFreeingRemove(pendingSubclassesMap, cls->name);

    // Destroy the pending table if it's now empty, to save memory.
    if (NXCountMapTable(pendingSubclassesMap) == 0) {
        NXFreeMapTable(pendingSubclassesMap);
        pendingSubclassesMap = NULL;
    }

    if (PrintConnecting) {
        _objc_inform("CONNECT: resolving subclasses of class '%s'", cls->name);
    }

    while (pending) {
        PendingSubclass *next = pending->next;
        if (pending->subclass) connect_class(pending->subclass);
        _free_internal(pending);
        pending = next;
    }
}


/***********************************************************************
* really_connect_class
* Connect cls to superclass supercls unconditionally.
* Also adjust the class hash tables and handle pended subclasses.
*
* This should be called from connect_class() ONLY.
**********************************************************************/
static void really_connect_class(struct old_class *cls,
                                 struct old_class *supercls)
{
    struct old_class *oldCls;

    // Connect superclass pointers.
    set_superclass(cls, supercls);

    // Update GC layouts
    // For paranoia, this is a conservative update: only non-strong -> strong
    // is corrected. Any bugs will be leaks instead of crashes. 
    // rdar://5791689 covers any less-paranoid more-complete fix.
    if (UseGC  &&  supercls  &&  
        (cls->info & CLS_EXT)  &&  (supercls->info & CLS_EXT)) 
    {
        BOOL layoutsChanged = NO;
        layout_bitmap ivarBitmap = 
            layout_bitmap_create(cls->ivar_layout, 
                                 cls->instance_size, 
                                 cls->instance_size, NO);

        layout_bitmap superBitmap = 
            layout_bitmap_create(supercls->ivar_layout, 
                                 supercls->instance_size, 
                                 supercls->instance_size, NO);
        layoutsChanged |= layout_bitmap_or(ivarBitmap, superBitmap, cls->name);
        layout_bitmap_free(superBitmap);
                
        if (layoutsChanged) {
            // Rebuild layout strings. 
            if (PrintIvars) {
                _objc_inform("IVARS: gc layout changed for class %s (super %s)",
                             cls->name, supercls->name);
            }
            cls->ivar_layout = layout_string_create(ivarBitmap);
        }
        
        layout_bitmap_free(ivarBitmap);
    }

    // Done!
    cls->info |= CLS_CONNECTED;

    OBJC_LOCK(&classLock);

    // Update hash tables. 
    NXHashRemove(unconnected_class_hash, cls);
    oldCls = NXHashInsert(class_hash, cls);

    // Delete unconnected_class_hash if it is now empty.
    if (NXCountHashTable(unconnected_class_hash) == 0) {
        NXFreeHashTable(unconnected_class_hash);
        unconnected_class_hash = NULL;
    }

    OBJC_UNLOCK(&classLock);

    // Warn if the new class has the same name as a previously-installed class.
    // The new class is kept and the old class is discarded.
    if (oldCls) {
        inform_duplicate(oldCls, cls);
    }
 
    // Connect newly-connectable subclasses
    resolve_subclasses_of_class(cls);

    // GC debugging: make sure all classes with -dealloc also have -finalize
    if (DebugFinalizers) {
        extern IMP findIMPInClass(struct old_class *cls, SEL sel);
        if (findIMPInClass(cls, sel_getUid("dealloc"))  &&  
            ! findIMPInClass(cls, sel_getUid("finalize")))
        {
            _objc_inform("GC: class '%s' implements -dealloc but not -finalize", cls->name);
        }
    }

    // Debugging: if this class has ivars, make sure this class's ivars don't 
    // overlap with its super's. This catches some broken fragile base classes.
    // Do not use super->instance_size vs. self->ivar[0] to check this. 
    // Ivars may be packed across instance_size boundaries.
    if (DebugFragileSuperclasses  &&  cls->ivars  &&  cls->ivars->ivar_count) {
        struct old_class *ivar_cls = supercls;

        // Find closest superclass that has some ivars, if one exists.
        while (ivar_cls  &&  
               (!ivar_cls->ivars || ivar_cls->ivars->ivar_count == 0))
        {
            ivar_cls = ivar_cls->super_class;
        }

        if (ivar_cls) {
            // Compare superclass's last ivar to this class's first ivar
            struct old_ivar *super_ivar = 
                &ivar_cls->ivars->ivar_list[ivar_cls->ivars->ivar_count - 1];
            struct old_ivar *self_ivar = 
                &cls->ivars->ivar_list[0];

            // fixme could be smarter about super's ivar size
            if (self_ivar->ivar_offset <= super_ivar->ivar_offset) {
                _objc_inform("WARNING: ivars of superclass '%s' and "
                             "subclass '%s' overlap; superclass may have "
                             "changed since subclass was compiled", 
                             ivar_cls->name, cls->name);
            }
        }
    }
}


/***********************************************************************
* connect_class
* Connect class cls to its superclasses, if possible.
* If cls becomes connected, move it from unconnected_class_hash 
*   to connected_class_hash.
* Returns TRUE if cls is connected.
* Returns FALSE if cls could not be connected for some reason 
*   (missing superclass or still-unconnected superclass)
**********************************************************************/
static BOOL connect_class(struct old_class *cls)
{
    if (class_is_connected(cls)) {
        // This class is already connected to its superclass.
        // Do nothing.
        return TRUE;
    }
    else if (cls->super_class == NULL) {
        // This class is a root class. 
        // Connect it to itself. 

        if (PrintConnecting) {
            _objc_inform("CONNECT: class '%s' now connected (root class)", 
                        cls->name);
        }

        really_connect_class(cls, NULL);
        return TRUE;
    }
    else {
        // This class is not a root class and is not yet connected.
        // Connect it if its superclass and root class are already connected. 
        // Otherwise, add this class to the to-be-connected list, 
        // pending the completion of its superclass and root class.

        // At this point, cls->super_class and cls->isa->isa are still STRINGS
        char *supercls_name = (char *)cls->super_class;
        struct old_class *supercls;

        // YES unconnected, YES class handler
        if (NULL == (supercls = _class_asOld(look_up_class(supercls_name, YES, YES)))) {
            // Superclass does not exist yet.
            // pendClassInstallation will handle duplicate pends of this class
            pendClassInstallation(cls, supercls_name);

            if (PrintConnecting) {
                _objc_inform("CONNECT: class '%s' NOT connected (missing super)", cls->name);
            }
            return FALSE;
        }
        
        if (! connect_class(supercls)) {
            // Superclass exists but is not yet connected.
            // pendClassInstallation will handle duplicate pends of this class
            pendClassInstallation(cls, supercls_name);

            if (PrintConnecting) {
                _objc_inform("CONNECT: class '%s' NOT connected (unconnected super)", cls->name);
            }
            return FALSE;
        }

        // Superclass exists and is connected. 
        // Connect this class to the superclass.
        
        if (PrintConnecting) {
            _objc_inform("CONNECT: class '%s' now connected", cls->name);
        }

        really_connect_class(cls, supercls);
        return TRUE;
    } 
}


/***********************************************************************
* _objc_read_categories_from_image.
* Read all categories from the given image. 
* Install them on their parent classes, or register them for later 
*   installation. 
* Returns YES if some method caches now need to be flushed.
**********************************************************************/
static BOOL _objc_read_categories_from_image (header_info *  hi)
{
    Module		mods;
    size_t	midx;
    BOOL needFlush = NO;

    if (_objcHeaderIsReplacement(hi)) {
        // Ignore any categories in this image
        return NO;
    }


    // Major loop - process all modules in the header
    mods = hi->mod_ptr;

    // NOTE: The module and category lists are traversed backwards 
    // to preserve the pre-10.4 processing order. Changing the order 
    // would have a small chance of introducing binary compatibility bugs.
    midx = hi->mod_count;
    while (midx-- > 0) {
        unsigned int	index;
        unsigned int	total;
        
        // Nothing to do for a module without a symbol table
        if (mods[midx].symtab == NULL)
            continue;
        
        // Total entries in symbol table (class entries followed
        // by category entries)
        total = mods[midx].symtab->cls_def_cnt +
            mods[midx].symtab->cat_def_cnt;
        
        // Minor loop - register all categories from given module
        index = total;
        while (index-- > mods[midx].symtab->cls_def_cnt) {
            struct old_category *cat = mods[midx].symtab->defs[index];
            needFlush |= _objc_register_category(cat, (int)mods[midx].version);
        }
    }

    return needFlush;
}


/***********************************************************************
* _objc_read_classes_from_image.
* Read classes from the given image, perform assorted minor fixups, 
*   scan for +load implementation.
* Does not connect classes to superclasses. 
* Does attach pended categories to the classes.
* Adds all classes to unconnected_class_hash. class_hash is unchanged.
**********************************************************************/
static void _objc_read_classes_from_image(header_info *hi)
{
    unsigned int	index;
    unsigned int	midx;
    Module		mods;
    int 		isBundle = (hi->mhdr->filetype == MH_BUNDLE);

    if (_objcHeaderIsReplacement(hi)) {
        // Ignore any classes in this image
        return;
    }

    // class_hash starts small, enough only for libobjc itself. 
    // If other Objective-C libraries are found, immediately resize 
    // class_hash, assuming that Foundation and AppKit are about 
    // to add lots of classes.
    OBJC_LOCK(&classLock);
    if (hi->mhdr != (headerType *)&_mh_dylib_header && _NXHashCapacity(class_hash) < 1024) {
        _NXHashRehashToCapacity(class_hash, 1024);
    }
    OBJC_UNLOCK(&classLock);

    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;

        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            struct old_class *newCls, *oldCls;

            // Locate the class description pointer
            newCls = mods[midx].symtab->defs[index];

            // Classes loaded from Mach-O bundles can be unloaded later.
            // Nothing uses this class yet, so _class_setInfo is not needed.
            if (isBundle) newCls->info |= CLS_FROM_BUNDLE;
            if (isBundle) newCls->isa->info |= CLS_FROM_BUNDLE;

            // Use common static empty cache instead of NULL
            if (newCls->cache == NULL)
                newCls->cache = (Cache) &_objc_empty_cache;
            if (newCls->isa->cache == NULL)
                newCls->isa->cache = (Cache) &_objc_empty_cache;

            // Set metaclass version
            newCls->isa->version = mods[midx].version;

            // methodLists is NULL or a single list, not an array
            newCls->info |= CLS_NO_METHOD_ARRAY|CLS_NO_PROPERTY_ARRAY;
            newCls->isa->info |= CLS_NO_METHOD_ARRAY|CLS_NO_PROPERTY_ARRAY;

            // class has no subclasses for cache flushing
            newCls->info |= CLS_LEAF;
            newCls->isa->info |= CLS_LEAF;

            if (mods[midx].version >= 6) {
                // class structure has ivar_layout and ext fields
                newCls->info |= CLS_EXT;
                newCls->isa->info |= CLS_EXT;
            }

            // Check for +load implementation before categories are attached
            if (_class_hasLoadMethod((Class)newCls)) {
                newCls->isa->info |= CLS_HAS_LOAD_METHOD;
            }
            
            // Install into unconnected_class_hash.
            OBJC_LOCK(&classLock);

            if (future_class_hash) {
                struct old_class *futureCls =
                    NXHashRemove(future_class_hash, newCls);
                if (futureCls) {
                    // Another class structure for this class was already 
                    // prepared by objc_getFutureClass(). Use it instead.
                    _free_internal((char *)futureCls->name);
                    memcpy(futureCls, newCls, sizeof(*newCls));
                    setOriginalClassForFutureClass(futureCls, newCls);
                    newCls = futureCls;

                    if (NXCountHashTable(future_class_hash) == 0) {
                        NXFreeHashTable(future_class_hash);
                        future_class_hash = NULL;
                    }
                }
            }

            if (!unconnected_class_hash) {
                unconnected_class_hash = 
                    NXCreateHashTableFromZone(classHashPrototype, 128, 
                                              NULL, _objc_internal_zone());
            }

            oldCls = NXHashInsert(unconnected_class_hash, newCls); 
            if (oldCls) {
                // Duplicate classes loaded. 
                // newCls has been inserted over oldCls, 
                // same as really_connect_class
                inform_duplicate(oldCls, newCls);
            }

            OBJC_UNLOCK(&classLock);

            // Fix up pended class refs to this class, if any
            resolve_references_to_class(newCls);

            // Attach pended categories for this class, if any
            resolve_categories_for_class(newCls);
        }
    }
}


/***********************************************************************
* _objc_connect_classes_from_image.
* Connect the classes in the given image to their superclasses,
* or register them for later connection if any superclasses are missing.
**********************************************************************/
static void _objc_connect_classes_from_image(header_info *hi)
{
    unsigned int index;
    unsigned int midx;
    Module mods;
    BOOL replacement = _objcHeaderIsReplacement(hi);

    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;

        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            struct old_class *cls = mods[midx].symtab->defs[index];
            if (! replacement) {
                BOOL connected;
                struct old_class *futureCls = getFutureClassForOriginalClass(cls);
                if (futureCls) {
                    // objc_getFutureClass() requested a different class 
                    // struct. Fix up the original struct's super_class 
                    // field for [super ...] use, but otherwise perform 
                    // fixups on the new class struct only.
                    const char *super_name = (const char *) cls->super_class;
                    if (super_name) cls->super_class = _class_asOld(objc_getClass(super_name));
                    cls = futureCls;
                }
                connected = connect_class(cls);
                if (connected  &&  callbackFunction) {
                    (*callbackFunction)((Class)cls, 0);
                }
            } else {
                // Replacement image - fix up super_class only (#3704817)
                // And metaclass's super_class (#5351107)
                const char *super_name = (const char *) cls->super_class;
                if (super_name) {
                    cls->super_class = _class_asOld(objc_getClass(super_name));
                    // metaclass's superclass is superclass's metaclass
                    cls->isa->super_class = cls->super_class->isa;
                } else {
                    // Replacement for a root class
                    // cls->super_class already NULL
                    // root metaclass's superclass is root class
                    cls->isa->super_class = cls;
                }
            }
        }
    }
}


/***********************************************************************
* _objc_map_class_refs_for_image.  Convert the class ref entries from
* a class name string pointer to a class pointer.  If the class does
* not yet exist, the reference is added to a list of pending references
* to be fixed up at a later date.
**********************************************************************/
static void fix_class_ref(struct old_class **ref, const char *name, BOOL isMeta)
{
    struct old_class *cls;

    // Get pointer to class of this name
    // YES unconnected, YES class loader
    cls = _class_asOld(look_up_class(name, YES, YES));
    if (cls) {
        // Referenced class exists. Fix up the reference.
        *ref = isMeta ? cls->isa : cls;
    } else {
        // Referenced class does not exist yet. Insert a placeholder 
        // class and fix up the reference later.
        pendClassReference (ref, name, isMeta);
        *ref = (struct old_class *)_class_getNonexistentObjectClass();
    }
}

static void _objc_map_class_refs_for_image (header_info * hi)
{
    struct old_class **cls_refs;
    size_t	count;
    unsigned int	index;

    // Locate class refs in image
    cls_refs = _getObjcClassRefs (hi, &count);
    if (cls_refs) {
        // Process each class ref
        for (index = 0; index < count; index += 1) {
            // Ref is initially class name char*
            const char *name = (const char *) cls_refs[index];
            if (name == NULL) {
                // rdar://5453039 is the entire page zero, or just this pointer
                uintptr_t *p = (uintptr_t *)(((uintptr_t)&cls_refs[index]) & ~0xfff);
                uintptr_t *end = (uintptr_t *)(((uintptr_t)p)+0x1000);
                int clear = 1;
                for ( ; p < end; p++) {
                    if (*p != 0) {
                        clear = 0; 
                        break;
                    }
                }
                _objc_inform_on_crash("rdar://5453039 page around %p IS%s clear", 
                                      &cls_refs[index], clear ? "" : " NOT");
                // crash in the usual spot so CrashTracer coalesces it
            }
            fix_class_ref(&cls_refs[index], name, NO /*never meta*/);
        }
    }
}


/***********************************************************************
* _objc_remove_pending_class_refs_in_image
* Delete any pending class ref fixups for class refs in the given image, 
* because the image is about to be unloaded.
**********************************************************************/
static void removePendingReferences(struct old_class **refs, size_t count)
{
    struct old_class **end = refs + count;

    if (!refs) return;
    if (!pendingClassRefsMap) return;

    // Search the pending class ref table for class refs in this range.
    // The class refs may have already been stomped with nonexistentClass, 
    // so there's no way to recover the original class name.
    
    const char *key;
    PendingClassRef *pending;
    NXMapState  state = NXInitMapState(pendingClassRefsMap);
    while(NXNextMapState(pendingClassRefsMap, &state, 
                         (const void **)&key, (const void **)&pending)) 
    {
        for ( ; pending != NULL; pending = pending->next) {
            if (pending->ref >= refs  &&  pending->ref < end) {
                pending->ref = NULL;
            }
        }
    } 
}

static void _objc_remove_pending_class_refs_in_image(header_info *hi)
{
    struct old_class **cls_refs;
    size_t count;

    // Locate class refs in this image
    cls_refs = _getObjcClassRefs(hi, &count);
    removePendingReferences(cls_refs, count);
}


/***********************************************************************
* map_selrefs.  For each selector in the specified array,
* replace the name pointer with a uniqued selector.
* If copy is TRUE, all selector data is always copied. This is used 
* for registering selectors from unloadable bundles, so the selector 
* can still be used after the bundle's data segment is unmapped.
* Returns YES if dst was written to, NO if it was unchanged.
**********************************************************************/
static inline BOOL map_selrefs(SEL *src, SEL *dst, size_t size, BOOL copy)
{
    BOOL result = NO;
    size_t cnt = size / sizeof(SEL);
    size_t index;

    sel_lock();

    // Process each selector
    for (index = 0; index < cnt; index += 1)
    {
        SEL sel;

        // Lookup pointer to uniqued string
        sel = sel_registerNameNoLock((const char *) src[index], copy);

        // Replace this selector with uniqued one (avoid
        // modifying the VM page if this would be a NOP)
        if (dst[index] != sel) {
            dst[index] = sel;
            result = YES;
        }
    }
    
    sel_unlock();

    return result;
}


/***********************************************************************
* map_message_refs.  For each message ref in the specified array,
* replace the name pointer with a uniqued selector.
* If copy is TRUE, all selector data is always copied. This is used 
* for registering selectors from unloadable bundles, so the selector 
* can still be used after the bundle's data segment is unmapped.
* Returns YES if dst was written to, NO if it was unchanged.
**********************************************************************/
static inline BOOL map_message_refs(message_ref *src, message_ref *dst, size_t size, BOOL copy)
{
    BOOL result = NO;
    size_t cnt = size / sizeof(message_ref);
    size_t index;

    sel_lock();

    // Process each selector
    for (index = 0; index < cnt; index += 1)
    {
        SEL sel;

        // Lookup pointer to uniqued string
        sel = sel_registerNameNoLock((const char *) src[index].sel, copy);

        // Replace this selector with uniqued one (avoid
        // modifying the VM page if this would be a NOP)
        if (dst[index].sel != sel) {
            dst[index].sel = sel;
            result = YES;
        }
    }
    
    sel_unlock();

    return result;
}


/***********************************************************************
* map_method_descs.  For each method in the specified method list,
* replace the name pointer with a uniqued selector.
* If copy is TRUE, all selector data is always copied. This is used 
* for registering selectors from unloadable bundles, so the selector 
* can still be used after the bundle's data segment is unmapped.
**********************************************************************/
static void  map_method_descs (struct objc_method_description_list * methods, BOOL copy)
{
    unsigned int	index;

    if (!methods) return;

    sel_lock();

    // Process each method
    for (index = 0; index < methods->count; index += 1)
    {
        struct objc_method_description *	method;
        SEL					sel;

        // Get method entry to fix up
        method = &methods->list[index];

        // Lookup pointer to uniqued string
        sel = sel_registerNameNoLock((const char *) method->name, copy);

        // Replace this selector with uniqued one (avoid
        // modifying the VM page if this would be a NOP)
        if (method->name != sel)
            method->name = sel;
    }

    sel_unlock();
}


/***********************************************************************
* ext_for_protocol
* Returns the protocol extension for the given protocol.
* Returns NULL if the protocol has no extension.
**********************************************************************/
static struct old_protocol_ext *ext_for_protocol(struct old_protocol *proto)
{
    if (!proto) return NULL;
    if (!protocol_ext_map) return NULL;
    else return (struct old_protocol_ext *)NXMapGet(protocol_ext_map, proto);
}


/***********************************************************************
* lookup_method
* Search a protocol method list for a selector.
**********************************************************************/
static struct objc_method_description *
lookup_method(struct objc_method_description_list *mlist, SEL aSel)
{
   if (mlist) {
       int i;
       for (i = 0; i < mlist->count; i++) {
           if (mlist->list[i].name == aSel) {
               return mlist->list+i;
           }
       }
   }
   return NULL;
}


/***********************************************************************
* lookup_protocol_method
* Recursively search for a selector in a protocol 
* (and all incorporated protocols)
**********************************************************************/
__private_extern__ struct objc_method_description *
lookup_protocol_method(struct old_protocol *proto, SEL aSel, 
                       BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    struct objc_method_description *m = NULL;
    struct old_protocol_ext *ext;

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            m = lookup_method(proto->instance_methods, aSel);
        } else {
            m = lookup_method(proto->class_methods, aSel);
        }
    } else if ((ext = ext_for_protocol(proto))) {
        if (isInstanceMethod) {
            m = lookup_method(ext->optional_instance_methods, aSel);
        } else {
            m = lookup_method(ext->optional_class_methods, aSel);
        }
    }

    if (!m  &&  proto->protocol_list) {
        int i;
        for (i = 0; !m  &&  i < proto->protocol_list->count; i++) {
            m = lookup_protocol_method(proto->protocol_list->list[i], aSel, 
                                       isRequiredMethod, isInstanceMethod);
        }
    }

    return m;
}


/***********************************************************************
* protocol_getName
* Returns the name of the given protocol.
**********************************************************************/
const char *protocol_getName(Protocol *p)
{
    struct old_protocol *proto = oldprotocol(p);
    if (!proto) return "nil";
    return proto->protocol_name;
}


/***********************************************************************
* protocol_getMethodDescription
* Returns the description of a named method.
* Searches either required or optional methods.
* Searches either instance or class methods.
**********************************************************************/
struct objc_method_description 
protocol_getMethodDescription(Protocol *p, SEL aSel, 
                              BOOL isRequiredMethod, BOOL isInstanceMethod)
{
    struct old_protocol *proto = oldprotocol(p);
    if (!proto) return (struct objc_method_description){NULL, NULL};

    struct objc_method_description *desc = 
        lookup_protocol_method(proto, aSel, 
                               isRequiredMethod, isInstanceMethod);
    if (desc) return *desc;
    else return (struct objc_method_description){NULL, NULL};
}


/***********************************************************************
* protocol_copyMethodDescriptionList
* Returns an array of method descriptions from a protocol.
* Copies either required or optional methods.
* Copies either instance or class methods.
**********************************************************************/
struct objc_method_description *
protocol_copyMethodDescriptionList(Protocol *p, 
                                   BOOL isRequiredMethod, 
                                   BOOL isInstanceMethod, 
                                   unsigned int *outCount)
{
    struct objc_method_description_list *mlist = NULL;
    struct old_protocol *proto = oldprotocol(p);
    struct old_protocol_ext *ext;

    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    } 

    if (isRequiredMethod) {
        if (isInstanceMethod) {
            mlist = proto->instance_methods;
        } else {
            mlist = proto->class_methods;
        }
    } else if ((ext = ext_for_protocol(proto))) {
        if (isInstanceMethod) {
            mlist = ext->optional_instance_methods;
        } else {
            mlist = ext->optional_class_methods;
        }
    }

    if (!mlist) {
        if (outCount) *outCount = 0;
        return NULL;
    }
    
    unsigned int i;
    unsigned int count = mlist->count;
    struct objc_method_description *result = 
        calloc(count + 1, sizeof(struct objc_method_description));
    for (i = 0; i < count; i++) {
        result[i] = mlist->list[i];
    }

    if (outCount) *outCount = count;
    return result;
}


Property protocol_getProperty(Protocol *p, const char *name, 
                              BOOL isRequiredProperty, BOOL isInstanceProperty)
{
    struct old_protocol *proto = oldprotocol(p);

    if (!proto  ||  !name) return NULL;
    
    if (!isRequiredProperty  ||  !isInstanceProperty) {
        // Only required instance properties are currently supported
        return NULL;
    }

    struct old_protocol_ext *ext;
    if ((ext = ext_for_protocol(proto))) {
        struct objc_property_list *plist;
        if ((plist = ext->instance_properties)) {
            uint32_t i;
            for (i = 0; i < plist->count; i++) {
                Property prop = property_list_nth(plist, i);
                if (0 == strcmp(name, prop->name)) {
                    return prop;
                }
            }
        }
    }

    struct old_protocol_list *plist;
    if ((plist = proto->protocol_list)) {
        int i;
        for (i = 0; i < plist->count; i++) {
            Property prop = 
                protocol_getProperty((Protocol *)plist->list[i], name, 
                                     isRequiredProperty, isInstanceProperty);
            if (prop) return prop;
        }
    }
    
    return NULL;
}


Property *protocol_copyPropertyList(Protocol *p, unsigned int *outCount)
{
    Property *result = NULL;
    struct old_protocol_ext *ext;
    
    struct old_protocol *proto = oldprotocol(p);
    if (! (ext = ext_for_protocol(proto))) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    struct objc_property_list *plist = ext->instance_properties;
    result = copyPropertyList(plist, outCount);
    
    return result;
}


/***********************************************************************
* protocol_copyProtocolList
* Copies this protocol's incorporated protocols. 
* Does not copy those protocol's incorporated protocols in turn.
**********************************************************************/
Protocol **protocol_copyProtocolList(Protocol *p, unsigned int *outCount)
{
    unsigned int count = 0;
    Protocol **result = NULL;
    struct old_protocol *proto = oldprotocol(p);
    
    if (!proto) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    if (proto->protocol_list) {
        count = (unsigned int)proto->protocol_list->count;
    }
    if (count > 0) {
        result = malloc((count+1) * sizeof(Protocol *));

        unsigned int i;
        for (i = 0; i < count; i++) {
            result[i] = (Protocol *)proto->protocol_list->list[i];
        }
        result[i] = NULL;
    }

    if (outCount) *outCount = count;
    return result;
}


BOOL protocol_conformsToProtocol(Protocol *self_gen, Protocol *other_gen)
{
    struct old_protocol *self = oldprotocol(self_gen);
    struct old_protocol *other = oldprotocol(other_gen);

    if (!self  ||  !other) {
        return NO;
    }

    if (0 == strcmp(self->protocol_name, other->protocol_name)) {
        return YES;
    }

    if (self->protocol_list) {
        int i;
        for (i = 0; i < self->protocol_list->count; i++) {
            struct old_protocol *proto = self->protocol_list->list[i];
            if (0 == strcmp(other->protocol_name, proto->protocol_name)) {
                return YES;
            }
            if (protocol_conformsToProtocol((Protocol *)proto, other_gen)) {
                return YES;
            }
        }
    }

    return NO;
}


BOOL protocol_isEqual(Protocol *self, Protocol *other)
{
    if (self == other) return YES;
    if (!self  ||  !other) return NO;

    if (!protocol_conformsToProtocol(self, other)) return NO;
    if (!protocol_conformsToProtocol(other, self)) return NO;

    return YES;
}


/***********************************************************************
* _objc_fixup_protocol_objects_for_image.  For each protocol in the
* specified image, selectorize the method names and add to the protocol hash.
**********************************************************************/

static BOOL versionIsExt(uintptr_t version, const char *names, size_t size)
{
    // CodeWarrior used isa field for string "Protocol" 
    //   from section __OBJC,__class_names.  rdar://4951638
    // gcc (10.4 and earlier) used isa field for version number; 
    //   the only version number used on Mac OS X was 2.
    // gcc (10.5 and later) uses isa field for ext pointer

    if (version < 4096) {
        return NO;
    }

    if (version >= (uintptr_t)names  &&  version < (uintptr_t)(names + size)) {
        return NO;
    }

    return YES;
}

static void fix_protocol(struct old_protocol *proto, Class protocolClass, 
                         BOOL isBundle, const char *names, size_t names_size)
{
#warning GrP fixme hack
    if (!proto) return;

    uintptr_t version = (uintptr_t)proto->isa;

    // Set the protocol's isa
    proto->isa = protocolClass;

    // Fix up method lists
    // fixme share across duplicates
    map_method_descs (proto->instance_methods, isBundle);
    map_method_descs (proto->class_methods, isBundle);

    // Fix up ext, if any
    if (versionIsExt(version, names, names_size)) {
        struct old_protocol_ext *ext = (struct old_protocol_ext *)version;
        NXMapInsert(protocol_ext_map, proto, ext);
        map_method_descs (ext->optional_instance_methods, isBundle);
        map_method_descs (ext->optional_class_methods, isBundle);
    }
    
    // Record the protocol it if we don't have one with this name yet
    // fixme bundles - copy protocol
    // fixme unloading
    if (!NXMapGet(protocol_map, proto->protocol_name)) {
        NXMapKeyCopyingInsert(protocol_map, proto->protocol_name, proto);
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s",
                         proto, proto->protocol_name);
        }
    } else {
        // duplicate - do nothing
        if (PrintProtocols) {
            _objc_inform("PROTOCOLS: protocol at %p is %s (duplicate)",
                         proto, proto->protocol_name);
        }
    }
}

static void _objc_fixup_protocol_objects_for_image (header_info * hi)
{
    Class protocolClass = objc_getClass("Protocol");
    size_t count, i;
    struct old_protocol *protos;
    int isBundle = hi->mhdr->filetype == MH_BUNDLE;
    const char *names;
    size_t names_size;

    OBJC_LOCK(&classLock);

    // Allocate the protocol registry if necessary.
    if (!protocol_map) {
        protocol_map = 
            NXCreateMapTableFromZone(NXStrValueMapPrototype, 32, 
                                     _objc_internal_zone());
    }
    if (!protocol_ext_map) {
        protocol_ext_map = 
            NXCreateMapTableFromZone(NXPtrValueMapPrototype, 32, 
                                     _objc_internal_zone());        
    }

    protos = _getObjcProtocols(hi, &count);
    names = _getObjcClassNames(hi, &names_size);
    for (i = 0; i < count; i++) {
        fix_protocol(&protos[i], protocolClass, isBundle, names, names_size);
    }

    OBJC_UNLOCK(&classLock);
}


/***********************************************************************
* _objc_fixup_selector_refs.  Register all of the selectors in each
* image, and fix them all up.
**********************************************************************/
static void _objc_fixup_selector_refs   (const header_info *hi)
{
    size_t count;
    SEL *sels;

    // Fix up selector refs
    sels = _getObjcSelectorRefs (hi, &count);
    if (sels) {
        map_selrefs(sels, sels, count * sizeof(SEL), 
                    hi->mhdr->filetype == MH_BUNDLE);
    }
}


/***********************************************************************
* _read_images
* Perform metadata processing for hCount images starting with firstNewHeader
**********************************************************************/
__private_extern__ void _read_images(header_info **hList, uint32_t hCount)
{
    uint32_t i;

    if (!class_hash) _objc_init_class_hash();

    // Parts of this order are important for correctness or performance.

    // Read classes from all images.
    for (i = 0; i < hCount; i++) {
        _objc_read_classes_from_image(hList[i]);
    }

    // Read categories from all images. 
    BOOL needFlush = NO;
    for (i = 0; i < hCount; i++) {
        needFlush |= _objc_read_categories_from_image(hList[i]);
    }
    if (needFlush) flush_marked_caches();

    // Connect classes from all images.
    for (i = 0; i < hCount; i++) {
        _objc_connect_classes_from_image(hList[i]);
    }

    // Fix up class refs, selector refs, and protocol objects from all images.
    for (i = 0; i < hCount; i++) {
        _objc_map_class_refs_for_image(hList[i]);
        _objc_fixup_selector_refs(hList[i]);
        _objc_fixup_protocol_objects_for_image(hList[i]);
    }
}


/***********************************************************************
* prepare_load_methods
* Schedule +load for classes in this image, any un-+load-ed 
* superclasses in other images, and any categories in this image.
**********************************************************************/
// Recursively schedule +load for cls and any un-+load-ed superclasses.
// cls must already be connected.
static void schedule_class_load(struct old_class *cls)
{
    if (cls->info & CLS_LOADED) return;
    if (cls->super_class) schedule_class_load(cls->super_class);
    add_class_to_loadable_list((Class)cls);
    cls->info |= CLS_LOADED;
}

__private_extern__ void prepare_load_methods(header_info *hi)
{
    Module mods;
    unsigned int midx;
    

    if (_objcHeaderIsReplacement(hi)) {
        // Ignore any classes in this image
        return;
    }

    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        unsigned int index;

        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;

        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            // Locate the class description pointer
            struct old_class *cls = mods[midx].symtab->defs[index];
            if (cls->info & CLS_CONNECTED) {
                schedule_class_load(cls);
            }
        }
    }


    // Major loop - process all modules in the header
    mods = hi->mod_ptr;

    // NOTE: The module and category lists are traversed backwards 
    // to preserve the pre-10.4 processing order. Changing the order 
    // would have a small chance of introducing binary compatibility bugs.
    midx = hi->mod_count;
    while (midx-- > 0) {
        unsigned int index;
        unsigned int total;
        Symtab symtab = mods[midx].symtab;

        // Nothing to do for a module without a symbol table
        if (mods[midx].symtab == NULL)
            continue;
        // Total entries in symbol table (class entries followed
        // by category entries)
        total = mods[midx].symtab->cls_def_cnt +
            mods[midx].symtab->cat_def_cnt;
        
        // Minor loop - register all categories from given module
        index = total;
        while (index-- > mods[midx].symtab->cls_def_cnt) {
            struct old_category *cat = symtab->defs[index];
            add_category_to_loadable_list((Category)cat);
        }
    }
}


/***********************************************************************
* _objc_remove_classes_in_image
* Remove all classes in the given image from the runtime, because 
* the image is about to be unloaded.
* Things to clean up:
*   class_hash
*   unconnected_class_hash
*   pending subclasses list (only if class is still unconnected)
*   loadable class list
*   class's method caches
*   class refs in all other images
**********************************************************************/
// Re-pend any class references in refs that point into [start..end)
static void rependClassReferences(struct old_class **refs, size_t count, 
                                  uintptr_t start, uintptr_t end)
{
    size_t i;

    if (!refs) return;

    // Process each class ref
    for (i = 0; i < count; i++) {
        if ((uintptr_t)(refs[i]) >= start  &&  (uintptr_t)(refs[i]) < end) {
            pendClassReference(&refs[i], refs[i]->name, 
                               (refs[i]->info & CLS_META) ? YES : NO);
            refs[i] = (struct old_class *)_class_getNonexistentObjectClass();
        }
    }
}


static void try_free(const void *p)
{
    if (p  &&  malloc_size(p)) free((void *)p);
}

// Deallocate all memory in a method list
static void unload_mlist(struct old_method_list *mlist) 
{
    int i;
    if (mlist->obsolete == _OBJC_FIXED_UP) {
        for (i = 0; i < mlist->method_count; i++) {
            try_free(mlist->method_list[i].method_types);
        }
        
        try_free(mlist);
    }
}

// Deallocate all memory in a class. 
__private_extern__ void unload_class(struct old_class *cls)
{
    // Free ivar lists
    if (cls->ivars) {
        int i;
        for (i = 0; i < cls->ivars->ivar_count; i++) {
            try_free(cls->ivars->ivar_list[i].ivar_name);
            try_free(cls->ivars->ivar_list[i].ivar_type);
        }
        try_free(cls->ivars);
    }

    // Free fixed-up method lists and method list array
    if (cls->methodLists) {
        // more than zero method lists
        if (cls->info & CLS_NO_METHOD_ARRAY) {
            // one method list
            unload_mlist((struct old_method_list *)cls->methodLists);
        } 
        else {
            // more than one method list
            struct old_method_list **mlistp;
            for (mlistp = cls->methodLists; 
                 *mlistp != NULL  &&  *mlistp != END_OF_METHODS_LIST; 
                 mlistp++) 
            {
                unload_mlist(*mlistp);
            }
            free(cls->methodLists);
        }
    }

    // Free protocol list
    struct old_protocol_list *protos = cls->protocols;
    while (protos) {
        struct old_protocol_list *dead = protos;
        protos = protos->next;
        try_free(dead);
    }

    // Free method cache
    if (cls->cache  &&  cls->cache != &_objc_empty_cache) {
        _cache_free(cls->cache);
    }

    if ((cls->info & CLS_EXT)) {
        if (cls->ext) {
            // Free property lists and property list array
            if (cls->ext->propertyLists) {
                // more than zero property lists
                if (cls->info & CLS_NO_PROPERTY_ARRAY) {
                    // one property list
                    try_free(cls->ext->propertyLists);
                } else {
                    // more than one property list
                    struct objc_property_list **plistp;
                    for (plistp = cls->ext->propertyLists; 
                         *plistp != NULL; 
                         plistp++) 
                    {
                        try_free(*plistp);
                    }
                    try_free(cls->ext->propertyLists);
                }
            }

            // Free weak ivar layout
            try_free(cls->ext->weak_ivar_layout);

            // Free ext
            try_free(cls->ext);
        }

        // Free non-weak ivar layout
        try_free(cls->ivar_layout);
    }

    // Free class name
    try_free(cls->name);

    // Free cls
    try_free(cls);
}


static void _objc_remove_classes_in_image(header_info *hi)
{
    unsigned int       index;
    unsigned int       midx;
    Module             mods;

    OBJC_LOCK(&classLock);
    
    // Major loop - process all modules in the image
    mods = hi->mod_ptr;
    for (midx = 0; midx < hi->mod_count; midx += 1)
    {
        // Skip module containing no classes
        if (mods[midx].symtab == NULL)
            continue;
        
        // Minor loop - process all the classes in given module
        for (index = 0; index < mods[midx].symtab->cls_def_cnt; index += 1)
        {
            struct old_class *cls;
            
            // Locate the class description pointer
            cls = mods[midx].symtab->defs[index];

            // Remove from loadable class list, if present
            remove_class_from_loadable_list((Class)cls);

            // Remove from unconnected_class_hash and pending subclasses
            if (unconnected_class_hash  &&  NXHashMember(unconnected_class_hash, cls)) {
                NXHashRemove(unconnected_class_hash, cls);
                if (pendingSubclassesMap) {
                    // Find this class in its superclass's pending list
                    char *supercls_name = (char *)cls->super_class;
                    PendingSubclass *pending = 
                        NXMapGet(pendingSubclassesMap, supercls_name);
                    for ( ; pending != NULL; pending = pending->next) {
                        if (pending->subclass == cls) {
                            pending->subclass = Nil;
                            break;
                        }
                    }
                }
            }
            
            // Remove from class_hash
            NXHashRemove(class_hash, cls);

            // Free heap memory pointed to by the class
            unload_class(cls->isa);
            unload_class(cls);
        }
    }


    // Search all other images for class refs that point back to this range.
    // Un-fix and re-pend any such class refs.

    // Get the location of the dying image's __OBJC segment
    uintptr_t seg = hi->objcSegmentHeader->vmaddr + hi->image_slide;
    size_t seg_size = hi->objcSegmentHeader->filesize;

    header_info *other_hi;
    for (other_hi = _objc_headerStart(); 
         other_hi != NULL; 
         other_hi = other_hi->next) 
    {
        struct old_class **other_refs;
        size_t count;
        if (other_hi == hi) continue;  // skip the image being unloaded

        // Fix class refs in the other image
        other_refs = _getObjcClassRefs(other_hi, &count);
        rependClassReferences(other_refs, count, seg, seg+seg_size);
    }

    OBJC_UNLOCK(&classLock);
}


/***********************************************************************
* _objc_remove_categories_in_image
* Remove all categories in the given image from the runtime, because 
* the image is about to be unloaded.
* Things to clean up:
*    unresolved category list
*    loadable category list
**********************************************************************/
static void _objc_remove_categories_in_image(header_info *hi)
{
    Module mods;
    unsigned int midx;
    
    // Major loop - process all modules in the header
    mods = hi->mod_ptr;
    
    for (midx = 0; midx < hi->mod_count; midx++) {
        unsigned int index;
        unsigned int total;
        Symtab symtab = mods[midx].symtab;
        
        // Nothing to do for a module without a symbol table
        if (symtab == NULL) continue;
        
        // Total entries in symbol table (class entries followed
        // by category entries)
        total = symtab->cls_def_cnt + symtab->cat_def_cnt;
        
        // Minor loop - check all categories from given module
        for (index = symtab->cls_def_cnt; index < total; index++) {
            struct old_category *cat = symtab->defs[index];

            // Clean up loadable category list
            remove_category_from_loadable_list((Category)cat);

            // Clean up category_hash
            if (category_hash) {
                _objc_unresolved_category *cat_entry = 
                    NXMapGet(category_hash, cat->class_name);
                for ( ; cat_entry != NULL; cat_entry = cat_entry->next) {
                    if (cat_entry->cat == cat) {
                        cat_entry->cat = NULL;
                        break;
                    }
                }
            }
        }
    }
}


/***********************************************************************
* unload_paranoia
* Various paranoid debugging checks that look for poorly-behaving 
* unloadable bundles. 
* Called by _objc_unmap_image when OBJC_UNLOAD_DEBUG is set.
**********************************************************************/
static void unload_paranoia(header_info *hi) 
{
    // Get the location of the dying image's __OBJC segment
    uintptr_t seg = hi->objcSegmentHeader->vmaddr + hi->image_slide;
    size_t seg_size = hi->objcSegmentHeader->filesize;

    _objc_inform("UNLOAD DEBUG: unloading image '%s' [%p..%p]", 
                 _nameForHeader(hi->mhdr), (void *)seg, (void*)(seg+seg_size));

    OBJC_LOCK(&classLock);

    // Make sure the image contains no categories on surviving classes.
    {
        Module mods;
        unsigned int midx;

        // Major loop - process all modules in the header
        mods = hi->mod_ptr;
        
        for (midx = 0; midx < hi->mod_count; midx++) {
            unsigned int index;
            unsigned int total;
            Symtab symtab = mods[midx].symtab;

            // Nothing to do for a module without a symbol table
            if (symtab == NULL) continue;
            
            // Total entries in symbol table (class entries followed
            // by category entries)
            total = symtab->cls_def_cnt + symtab->cat_def_cnt;
            
            // Minor loop - check all categories from given module
            for (index = symtab->cls_def_cnt; index < total; index++) {
                struct old_category *cat = symtab->defs[index];
                struct old_class query;

                query.name = cat->class_name;
                if (NXHashMember(class_hash, &query)) {
                    _objc_inform("UNLOAD DEBUG: dying image contains category '%s(%s)' on surviving class '%s'!", cat->class_name, cat->category_name, cat->class_name);
                }
            }
        }
    }

    // Make sure no surviving class is in the dying image.
    // Make sure no surviving class has a superclass in the dying image.
    // fixme check method implementations too
    {
        struct old_class *cls;
        NXHashState state;

        state = NXInitHashState(class_hash);
        while (NXNextHashState(class_hash, &state, (void **)&cls)) {
            if ((vm_address_t)cls >= seg  && 
                (vm_address_t)cls < seg+seg_size) 
            {
                _objc_inform("UNLOAD DEBUG: dying image contains surviving class '%s'!", cls->name);
            }
            
            if ((vm_address_t)cls->super_class >= seg  &&  
                (vm_address_t)cls->super_class < seg+seg_size)
            {
                _objc_inform("UNLOAD DEBUG: dying image contains superclass '%s' of surviving class '%s'!", cls->super_class->name, cls->name);
            }
        }
    }

    OBJC_UNLOCK(&classLock);
}


/***********************************************************************
* _unload_image
* Only handles MH_BUNDLE for now.
**********************************************************************/
__private_extern__ void _unload_image(header_info *hi)
{
    // Cleanup:
    // Remove image's classes from the class list and free auxiliary data.
    // Remove image's unresolved or loadable categories and free auxiliary data
    // Remove image's unresolved class refs.
    _objc_remove_classes_in_image(hi);
    _objc_remove_categories_in_image(hi);
    _objc_remove_pending_class_refs_in_image(hi);
    
    // Perform various debugging checks if requested.
    if (DebugUnload) unload_paranoia(hi);
}


/***********************************************************************
* objc_addClass.  Add the specified class to the table of known classes,
* after doing a little verification and fixup.
**********************************************************************/
void		objc_addClass		(Class cls_gen)
{
    struct old_class *cls = _class_asOld(cls_gen);

    OBJC_WARN_DEPRECATED;

    // Synchronize access to hash table
    OBJC_LOCK (&classLock);

    // Make sure both the class and the metaclass have caches!
    // Clear all bits of the info fields except CLS_CLASS and CLS_META.
    // Normally these bits are already clear but if someone tries to cons
    // up their own class on the fly they might need to be cleared.
    if (cls->cache == NULL) {
        cls->cache = (Cache) &_objc_empty_cache;
        cls->info = CLS_CLASS;
    }

    if (cls->isa->cache == NULL) {
        cls->isa->cache = (Cache) &_objc_empty_cache;
        cls->isa->info = CLS_META;
    }

    // methodLists should be: 
    // 1. NULL (Tiger and later only)
    // 2. A -1 terminated method list array
    // In either case, CLS_NO_METHOD_ARRAY remains clear.
    // If the user manipulates the method list directly, 
    // they must use the magic private format.

    // Add the class to the table
    (void) NXHashInsert (class_hash, cls);

    // Superclass is no longer a leaf for cache flushing
    if (cls->super_class && (cls->super_class->info & CLS_LEAF)) {
        _class_clearInfo((Class)cls->super_class, CLS_LEAF);
        _class_clearInfo((Class)cls->super_class->isa, CLS_LEAF);
    }

    // Desynchronize
    OBJC_UNLOCK (&classLock);
}

/***********************************************************************
* _objcTweakMethodListPointerForClass.
* Change the class's method list pointer to a method list array. 
* Does nothing if the method list pointer is already a method list array.
* If the class is currently in use, methodListLock must be held by the caller.
**********************************************************************/
static void _objcTweakMethodListPointerForClass(struct old_class *cls)
{
    struct old_method_list *	originalList;
    const int					initialEntries = 4;
    size_t							mallocSize;
    struct old_method_list **	ptr;

    // Do nothing if methodLists is already an array.
    if (cls->methodLists  &&  !(cls->info & CLS_NO_METHOD_ARRAY)) return;

    // Remember existing list
    originalList = (struct old_method_list *) cls->methodLists;

    // Allocate and zero a method list array
    mallocSize   = sizeof(struct old_method_list *) * initialEntries;
    ptr	     = (struct old_method_list **) _calloc_internal(1, mallocSize);

    // Insert the existing list into the array
    ptr[initialEntries - 1] = END_OF_METHODS_LIST;
    ptr[0] = originalList;

    // Replace existing list with array
    cls->methodLists = ptr;
    _class_clearInfo((Class)cls, CLS_NO_METHOD_ARRAY);
}


/***********************************************************************
* _objc_insertMethods.
* Adds methods to a class.
* Does not flush any method caches.
* Does not take any locks.
* If the class is already in use, use class_addMethods() instead.
**********************************************************************/
__private_extern__ void _objc_insertMethods(struct old_class *cls, 
                                            struct old_method_list *mlist, 
                                            struct old_category *cat)
{
    struct old_method_list ***list;
    struct old_method_list **ptr;
    ptrdiff_t endIndex;
    size_t oldSize;
    size_t newSize;

    if (!cls->methodLists) {
        // cls has no methods - simply use this method list
        cls->methodLists = (struct old_method_list **)mlist;
        _class_setInfo((Class)cls, CLS_NO_METHOD_ARRAY);
        return;
    }

    // Log any existing methods being replaced
    if (PrintReplacedMethods) {
        int i;
        for (i = 0; i < mlist->method_count; i++) {
            extern IMP findIMPInClass(struct old_class *cls, SEL sel);
            SEL sel = sel_registerName((char *)mlist->method_list[i].method_name);
            IMP newImp = mlist->method_list[i].method_imp;
            IMP oldImp;

            if ((oldImp = findIMPInClass(cls, sel))) {
                _objc_inform("REPLACED: %c[%s %s]  %s%s  (IMP was %p, now %p)",
                             ISMETA(cls) ? '+' : '-',
                             cls->name, sel_getName(sel), 
                             cat ? "by category " : "", 
                             cat ? cat->category_name : "", 
                             oldImp, newImp);
            }
        }
    }

    // Create method list array if necessary
    _objcTweakMethodListPointerForClass(cls);
    
    list = &cls->methodLists;

    // Locate unused entry for insertion point
    ptr = *list;
    while ((*ptr != 0) && (*ptr != END_OF_METHODS_LIST))
        ptr += 1;

    // If array is full, add to it
    if (*ptr == END_OF_METHODS_LIST)
    {
        // Calculate old and new dimensions
        endIndex = ptr - *list;
        oldSize  = (endIndex + 1) * sizeof(void *);
        newSize  = oldSize + sizeof(struct old_method_list *); // only increase by 1

        // Grow the method list array by one.
        // This block may be from user code; don't use _realloc_internal
        *list = (struct old_method_list **)realloc(*list, newSize);

        // Zero out addition part of new array
        bzero (&((*list)[endIndex]), newSize - oldSize);

        // Place new end marker
        (*list)[(newSize/sizeof(void *)) - 1] = END_OF_METHODS_LIST;

        // Insertion point corresponds to old array end
        ptr = &((*list)[endIndex]);
    }

    // Right shift existing entries by one
    bcopy (*list, (*list) + 1, ((void *) ptr) - ((void *) *list));

    // Insert at method list at beginning of array
    **list = mlist;
}

/***********************************************************************
* _objc_removeMethods.
* Remove methods from a class.
* Does not take any locks.
* Does not flush any method caches.
* If the class is currently in use, use class_removeMethods() instead.
**********************************************************************/
__private_extern__ void _objc_removeMethods(struct old_class *cls, 
                                            struct old_method_list *mlist)
{
    struct old_method_list ***list;
    struct old_method_list **ptr;

    if (cls->methodLists == NULL) {
        // cls has no methods
        return;
    }
    if (cls->methodLists == (struct old_method_list **)mlist) {
        // mlist is the class's only method list - erase it
        cls->methodLists = NULL;
        return;
    }
    if (cls->info & CLS_NO_METHOD_ARRAY) {
        // cls has only one method list, and this isn't it - do nothing
        return;
    }

    // cls has a method list array - search it

    list = &cls->methodLists;

    // Locate list in the array
    ptr = *list;
    while (*ptr != mlist) {
        // fix for radar # 2538790
        if ( *ptr == END_OF_METHODS_LIST ) return;
        ptr += 1;
    }

    // Remove this entry
    *ptr = 0;

    // Left shift the following entries
    while (*(++ptr) != END_OF_METHODS_LIST)
        *(ptr-1) = *ptr;
    *(ptr-1) = 0;
}

/***********************************************************************
* _objc_add_category.  Install the specified category's methods and
* protocols into the class it augments.
* The class is assumed not to be in use yet: no locks are taken and 
* no method caches are flushed.
**********************************************************************/
static inline void _objc_add_category(struct old_class *cls, struct old_category *category, int version)
{
    if (PrintConnecting) {
        _objc_inform("CONNECT: attaching category '%s (%s)'", cls->name, category->category_name);
    }

    // Augment instance methods
    if (category->instance_methods)
        _objc_insertMethods (cls, category->instance_methods, category);

    // Augment class methods
    if (category->class_methods)
        _objc_insertMethods (cls->isa, category->class_methods, category);

    // Augment protocols
    if ((version >= 5) && category->protocols)
    {
        if (cls->isa->version >= 5)
        {
            category->protocols->next = cls->protocols;
            cls->protocols	          = category->protocols;
            cls->isa->protocols       = category->protocols;
        }
        else
        {
            _objc_inform ("unable to add protocols from category %s...\n", category->category_name);
            _objc_inform ("class `%s' must be recompiled\n", category->class_name);
        }
    }

    // Augment properties
    if (version >= 7  &&  category->instance_properties) {
        if (cls->isa->version >= 6) {
            _class_addProperties(cls, category->instance_properties);
        } else {
            _objc_inform ("unable to add properties from category %s...\n", category->category_name);
            _objc_inform ("class `%s' must be recompiled\n", category->class_name);
        }
    }
}

/***********************************************************************
* _objc_add_category_flush_caches.  Install the specified category's 
* methods into the class it augments, and flush the class' method cache.
* Return YES if some method caches now need to be flushed.
**********************************************************************/
static BOOL _objc_add_category_flush_caches(struct old_class *cls, struct old_category *category, int version)
{
    BOOL needFlush = NO;

    // Install the category's methods into its intended class
    OBJC_LOCK(&methodListLock);
    _objc_add_category (cls, category, version);
    OBJC_UNLOCK(&methodListLock);

    // Queue for cache flushing so category's methods can get called
    if (category->instance_methods) {
        _class_setInfo((Class)cls, CLS_FLUSH_CACHE);
        needFlush = YES;
    }
    if (category->class_methods) {
        _class_setInfo((Class)cls->isa, CLS_FLUSH_CACHE);
        needFlush = YES;
    }
    
    return needFlush;
}


/***********************************************************************
* reverse_cat
* Reverse the given linked list of pending categories. 
* The pending category list is built backwards, and needs to be 
* reversed before actually attaching the categories to a class.
* Returns the head of the new linked list.
**********************************************************************/
static _objc_unresolved_category *reverse_cat(_objc_unresolved_category *cat)
{
    if (!cat) return NULL;

    _objc_unresolved_category *prev = NULL;
    _objc_unresolved_category *cur = cat;
    _objc_unresolved_category *ahead = cat->next;
    
    while (cur) {
        ahead = cur->next;
        cur->next = prev;
        prev = cur;
        cur = ahead;
    }

    return prev;
}


/***********************************************************************
* resolve_categories_for_class.  
* Install all existing categories intended for the specified class.
* cls must be a true class and not a metaclass.
**********************************************************************/
static void resolve_categories_for_class(struct old_class *cls)
{
    _objc_unresolved_category *	pending;
    _objc_unresolved_category *	next;

    // Nothing to do if there are no categories at all
    if (!category_hash) return;

    // Locate and remove first element in category list
    // associated with this class
    pending = NXMapKeyFreeingRemove (category_hash, cls->name);

    // Traverse the list of categories, if any, registered for this class

    // The pending list is built backwards. Reverse it and walk forwards.
    pending = reverse_cat(pending);

    while (pending) {
        if (pending->cat) {
            // Install the category
            // use the non-flush-cache version since we are only
            // called from the class intialization code
            _objc_add_category(cls, pending->cat, (int)pending->version);
        }

        // Delink and reclaim this registration
        next = pending->next;
        _free_internal(pending);
        pending = next;
    }
}


/***********************************************************************
* _objc_resolve_categories_for_class.  
* Public version of resolve_categories_for_class. This was 
* exported pre-10.4 for Omni et al. to workaround a problem 
* with too-lazy category attachment.
* cls should be a class, but this function can also cope with metaclasses.
**********************************************************************/
void _objc_resolve_categories_for_class(Class cls_gen)
{
    struct old_class *cls = _class_asOld(cls_gen);

    // If cls is a metaclass, get the class. 
    // resolve_categories_for_class() requires a real class to work correctly.
    if (ISMETA(cls)) {
        if (strncmp(cls->name, "_%", 2) == 0) {
            // Posee's meta's name is smashed and isn't in the class_hash, 
            // so objc_getClass doesn't work.
            char *baseName = strchr(cls->name, '%'); // get posee's real name
            cls = _class_asOld(objc_getClass(baseName));
        } else {
            cls = _class_asOld(objc_getClass(cls->name));
        }
    }

    resolve_categories_for_class(cls);
}


/***********************************************************************
* _objc_register_category.
* Process a category read from an image. 
* If the category's class exists, attach the category immediately. 
*   Classes that need cache flushing are marked but not flushed.
* If the category's class does not exist yet, pend the category for 
*   later attachment. Pending categories are attached in the order 
*   they were discovered.
* Returns YES if some method caches now need to be flushed.
**********************************************************************/
static BOOL _objc_register_category(struct old_category *cat, int version)
{
    _objc_unresolved_category *	new_cat;
    _objc_unresolved_category *	old;
    struct old_class *theClass;

    // If the category's class exists, attach the category.
    if ((theClass = _class_asOld(objc_lookUpClass(cat->class_name)))) {
        return _objc_add_category_flush_caches(theClass, cat, version);
    }
    
    // If the category's class exists but is unconnected, 
    // then attach the category to the class but don't bother 
    // flushing any method caches (because they must be empty).
    // YES unconnected, NO class_handler
    if ((theClass = _class_asOld(look_up_class(cat->class_name, YES, NO)))) {
        _objc_add_category(theClass, cat, version);
        return NO;
    }


    // Category's class does not exist yet. 
    // Save the category for later attachment.

    if (PrintConnecting) {
        _objc_inform("CONNECT: pending category '%s (%s)'", cat->class_name, cat->category_name);
    }

    // Create category lookup table if needed
    if (!category_hash)
        category_hash = NXCreateMapTableFromZone (NXStrValueMapPrototype,
                                                  128,
                                                  _objc_internal_zone ());

    // Locate an existing list of categories, if any, for the class.
    old = NXMapGet (category_hash, cat->class_name);

    // Register the category to be fixed up later.
    // The category list is built backwards, and is reversed again 
    // by resolve_categories_for_class().
    new_cat = _malloc_internal(sizeof(_objc_unresolved_category));
    new_cat->next    = old;
    new_cat->cat     = cat;
    new_cat->version = version;
    (void) NXMapKeyCopyingInsert (category_hash, cat->class_name, new_cat);

    return NO;
}


__private_extern__ const char **
_objc_copyClassNamesForImage(header_info *hi, unsigned int *outCount)
{
    Module mods;
    int m;
    const char **list;
    int count;
    int allocated;

    list = NULL;
    count = 0;
    allocated = 0;
    
    mods = hi->mod_ptr;
    for (m = 0; m < hi->mod_count; m++) {
        int d;

        if (!mods[m].symtab) continue;
        
        for (d = 0; d < mods[m].symtab->cls_def_cnt; d++) {
            struct old_class *cls = mods[m].symtab->defs[d];
            // fixme what about future-ified classes?
            if (class_is_connected(cls)) {
                if (count == allocated) {
                    allocated = allocated*2 + 16;
                    list = realloc(list, allocated * sizeof(char *));
                }
                list[count++] = cls->name;
            }
        }
    }

    if (count > 0) {
        // NULL-terminate non-empty list
        if (count == allocated) {
            allocated = allocated+1;
            list = realloc(list, allocated * sizeof(char *));
        }
        list[count] = NULL;
    }

    if (outCount) *outCount = count;
    return list;
}

#endif
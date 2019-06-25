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
* objc-runtime.m
* Copyright 1988-1996, NeXT Software, Inc.
* Author:	s. naroff
*
**********************************************************************/



/***********************************************************************
* Imports.
**********************************************************************/

#include "objc-private.h"
#include "objc-loadmethod.h"
#include "message.h"

OBJC_EXPORT Class getOriginalClassForPosingClass(Class);


/***********************************************************************
* Exports.
**********************************************************************/

// Settings from environment variables
#define OPTION(var, env, help) bool var = false;
#include "objc-env.h"
#undef OPTION

struct option_t {
    bool* var;
    const char *env;
    const char *help;
    size_t envlen;
};

const option_t Settings[] = {
#define OPTION(var, env, help) option_t{&var, #env, help, strlen(#env)}, 
#include "objc-env.h"
#undef OPTION
};


// objc's key for pthread_getspecific
static tls_key_t _objc_pthread_key;

// Selectors
SEL SEL_load = NULL;
SEL SEL_initialize = NULL;
SEL SEL_resolveInstanceMethod = NULL;
SEL SEL_resolveClassMethod = NULL;
SEL SEL_cxx_construct = NULL;
SEL SEL_cxx_destruct = NULL;
SEL SEL_retain = NULL;
SEL SEL_release = NULL;
SEL SEL_autorelease = NULL;
SEL SEL_retainCount = NULL;
SEL SEL_alloc = NULL;
SEL SEL_allocWithZone = NULL;
SEL SEL_copy = NULL;
SEL SEL_new = NULL;
SEL SEL_finalize = NULL;
SEL SEL_forwardInvocation = NULL;

header_info *FirstHeader = 0;  // NULL means empty list
header_info *LastHeader  = 0;  // NULL means invalid; recompute it
int HeaderCount = 0;



/***********************************************************************
* objc_getClass.  Return the id of the named class.  If the class does
* not exist, call _objc_classLoader and then objc_classHandler, either of 
* which may create a new class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
Class objc_getClass(const char *aClassName)
{
    if (!aClassName) return Nil;

    // NO unconnected, YES class handler
    return look_up_class(aClassName, NO, YES);
}


/***********************************************************************
* objc_getRequiredClass.  
* Same as objc_getClass, but kills the process if the class is not found. 
* This is used by ZeroLink, where failing to find a class would be a 
* compile-time link error without ZeroLink.
**********************************************************************/
Class objc_getRequiredClass(const char *aClassName)
{
    Class cls = objc_getClass(aClassName);
    if (!cls) _objc_fatal("link error: class '%s' not found.", aClassName);
    return cls;
}


/***********************************************************************
* objc_lookUpClass.  Return the id of the named class.
* If the class does not exist, call _objc_classLoader, which may create 
* a new class.
*
* Formerly objc_getClassWithoutWarning ()
**********************************************************************/
Class objc_lookUpClass(const char *aClassName)
{
    if (!aClassName) return Nil;

    // NO unconnected, NO class handler
    return look_up_class(aClassName, NO, NO);
}

/***********************************************************************
* objc_getFutureClass.  Return the id of the named class.
* If the class does not exist, return an uninitialized class 
* structure that will be used for the class when and if it 
* does get loaded.
* Not thread safe. 
**********************************************************************/
Class objc_getFutureClass(const char *name)
{
    Class cls;

    // YES unconnected, NO class handler
    // (unconnected is OK because it will someday be the real class)
    cls = look_up_class(name, YES, NO);
    if (cls) {
        if (PrintFuture) {
            _objc_inform("FUTURE: found %p already in use for %s", 
                         (void*)cls, name);
        }
        return cls;
    }
    
    // No class or future class with that name yet. Make one.
    // fixme not thread-safe with respect to 
    // simultaneous library load or getFutureClass.
    return _objc_allocateFutureClass(name);
}


/***********************************************************************
* objc_getMetaClass.  Return the id of the meta class the named class.
* Warning: doesn't work if aClassName is the name of a posed-for class's isa!
**********************************************************************/
Class objc_getMetaClass(const char *aClassName)
{
    Class cls;

    if (!aClassName) return Nil;

    cls = objc_getClass (aClassName);
    if (!cls)
    {
        _objc_inform ("class `%s' not linked into application", aClassName);
        return Nil;
    }

    return cls->ISA();
}


/***********************************************************************
* appendHeader.  Add a newly-constructed header_info to the list. 
**********************************************************************/
void appendHeader(header_info *hi)
{
    // Add the header to the header list. 
    // The header is appended to the list, to preserve the bottom-up order.
    HeaderCount++;
    hi->next = NULL;
    if (!FirstHeader) {
        // list is empty
        FirstHeader = LastHeader = hi;
    } else {
        if (!LastHeader) {
            // list is not empty, but LastHeader is invalid - recompute it
            LastHeader = FirstHeader;
            while (LastHeader->next) LastHeader = LastHeader->next;
        }
        // LastHeader is now valid
        LastHeader->next = hi;
        LastHeader = hi;
    }
}


/***********************************************************************
* removeHeader
* Remove the given header from the header list.
* FirstHeader is updated. 
* LastHeader is set to NULL. Any code that uses LastHeader must 
* detect this NULL and recompute LastHeader by traversing the list.
**********************************************************************/
void removeHeader(header_info *hi)
{
    header_info **hiP;

    for (hiP = &FirstHeader; *hiP != NULL; hiP = &(**hiP).next) {
        if (*hiP == hi) {
            header_info *deadHead = *hiP;

            // Remove from the linked list (updating FirstHeader if necessary).
            *hiP = (**hiP).next;
            
            // Update LastHeader if necessary.
            if (LastHeader == deadHead) {
                LastHeader = NULL;  // will be recomputed next time it's used
            }

            HeaderCount--;
            break;
        }
    }
}


/***********************************************************************
* environ_init
* Read environment variables that affect the runtime.
* Also print environment variable help, if requested.
**********************************************************************/
void environ_init(void) 
{
    if (issetugid()) {
        // All environment variables are silently ignored when setuid or setgid
        // This includes OBJC_HELP and OBJC_PRINT_OPTIONS themselves.
        return;
    } 

    bool PrintHelp = false;
    bool PrintOptions = false;

    // Scan environ[] directly instead of calling getenv() a lot.
    // This optimizes the case where none are set.
    for (char **p = *_NSGetEnviron(); *p != nil; p++) {
        if (0 != strncmp(*p, "OBJC_", 5)) continue;
        
        if (0 == strncmp(*p, "OBJC_HELP=", 10)) {
            PrintHelp = true;
            continue;
        }
        if (0 == strncmp(*p, "OBJC_PRINT_OPTIONS=", 19)) {
            PrintOptions = true;
            continue;
        }
        
        const char *value = strchr(*p, '=');
        if (!*value) continue;
        value++;
        
        for (size_t i = 0; i < sizeof(Settings)/sizeof(Settings[0]); i++) {
            const option_t *opt = &Settings[i];
            if ((size_t)(value - *p) == 1+opt->envlen  &&  
                0 == strncmp(*p, opt->env, opt->envlen))
            {
                *opt->var = (0 == strcmp(value, "YES"));
                break;
            }
        }            
    }

    // Print OBJC_HELP and OBJC_PRINT_OPTIONS output.
    if (PrintHelp  ||  PrintOptions) {
        if (PrintHelp) {
            _objc_inform("Objective-C runtime debugging. Set variable=YES to enable.");
            _objc_inform("OBJC_HELP: describe available environment variables");
            if (PrintOptions) {
                _objc_inform("OBJC_HELP is set");
            }
            _objc_inform("OBJC_PRINT_OPTIONS: list which options are set");
        }
        if (PrintOptions) {
            _objc_inform("OBJC_PRINT_OPTIONS is set");
        }

        for (size_t i = 0; i < sizeof(Settings)/sizeof(Settings[0]); i++) {
            const option_t *opt = &Settings[i];            
            if (PrintHelp) _objc_inform("%s: %s", opt->env, opt->help);
            if (PrintOptions && *opt->var) _objc_inform("%s is set", opt->env);
        }
    }
}


/***********************************************************************
* logReplacedMethod
* OBJC_PRINT_REPLACED_METHODS implementation
**********************************************************************/
void 
logReplacedMethod(const char *className, SEL s, 
                  BOOL isMeta, const char *catName, 
                  IMP oldImp, IMP newImp)
{
    const char *oldImage = "??";
    const char *newImage = "??";

    // Silently ignore +load replacement because category +load is special
    if (s == SEL_load) return;

#if TARGET_OS_WIN32
    // don't know dladdr()/dli_fname equivalent
#else
    Dl_info dl;

    if (dladdr((void*)oldImp, &dl)  &&  dl.dli_fname) oldImage = dl.dli_fname;
    if (dladdr((void*)newImp, &dl)  &&  dl.dli_fname) newImage = dl.dli_fname;
#endif
    
    _objc_inform("REPLACED: %c[%s %s]  %s%s  (IMP was %p (%s), now %p (%s))",
                 isMeta ? '+' : '-', className, sel_getName(s), 
                 catName ? "by category " : "", catName ? catName : "", 
                 oldImp, oldImage, newImp, newImage);
}



/***********************************************************************
* objc_setMultithreaded.
**********************************************************************/
void objc_setMultithreaded (BOOL flag)
{
    OBJC_WARN_DEPRECATED;

    // Nothing here. Thread synchronization in the runtime is always active.
}


/***********************************************************************
* _objc_fetch_pthread_data
* Fetch objc's pthread data for this thread.
* If the data doesn't exist yet and create is NO, return NULL.
* If the data doesn't exist yet and create is YES, allocate and return it.
**********************************************************************/
_objc_pthread_data *_objc_fetch_pthread_data(BOOL create)
{
    _objc_pthread_data *data;

    data = (_objc_pthread_data *)tls_get(_objc_pthread_key);
    if (!data  &&  create) {
        data = (_objc_pthread_data *)
            _calloc_internal(1, sizeof(_objc_pthread_data));
        tls_set(_objc_pthread_key, data);
    }

    return data;
}


/***********************************************************************
* _objc_pthread_destroyspecific
* Destructor for objc's per-thread data.
* arg shouldn't be NULL, but we check anyway.
**********************************************************************/
extern void _destroyInitializingClassList(struct _objc_initializing_classes *list);
void _objc_pthread_destroyspecific(void *arg)
{
    _objc_pthread_data *data = (_objc_pthread_data *)arg;
    if (data != NULL) {
        _destroyInitializingClassList(data->initializingClasses);
        _destroySyncCache(data->syncCache);
        _destroyAltHandlerList(data->handlerList);

        // add further cleanup here...

        _free_internal(data);
    }
}


void tls_init(void)
{
#if SUPPORT_DIRECT_THREAD_KEYS
    _objc_pthread_key = TLS_DIRECT_KEY;
    pthread_key_init_np(TLS_DIRECT_KEY, &_objc_pthread_destroyspecific);
#else
    _objc_pthread_key = tls_create(&_objc_pthread_destroyspecific);
#endif
}


/***********************************************************************
* _objcInit
* Former library initializer. This function is now merely a placeholder 
* for external callers. All runtime initialization has now been moved 
* to map_images() and _objc_init.
**********************************************************************/
void _objcInit(void)
{
    // do nothing
}


#if !(TARGET_OS_WIN32  ||  TARGET_OS_EMBEDDED  ||  TARGET_OS_IPHONE)
/***********************************************************************
* _objc_setNilReceiver
**********************************************************************/
id _objc_setNilReceiver(id newNilReceiver)
{
    id oldNilReceiver;

    oldNilReceiver = _objc_nilReceiver;
    _objc_nilReceiver = newNilReceiver;

    return oldNilReceiver;
}

/***********************************************************************
* _objc_getNilReceiver
**********************************************************************/
id _objc_getNilReceiver(void)
{
    return _objc_nilReceiver;
}
#endif


/***********************************************************************
* objc_setForwardHandler
**********************************************************************/
void objc_setForwardHandler(void *fwd, void *fwd_stret)
{
    _objc_forward_handler = fwd;
    _objc_forward_stret_handler = fwd_stret;
}


#if !__OBJC2__
// GrP fixme
extern "C" Class _objc_getOrigClass(const char *name);
#endif
const char *class_getImageName(Class cls)
{
#if TARGET_OS_WIN32
    TCHAR *szFileName;
    DWORD charactersCopied;
    Class origCls;
    HMODULE classModule;
    BOOL res;
#endif
    if (!cls) return NULL;

#if !__OBJC2__
    cls = _objc_getOrigClass(cls->getName());
#endif
#if TARGET_OS_WIN32
    charactersCopied = 0;
    szFileName = malloc(MAX_PATH * sizeof(TCHAR));
    
    origCls = objc_getOrigClass(cls->getName());
    classModule = NULL;
    res = GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCTSTR)origCls, &classModule);
    if (res && classModule) {
        charactersCopied = GetModuleFileName(classModule, szFileName, MAX_PATH * sizeof(TCHAR));
    }
    if (classModule) FreeLibrary(classModule);
    if (charactersCopied) {
        return (const char *)szFileName;
    } else {
        free(szFileName);
    }
    return NULL;
#else
    return dyld_image_path_containing_address(cls);
#endif
}


const char **objc_copyImageNames(unsigned int *outCount)
{
    header_info *hi;
    int count = 0;
    int max = HeaderCount;
#if TARGET_OS_WIN32
    const TCHAR **names = (const TCHAR **)calloc(max+1, sizeof(TCHAR *));
#else
    const char **names = (const char **)calloc(max+1, sizeof(char *));
#endif
    
    for (hi = FirstHeader; hi != NULL && count < max; hi = hi->next) {
#if TARGET_OS_WIN32
        if (hi->moduleName) {
            names[count++] = hi->moduleName;
        }
#else
        if (hi->fname) {
            names[count++] = hi->fname;
        }
#endif
    }
    names[count] = NULL;
    
    if (count == 0) {
        // Return NULL instead of empty list if there are no images
        free((void *)names);
        names = NULL;
    }

    if (outCount) *outCount = count;
    return names;
}


/**********************************************************************
*
**********************************************************************/
const char ** 
objc_copyClassNamesForImage(const char *image, unsigned int *outCount)
{
    header_info *hi;

    if (!image) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    // Find the image.
    for (hi = FirstHeader; hi != NULL; hi = hi->next) {
#if TARGET_OS_WIN32
        if (0 == wcscmp((TCHAR *)image, hi->moduleName)) break;
#else
        if (0 == strcmp(image, hi->fname)) break;
#endif
    }
    
    if (!hi) {
        if (outCount) *outCount = 0;
        return NULL;
    }

    return _objc_copyClassNamesForImage(hi, outCount);
}
	

/**********************************************************************
* Fast Enumeration Support
**********************************************************************/

static void (*enumerationMutationHandler)(id);

/**********************************************************************
* objc_enumerationMutation
* called by compiler when a mutation is detected during foreach iteration
**********************************************************************/
void objc_enumerationMutation(id object) {
    if (enumerationMutationHandler == nil) {
        _objc_fatal("mutation detected during 'for(... in ...)'  enumeration of object %p.", (void*)object);
    }
    (*enumerationMutationHandler)(object);
}


/**********************************************************************
* objc_setEnumerationMutationHandler
* an entry point to customize mutation error handing
**********************************************************************/
void objc_setEnumerationMutationHandler(void (*handler)(id)) {
    enumerationMutationHandler = handler;
}


/**********************************************************************
* Associative Reference Support
**********************************************************************/

id objc_getAssociatedObject_non_gc(id object, const void *key) {
    return _object_get_associative_reference(object, (void *)key);
}


void objc_setAssociatedObject_non_gc(id object, const void *key, id value, objc_AssociationPolicy policy) {
    _object_set_associative_reference(object, (void *)key, value, policy);
}


#if SUPPORT_GC

id objc_getAssociatedObject_gc(id object, const void *key) {
    return (id)auto_zone_get_associative_ref(gc_zone, object, (void *)key);
}

void objc_setAssociatedObject_gc(id object, const void *key, id value, objc_AssociationPolicy policy) {
    if ((policy & OBJC_ASSOCIATION_COPY_NONATOMIC) == OBJC_ASSOCIATION_COPY_NONATOMIC) {
        value = ((id(*)(id, SEL))objc_msgSend)(value, SEL_copy);
    }
    auto_zone_set_associative_ref(gc_zone, object, (void *)key, value);
}

// objc_setAssociatedObject and objc_getAssociatedObject are 
// resolver functions in objc-auto.mm.

#else

id 
objc_getAssociatedObject(id object, const void *key) 
{
    return objc_getAssociatedObject_non_gc(object, key);
}

void 
objc_setAssociatedObject(id object, const void *key, id value, 
                         objc_AssociationPolicy policy) 
{
    objc_setAssociatedObject_non_gc(object, key, value, policy);
}

#endif


void objc_removeAssociatedObjects(id object) 
{
#if SUPPORT_GC
    if (UseGC) {
        auto_zone_erase_associative_refs(gc_zone, object);
    } else 
#endif
    {
        if (object && object->getIsa()->instancesHaveAssociatedObjects()) {
            _object_remove_assocations(object);
        }
    }
}


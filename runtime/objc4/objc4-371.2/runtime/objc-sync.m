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

#include <stdbool.h>
#include <stdlib.h>
#include <sys/time.h>
#include <pthread.h>
#include <errno.h>
#include <AssertMacros.h>
#include <libkern/OSAtomic.h>

#include "objc-sync.h"
#include "objc-private.h"

//
// Allocate a lock only when needed.  Since few locks are needed at any point
// in time, keep them on a single list.
//

static pthread_mutexattr_t	sRecursiveLockAttr;
static bool			sRecursiveLockAttrIntialized = false;

static pthread_mutexattr_t* recursiveAttributes()
{
    if ( !sRecursiveLockAttrIntialized ) {
	int err = pthread_mutexattr_init(&sRecursiveLockAttr);
        require_noerr_string(err, done, "pthread_mutexattr_init failed");

	err = pthread_mutexattr_settype(&sRecursiveLockAttr, PTHREAD_MUTEX_RECURSIVE);
        require_noerr_string(err, done, "pthread_mutexattr_settype failed");

	sRecursiveLockAttrIntialized = true;
   }

done:
    return &sRecursiveLockAttr;
}


typedef uintptr_t spin_lock_t;
extern void _spin_lock(spin_lock_t *lockp);
extern int  _spin_lock_try(spin_lock_t *lockp);
extern void _spin_unlock(spin_lock_t *lockp);

typedef struct SyncData {
    struct SyncData* nextData;
    id               object;
    int              threadCount;  // number of THREADS using this block
    pthread_mutex_t  mutex;
    pthread_cond_t   conditionVariable;
} SyncData;

typedef struct {
    SyncData *data;
    unsigned int lockCount;  // number of times THIS THREAD locked this block
} SyncCacheItem;

typedef struct SyncCache {
    unsigned int allocated;
    unsigned int used;
    SyncCacheItem list[0];
} SyncCache;

typedef struct {
    spin_lock_t lock;
    SyncData *data;
} SyncList __attribute__((aligned(64)));
// aligned to put locks on separate cache lines

// Use multiple parallel lists to decrease contention among unrelated objects.
#define COUNT 16
#define HASH(obj) ((((uintptr_t)(obj)) >> 5) & (COUNT - 1))
#define LOCK_FOR_OBJ(obj) sDataLists[HASH(obj)].lock
#define LIST_FOR_OBJ(obj) sDataLists[HASH(obj)].data
static SyncList sDataLists[COUNT];


enum usage { ACQUIRE, RELEASE, CHECK };

static SyncCache *fetch_cache(BOOL create)
{
    _objc_pthread_data *data;
    
    data = _objc_fetch_pthread_data(create);
    if (!data  &&  !create) return NULL;

    if (!data->syncCache) {
        if (!create) {
            return NULL;
        } else {
            int count = 4;
            data->syncCache = calloc(1, sizeof(SyncCache) + 
                                     count*sizeof(SyncCacheItem));
            data->syncCache->allocated = count;
        }
    }

    // Make sure there's at least one open slot in the list.
    if (data->syncCache->allocated == data->syncCache->used) {
        data->syncCache->allocated *= 2;
        data->syncCache = 
            realloc(data->syncCache, sizeof(SyncCache) 
                    + data->syncCache->allocated * sizeof(SyncCacheItem));
    }

    return data->syncCache;
}


__private_extern__ void _destroySyncCache(struct SyncCache *cache)
{
    if (cache) free(cache);
}


static SyncData* id2data(id object, enum usage why)
{
    spin_lock_t *lockp = &LOCK_FOR_OBJ(object);
    SyncData **listp = &LIST_FOR_OBJ(object);
    SyncData* result = NULL;
    int err;

    // Check per-thread cache of already-owned locks for matching object
    SyncCache *cache = fetch_cache(NO);
    if (cache) {
        int i;
        for (i = 0; i < cache->used; i++) {
            SyncCacheItem *item = &cache->list[i];
            if (item->data->object != object) continue;

            // Found a match.
            result = item->data;
            require_action_string(result->threadCount > 0, cache_done, 
                                  result = NULL, "id2data cache is buggy");
            require_action_string(item->lockCount > 0, cache_done, 
                                  result = NULL, "id2data cache is buggy");
                
            switch(why) {
            case ACQUIRE:
                item->lockCount++;
                break;
            case RELEASE:
                item->lockCount--;
                if (item->lockCount == 0) {
                    // remove from per-thread cache
                    cache->list[i] = cache->list[--cache->used];
                    // atomic because may collide with concurrent ACQUIRE
                    OSAtomicDecrement32Barrier(&result->threadCount);
                }
                break;
            case CHECK:
                // do nothing
                break;
            }

        cache_done:            
            return result;
        }
    }

    // Thread cache didn't find anything.
    // Walk in-use list looking for matching object
    // Spinlock prevents multiple threads from creating multiple 
    // locks for the same new object.
    // We could keep the nodes in some hash table if we find that there are
    // more than 20 or so distinct locks active, but we don't do that now.
    
    _spin_lock(lockp);

    SyncData* p;
    SyncData* firstUnused = NULL;
    for (p = *listp; p != NULL; p = p->nextData) {
        if ( p->object == object ) {
            result = p;
            // atomic because may collide with concurrent RELEASE
            OSAtomicIncrement32Barrier(&result->threadCount);
            goto done;
        }
        if ( (firstUnused == NULL) && (p->threadCount == 0) )
            firstUnused = p;
    }
    
    // no SyncData currently associated with object
    if ( (why == RELEASE) || (why == CHECK) )
	goto done;
    
    // an unused one was found, use it
    if ( firstUnused != NULL ) {
        result = firstUnused;
        result->object = object;
        result->threadCount = 1;
        goto done;
    }
                            
    // malloc a new SyncData and add to list.
    // XXX calling malloc with a global lock held is bad practice,
    // might be worth releasing the lock, mallocing, and searching again.
    // But since we never free these guys we won't be stuck in malloc very often.
    result = (SyncData*)malloc(sizeof(SyncData));
    result->object = object;
    result->threadCount = 1;
    err = pthread_mutex_init(&result->mutex, recursiveAttributes());
    require_noerr_string(err, done, "pthread_mutex_init failed");
    err = pthread_cond_init(&result->conditionVariable, NULL);
    require_noerr_string(err, done, "pthread_cond_init failed");
    result->nextData = *listp;
    *listp = result;
    
 done:
    _spin_unlock(lockp);
    if (result) {
        // Only new ACQUIRE should get here.
        // All RELEASE and CHECK and recursive ACQUIRE are 
        // handled by the per-thread cache above.
        
        require_string(result != NULL, really_done, "id2data is buggy");
        require_action_string(why == ACQUIRE, really_done, 
                              result = NULL, "id2data is buggy");
        require_action_string(result->object == object, really_done, 
                              result = NULL, "id2data is buggy");
        
        if (!cache) cache = fetch_cache(YES);
        cache->list[cache->used++] = (SyncCacheItem){result, 1};
    }

 really_done:
    return result;
}


__private_extern__ __attribute__((noinline))
int objc_sync_nil(void)
{
    return OBJC_SYNC_SUCCESS;  // something to foil the optimizer
}


// Begin synchronizing on 'obj'.  
// Allocates recursive pthread_mutex associated with 'obj' if needed.
// Returns OBJC_SYNC_SUCCESS once lock is acquired.  
int objc_sync_enter(id obj)
{
    int result = OBJC_SYNC_SUCCESS;

    if (obj) {
        SyncData* data = id2data(obj, ACQUIRE);
        require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_INITIALIZED, "id2data failed");
	
        result = pthread_mutex_lock(&data->mutex);
        require_noerr_string(result, done, "pthread_mutex_lock failed");
    } else {
        // @synchronized(nil) does nothing
        if (DebugNilSync) {
            _objc_inform("NIL SYNC DEBUG: @synchronized(nil); set a breakpoint on objc_sync_nil to debug");
        }
        result = objc_sync_nil();
    }

done: 
    return result;
}


// End synchronizing on 'obj'. 
// Returns OBJC_SYNC_SUCCESS or OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_exit(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
    
    if (obj) {
        SyncData* data = id2data(obj, RELEASE); 
        require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR, "id2data failed");
        
        result = pthread_mutex_unlock(&data->mutex);
        require_noerr_string(result, done, "pthread_mutex_unlock failed");
    } else {
        // @synchronized(nil) does nothing
    }
	
done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;

    return result;
}


// Temporarily release lock on 'obj' and wait for another thread to notify on 'obj'
// Return OBJC_SYNC_SUCCESS, OBJC_SYNC_NOT_OWNING_THREAD_ERROR, OBJC_SYNC_TIMED_OUT, OBJC_SYNC_INTERRUPTED
int objc_sync_wait(id obj, long long milliSecondsMaxWait)
{
    int result = OBJC_SYNC_SUCCESS;
            
    SyncData* data = id2data(obj, CHECK);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR, "id2data failed");
    
    
    // XXX need to retry cond_wait under out-of-our-control failures
    if ( milliSecondsMaxWait == 0 ) {
        result = pthread_cond_wait(&data->conditionVariable, &data->mutex);
        require_noerr_string(result, done, "pthread_cond_wait failed");
    }
    else {
       	struct timespec maxWait;
        maxWait.tv_sec  = (time_t)(milliSecondsMaxWait / 1000);
        maxWait.tv_nsec = (long)((milliSecondsMaxWait - (maxWait.tv_sec * 1000)) * 1000000);
        result = pthread_cond_timedwait_relative_np(&data->conditionVariable, &data->mutex, &maxWait);
     	require_noerr_string(result, done, "pthread_cond_timedwait_relative_np failed");
    }
    // no-op to keep compiler from complaining about branch to next instruction
    data = NULL;

done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    else if ( result == ETIMEDOUT )
        result = OBJC_SYNC_TIMED_OUT;
    
    return result;
}


// Wake up another thread waiting on 'obj'
// Return OBJC_SYNC_SUCCESS, OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_notify(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
        
    SyncData* data = id2data(obj, CHECK);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR, "id2data failed");

    result = pthread_cond_signal(&data->conditionVariable);
    require_noerr_string(result, done, "pthread_cond_signal failed");

done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    
    return result;
}


// Wake up all threads waiting on 'obj'
// Return OBJC_SYNC_SUCCESS, OBJC_SYNC_NOT_OWNING_THREAD_ERROR
int objc_sync_notifyAll(id obj)
{
    int result = OBJC_SYNC_SUCCESS;
        
    SyncData* data = id2data(obj, CHECK);
    require_action_string(data != NULL, done, result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR, "id2data failed");

    result = pthread_cond_broadcast(&data->conditionVariable);
    require_noerr_string(result, done, "pthread_cond_broadcast failed");

done:
    if ( result == EPERM )
        result = OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    
    return result;
}







/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * Portions Copyright (c) 1999 Apple Computer, Inc.  All Rights
 * Reserved.  This file contains Original Code and/or Modifications of
 * Original Code as defined in and that are subject to the Apple Public
 * Source License Version 1.1 (the "License").  You may not use this file
 * except in compliance with the License.  Please obtain a copy of the
 * License at http://www.apple.com/publicsource and read it before using
 * this file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON- INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
/*
	Object.h
	Copyright 1988-1996 NeXT Software, Inc.
  
	DEFINED AS:	A common class
	HEADER FILES:	<objc/Object.h>

*/

#ifndef _OBJC_OBJECT_H_
#define _OBJC_OBJECT_H_

#include <objc/objc-runtime.h>

@class Protocol;

@interface Object
{
	Class isa;	/* A pointer to the instance's class structure */
}

/* Initializing classes and instances */

+ initialize;
- init;

/* Creating, copying, and freeing instances */

+ new;
+ free;
- free;
+ alloc;
- copy;
+ allocFromZone:(void *)zone;
- copyFromZone:(void *)zone;
- (void *)zone;

/* Identifying classes */

+ class;
+ superclass;
+ (const char *) name;
- class;
- superclass;
- (const char *) name;

/* Identifying and comparing instances */

- self;
- (unsigned int) hash;
- (BOOL) isEqual:anObject;

/* Testing inheritance relationships */

- (BOOL) isKindOf: aClassObject;
- (BOOL) isMemberOf: aClassObject;
- (BOOL) isKindOfClassNamed: (const char *)aClassName;
- (BOOL) isMemberOfClassNamed: (const char *)aClassName;

/* Testing class functionality */

+ (BOOL) instancesRespondTo:(SEL)aSelector;
- (BOOL) respondsTo:(SEL)aSelector;

/* Testing protocol conformance */

- (BOOL) conformsTo: (Protocol *)aProtocolObject;
+ (BOOL) conformsTo: (Protocol *)aProtocolObject;

/* Obtaining method descriptors from protocols */

- (struct objc_method_description *) descriptionForMethod:(SEL)aSel;
+ (struct objc_method_description *) descriptionForInstanceMethod:(SEL)aSel;

/* Obtaining method handles */

- (IMP) methodFor:(SEL)aSelector;
+ (IMP) instanceMethodFor:(SEL)aSelector;

/* Sending messages determined at run time */

- perform:(SEL)aSelector;
- perform:(SEL)aSelector with:anObject;
- perform:(SEL)aSelector with:object1 with:object2;

/* Posing */

+ poseAs: aClassObject;

/* Enforcing intentions */
 
- subclassResponsibility:(SEL)aSelector;
- notImplemented:(SEL)aSelector;

/* Error handling */

- doesNotRecognize:(SEL)aSelector;
- error:(const char *)aString, ...;

/* Debugging */

- (void) printForDebugger:(void *)stream;

/* Archiving */

- awake;
- write:(void *)stream;
- read:(void *)stream;
+ (int) version;
+ setVersion: (int) aVersion;

/* Forwarding */

- forward: (SEL)sel : (marg_list)args;
- performv: (SEL)sel : (marg_list)args;

@end

/* Abstract Protocol for Archiving */

@interface Object (Archiving)

- startArchiving: (void *)stream;
- finishUnarchiving;

@end

/* Abstract Protocol for Dynamic Loading */

@interface Object (DynamicLoading)

//+ finishLoading:(headerType *)header;
+ finishLoading:(struct mach_header *)header;
+ startUnloading;

@end

OBJC_EXPORT id object_dispose(Object *anObject);
OBJC_EXPORT id object_copy(Object *anObject, unsigned nBytes);
OBJC_EXPORT id object_copyFromZone(Object *anObject, unsigned nBytes, void *z);
OBJC_EXPORT id object_realloc(Object *anObject, unsigned nBytes);
OBJC_EXPORT id object_reallocFromZone(Object *anObject, unsigned nBytes, void *z);

#endif /* _OBJC_OBJECT_H_ */

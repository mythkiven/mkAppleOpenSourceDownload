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
 *	objc.h
 *	Copyright 1988-1996, NeXT Software, Inc.
 */

#ifndef _OBJC_OBJC_H_
#define _OBJC_OBJC_H_

#import <objc/objc-api.h>		// for OBJC_EXPORT

typedef struct objc_class *Class;

typedef struct objc_object {
	Class isa;
} *id;

typedef struct objc_selector 	*SEL;    
typedef id 			(*IMP)(id, SEL, ...); 
typedef char			BOOL;

#define YES             (BOOL)1
#define NO              (BOOL)0

#ifndef Nil
#define Nil 0		/* id of Nil class */
#endif

#ifndef nil
#define nil 0		/* id of Nil instance */
#endif


#if !defined(STRICT_OPENSTEP)

typedef char *STR;

OBJC_EXPORT BOOL sel_isMapped(SEL sel);
OBJC_EXPORT const char *sel_getName(SEL sel);
OBJC_EXPORT SEL sel_getUid(const char *str);
OBJC_EXPORT SEL sel_registerName(const char *str);
OBJC_EXPORT const char *object_getClassName(id obj);
OBJC_EXPORT void *object_getIndexedIvars(id obj);

#define ISSELECTOR(sel) sel_isMapped(sel)
#define SELNAME(sel)	sel_getName(sel)
#define SELUID(str)	sel_getUid(str)
#define NAMEOF(obj)     object_getClassName(obj)
#define IV(obj)         object_getIndexedIvars(obj)

#if defined(__osf__) && defined(__alpha__)
    typedef long arith_t;
    typedef unsigned long uarith_t;
    #define ARITH_SHIFT 32
#else
    typedef int arith_t;
    typedef unsigned uarith_t;
    #define ARITH_SHIFT 16
#endif

#endif	/* !STRICT_OPENSTEP */

#endif /* _OBJC_OBJC_H_ */

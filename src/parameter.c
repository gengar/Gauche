/*
 * parameter.c - parameter support
 *
 *   Copyright (c) 2000-2022  Shiro Kawai  <shiro@acm.org>
 *
 *   Redistribution and use in source and binary forms, with or without
 *   modification, are permitted provided that the following conditions
 *   are met:
 *
 *   1. Redistributions of source code must retain the above copyright
 *      notice, this list of conditions and the following disclaimer.
 *
 *   2. Redistributions in binary form must reproduce the above copyright
 *      notice, this list of conditions and the following disclaimer in the
 *      documentation and/or other materials provided with the distribution.
 *
 *   3. Neither the name of the authors nor the names of its contributors
 *      may be used to endorse or promote products derived from this
 *      software without specific prior written permission.
 *
 *   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 *   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 *   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 *   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 *   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 *   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 *   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 *   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 *   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 *   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 *   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#define LIBGAUCHE_BODY
#include "gauche.h"
#include "gauche/vm.h"
#include "gauche/priv/parameterP.h"

/*
 * Note: We're moving towards splitting thread local storage and parameters.
 * The following is a description of old model.  Eventually parameters won't
 * be thread-specific.
 *
 *
 * Parameters keep thread-local states.   When a thread is created,
 * it inherits the set of parameters from its creator (except the
 * primordial thread).
 * Parameters have additional features, such as guard procedure
 * and observer callbacks.  They are implemented in Scheme level
 * (see lib/gauche/parameter.scm).  C level only provides low-level
 * accessor and modifier methods.
 *
 * It is debatable how to implement the inheritance semantics.  MzScheme
 * keeps user-defined parameters in a hash table, and uses
 * copy-on-write mechanism to delay the copy of the table.  It is nice,
 * but difficult to use in preemptive threads, for it requires lock of
 * the table every time even in reading parameters.  Guile uses the
 * vector (Guile calls them fluids, but it's semantically equivalent
 * to parameters), and eagerly copies the vector at the creation of the
 * thread.  Since thread creation in Gauche is already heavy anyway,
 * I take Guile's approach.
 *
 * TODO: We now need to allocate a parameter slot to every thread (although
 * allocation is done lazily).  We may be able to use a tree instead of
 * a flat vector so that we can avoid allocation of leaf nodes until
 * they are accessed.
 */

#define THREAD_LOCAL_INIT_SIZE 64
#define THREAD_LOCAL_GROW      16

/* Every time a new parameter is created (in any thread), it is
 * given a unique index in the process.
 */
static ScmSize next_tl_index = 0;
static ScmInternalMutex tl_mutex = SCM_INTERNAL_MUTEX_INITIALIZER;

/* :name and :initial-value.  These keywords are set on-demand,
   since at the time of Scm_InitParameter we haven't initialized
   symbol subsystem yet.  */
static ScmObj key_name = SCM_FALSE;
static ScmObj key_initial_value = SCM_FALSE;

/* Class stuff */
static void pparam_print(ScmObj obj, ScmPort *out, ScmWriteContext *ctx);
static ScmObj pparam_allocate(ScmClass *klass, ScmObj initargs SCM_UNUSED);

SCM_DEFINE_BASE_CLASS(Scm_ThreadLocalClass, ScmThreadLocal,
                      pparam_print, NULL, NULL, pparam_allocate,
                      SCM_CLASS_OBJECT_CPL);

SCM_DEFINE_BASE_CLASS(Scm_PrimitiveParameterClass, ScmPrimitiveParameter,
                      pparam_print, NULL, NULL, pparam_allocate,
                      SCM_CLASS_OBJECT_CPL);

/* Init table.  For primordial thread, base == NULL.  For non-primordial
 * thread, base is the current thread (this must be called from the
 * creator thread).
 */
ScmVMThreadLocalTable *Scm__MakeVMThreadLocalTable(ScmVM *base)
{
    ScmVMThreadLocalTable *table = SCM_NEW(ScmVMThreadLocalTable);

    if (base) {
        /* NB: In this case, the caller is the owner thread of BASE,
           so we don't need to worry about base->parameters being
           modified during copying. */
        table->vector = SCM_NEW_ARRAY(ScmObj, base->threadLocals->size);
        table->size = base->threadLocals->size;
        for (ScmSize i=0; i<table->size; i++) {
            table->vector[i] = base->threadLocals->vector[i];
        }
    } else {
        table->vector = SCM_NEW_ARRAY(ScmObj, THREAD_LOCAL_INIT_SIZE);
        table->size = THREAD_LOCAL_INIT_SIZE;
        for (ScmSize i=0; i<table->size; i++) {
            table->vector[i] = SCM_UNBOUND;
        }
    }
    return table;
}

static void pparam_print(ScmObj obj,
                         ScmPort *out,
                         ScmWriteContext *ctx SCM_UNUSED)
{
    Scm_Printf(out, "#<%A %S @%p>",
               Scm_ShortClassName(Scm_ClassOf(obj)),
               SCM_PRIMITIVE_PARAMETER(obj)->name,
               obj);
}

static void ensure_tl_slot(ScmVMThreadLocalTable *p, ScmSize index)
{
    if (index >= p->size) {
        ScmSize newsiz =
            ((index+THREAD_LOCAL_GROW)/THREAD_LOCAL_GROW)*THREAD_LOCAL_GROW;
        ScmObj *newvec = SCM_NEW_ARRAY(ScmObj, newsiz);

        ScmSize i;
        for (i=0; i < p->size; i++) {
            newvec[i] = p->vector[i];
            p->vector[i] = SCM_FALSE; /*be friendly to GC*/
        }
        for (; i < newsiz; i++) {
            newvec[i] = SCM_UNBOUND;
        }
        p->vector = newvec;
        p->size = newsiz;
    }
}

static void ensure_tl_init_keywords()
{
    /* idempotency is ensured in SCM_MAKE_KEYWORD. */
    if (SCM_FALSEP(key_name)) {
        key_name = SCM_MAKE_KEYWORD("name");
    }
    if (SCM_FALSEP(key_initial_value)) {
        key_initial_value = SCM_MAKE_KEYWORD("initial-value");
    }
}

static ScmObj pparam_allocate(ScmClass *klass, ScmObj initargs)
{
    ensure_tl_init_keywords();
    ScmObj name = Scm_GetKeyword(key_name, initargs, SCM_FALSE);
    ScmObj initval = Scm_GetKeyword(key_initial_value, initargs, SCM_FALSE);
    ScmPrimitiveParameter *p =
        Scm_MakePrimitiveParameter(klass, name, initval, 0);
    return SCM_OBJ(p);
}

/*
 * Create a thread local
 */
ScmThreadLocal *Scm_MakeThreadLocal(ScmClass *klass,
                                    ScmObj name,
                                    ScmObj initval,
                                    u_long flags)
{
    SCM_INTERNAL_MUTEX_LOCK(tl_mutex);
    ScmSize index = next_tl_index++;
    SCM_INTERNAL_MUTEX_UNLOCK(tl_mutex);
    ensure_tl_slot(Scm_VM()->threadLocals, index);

    /* This is called _before_ class stuff is initialized, in which case
       we can't call SCM_NEW_INSTANCE.  We know such cases only happens
       with klass == SCM_CLASS_THRAED_LOCAL, so we hard-wire the
       case.
     */
    ScmThreadLocal *tl;
    if (SCM_EQ(klass, SCM_CLASS_THREAD_LOCAL)
        || SCM_EQ(klass, SCM_CLASS_PRIMITIVE_PARAMETER)) {
        tl = SCM_NEW(ScmThreadLocal);
        SCM_SET_CLASS(tl, klass);
        SCM_INSTANCE(tl)->slots = NULL;        /* no extra slots */
    } else {
        tl = SCM_NEW_INSTANCE(ScmThreadLocal, klass);
    }
    tl->name = name;
    tl->index = index;
    tl->initialValue = initval;
    tl->flags = flags;
    return tl;
}

/*
 * Create a primitive parameter
 * For now, it is just the same as thread local, but we'll gradually
 * modify it for the new parameter semantics.
 */
ScmPrimitiveParameter *Scm_MakePrimitiveParameter(ScmClass *klass,
                                                  ScmObj name,
                                                  ScmObj initval,
                                                  u_long flags)
{
    /* TRANSIENT */
    return (ScmPrimitiveParameter*)Scm_MakeThreadLocal(klass, name, initval, flags);
}

/*
 * Create a SUBR that embeds a primitive parameter.
 */
static ScmObj prim_param_proc(ScmObj *argv, int argc, void *data)
{
    ScmPrimitiveParameter *p = SCM_PRIMITIVE_PARAMETER(data);
    SCM_ASSERT(SCM_PRIMITIVE_PARAMETER_P(p));
    SCM_ASSERT(argc == 1);
    if (SCM_PAIRP(argv[0])) {
        if (SCM_PAIRP(SCM_CDR(argv[0]))) {
            Scm_Error("Wrong number of arguments for a parameter:"
                      " 0 or 1 argument(s) expected, but got %S", argv[0]);
        }
        return Scm_PrimitiveParameterSet(Scm_VM(), p, SCM_CAR(argv[0]));
    } else {
        return Scm_PrimitiveParameterRef(Scm_VM(), p);
    }
}

static ScmObj general_param_proc(ScmObj *argv, int argc, void *data)
{
    ScmPrimitiveParameter *p = SCM_PRIMITIVE_PARAMETER(data);
    SCM_ASSERT(SCM_PRIMITIVE_PARAMETER_P(p));
    SCM_ASSERT(argc == 1);

    if (SCM_PAIRP(argv[0])) {
        if (SCM_PAIRP(SCM_CDR(argv[0]))) {
            Scm_Error("Wrong number of arguments for a parameter:"
                      " 0 or 1 argument(s) expected, but got %S", argv[0]);
        }

        static ScmObj parameter_set_proc = SCM_UNDEFINED;
        SCM_BIND_PROC(parameter_set_proc, "%parameter-set!",
                      Scm_GaucheInternalModule());
        return Scm_VMApply2(parameter_set_proc, SCM_OBJ(p), SCM_CAR(argv[0]));
    } else {
        return Scm_PrimitiveParameterRef(Scm_VM(), p);
    }
}

ScmObj Scm_MakePrimitiveParameterSubr(ScmPrimitiveParameter *p)
{
    /* NB: We save p to the info field as well for the introspection. */
    if (SCM_EQ(Scm_ClassOf(SCM_OBJ(p)), SCM_CLASS_PRIMITIVE_PARAMETER)) {
        return Scm_MakeSubr(prim_param_proc, p, 0, 1, SCM_OBJ(p));
    } else {
        return Scm_MakeSubr(general_param_proc, p, 0, 1, SCM_OBJ(p));
    }
}

/*
 * Accessor & modifier
 */
ScmObj Scm_ThreadLocalRef(ScmVM *vm, const ScmThreadLocal *tl)
{
    ScmVMThreadLocalTable *t = vm->threadLocals;
    ScmObj result;
    if (tl->index >= t->size) {
        result = tl->initialValue;
    } else {
        result = t->vector[tl->index];
        if (SCM_UNBOUNDP(result)) {
            result = t->vector[tl->index] = tl->initialValue;
        }
    }
    if (tl->flags & SCM_PARAMETER_LAZY) return Scm_Force(result);
    else return result;
}


ScmObj Scm_PrimitiveParameterRef(ScmVM *vm, const ScmPrimitiveParameter *p)
{
    /* TRANSIENT */
    return Scm_ThreadLocalRef(vm, (const ScmThreadLocal*)p);
}


ScmObj Scm_ThreadLocalSet(ScmVM *vm, const ScmThreadLocal *tl,
                          ScmObj val)
{
    ScmObj oldval = SCM_UNBOUND;
    ScmVMThreadLocalTable *t = vm->threadLocals;
    if (tl->index >= t->size) {
        ensure_tl_slot(t, tl->index);
    } else {
        oldval = t->vector[tl->index];
    }
    if (SCM_UNBOUNDP(oldval)) {
        oldval = tl->initialValue;
    }

    t->vector[tl->index] = val;

    if (tl->flags & SCM_PARAMETER_LAZY) return Scm_Force(oldval);
    else return oldval;
}

ScmObj Scm_PrimitiveParameterSet(ScmVM *vm, const ScmPrimitiveParameter *p,
                                 ScmObj val)
{
    /* TRANSIENT */
    return Scm_ThreadLocalSet(vm, (const ScmThreadLocal*)p, val);
}

/* Convenience function.  Create a primitive parameter subr and bind
   it to NAME in MOD. */
ScmPrimitiveParameter *Scm_BindPrimitiveParameter(ScmModule *mod,
                                                  const char *name,
                                                  ScmObj initval,
                                                  u_long flags)
{
    ScmPrimitiveParameter *p =
        Scm_MakePrimitiveParameter(SCM_CLASS_PRIMITIVE_PARAMETER,
                                   SCM_INTERN(name), initval, flags);
    ScmObj subr = Scm_MakePrimitiveParameterSubr(p);
    Scm_Define(mod, SCM_SYMBOL(p->name), subr);
    return p;
}

void Scm__InitParameter(void)
{
    SCM_INTERNAL_MUTEX_INIT(tl_mutex);
    /* We don't initialize Scm_PrimitiveParameterClass yet, since class
       stuff is not initialized yet.  The class is initialized in
       class.c. */
}

#if GAUCHE_API_VERSION < 98
/* TRANSIENT: For the backward compatibility.  Remove by 1.0 */
void Scm_DefinePrimitiveParameter(ScmModule *mod,
                                  const char *name,
                                  ScmObj initval,
                                  ScmParameterLoc *location /*out*/)
{
    location->p = Scm_BindPrimitiveParameter(mod, name, initval, 0);
}

ScmObj Scm_ParameterRef(ScmVM *vm, const ScmParameterLoc *loc)
{
    Scm_Warn("Scm_ParameterRef is deprecated.");
    return Scm_PrimitiveParameterRef(vm, loc->p);
}

ScmObj Scm_ParameterSet(ScmVM *vm, const ScmParameterLoc *loc, ScmObj value)
{
    Scm_Warn("Scm_ParameterSet is deprecated.");
    return Scm_PrimitiveParameterSet(vm, loc->p, value);
}

void Scm_InitParameterLoc(ScmVM *vm SCM_UNUSED,
                          ScmParameterLoc *location,
                          ScmObj initval)
{
    Scm_Warn("Scm_InitParameterLoc is deprecated.  Use Scm_MakePrimitiveParameter");
    ScmPrimitiveParameter *p =
        Scm_MakePrimitiveParameter(SCM_CLASS_PRIMITIVE_PARAMETER,
                                   SCM_FALSE, initval, 0);
    location->p = p;
}

void Scm_MakeParameterSlot(ScmVM *vm, ScmParameterLoc *location)
{
    Scm_Warn("Scm_MakeParameterSlot is deprecated.  Use Scm_MakePrimitiveParameter.");
    Scm_InitParameterLoc(vm, location, SCM_FALSE);
}

void Scm__VMParameterTableInit(void *dummy SCM_UNUSED,
                               ScmVM *dummy2 SCM_UNUSED)
{
    Scm_Panic("Scm__VMParameterTableInit is obsoleted.  Shouldn't be called.");
}

#endif /*GAUCHE_API_VERSION < 98*/

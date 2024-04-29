;;;
;;; configure.scm - configuring Gauche extensions
;;;
;;;   Copyright (c) 2013-2024  Shiro Kawai  <shiro@acm.org>
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

;; This is a utility library to write 'configure' script, a replacement
;; of autotool-generated 'configure' shell script.  See ext/template.configure
;; for an example.
;;
;; The biggest advantage of using autotool's 'configure' is that it runs
;; on most vanilla unix, for it only uses minimal shell features and
;; basic unix commands.   However, when you configure Gauche extension,
;; you sure have Gauche already.  Why not use full power of Gauche
;; to do the configuration work?
;;
;; If we use Gauche to write 'configure', we no longer need an extra step
;; to generate configure from configure.ac, for the interpreter (gosh)
;; is powerful enough to allow extension writers to do any abstraction
;; he needs.   So the author can check in 'configure' script itself
;; to the source tree, and anyone who checks it out can directly run
;; ./configure, without worrying running autoconf (and free from headache
;; of autoconf version mismatch)
;;
;; The core feature of gauche.configure is the ability to generate files
;; (e.g. Makefile) from templates (e.g. Makefile.in) with replacing
;; parameters.  We follow autoconf convention, so the replacement variables
;; in a template is written like @VAR@.
;;
;; The API is roughly corresponds to autoconf's AC_* macros, while we use
;; 'cf-' suffix instead.
;;
;; The simplest configure scripts can be just the following 3 expressions:
;;
;;  (use gauche.configure)
;;  (cf-init-gauche-extension)
;;  (cf-output-default)
;;
;; It takes package name and version from package.scm file, sets several
;; substitution variables, and creates Makefile from Makefile.in along
;; the gpd (Gauche package description) file.

;; TODO: Caching test results

(define-module gauche.configure
  (use gauche.generator)
  (use gauche.dictionary)
  (use gauche.parseopt)
  (use gauche.logger)
  (use gauche.cgen)
  (use gauche.package)
  (use gauche.process)
  (use gauche.version)
  (use gauche.mop.singleton)
  (use util.match)
  (use file.filter)
  (use file.util)
  (use text.tr)
  (use text.tree)
  (use srfi.13)

  (use gauche.configure.base)
  (use gauche.configure.lang)
  (use gauche.configure.prog)
  (use gauche.configure.init)
  (extend gauche.config)
  (export cf-init cf-init-gauche-extension
          cf-arg-enable cf-arg-with cf-feature-ref cf-package-ref
          cf-help-string
          cf-msg-checking cf-msg-result cf-msg-warn cf-msg-error cf-msg-notice
          cf-echo
          cf-make-gpd
          cf-define cf-defined? cf-subst cf-subst-append cf-subst-prepend
          cf-arg-var cf-have-subst? cf-ref cf$
          with-cf-subst
          cf-config-headers cf-output cf-output-default cf-show-substs
          cf-check-prog cf-path-prog cf-check-tool
          cf-prog-cxx

          cf-lang <c-language>
          cf-lang-program cf-lang-io-program cf-lang-call
          cf-call-with-cpp
          cf-try-compile cf-try-compile-and-link

          cf-check-header cf-header-available? cf-check-headers
          cf-includes-default
          cf-check-type cf-type-available? cf-check-types
          cf-check-decl cf-decl-available? cf-check-decls
          cf-check-member cf-member-available? cf-check-members

          cf-check-func cf-func-available? cf-check-funcs
          cf-check-lib cf-lib-available? cf-search-libs
          ))
(select-module gauche.configure)

;; some internal utilities

(define (safe-variable-name s)
  (string-tr (string-upcase s) "A-Z0-9" "_*" :complement #t))

;;;
;;; Output
;;;

;; API
(define (cf-config-headers header-or-headers)
  (dolist [h (listify header-or-headers)]
    (match (string-split h #\:)
      [(out src) (push! (~(ensure-package)'config.h) (cons out src))]
      [(out) (push! (~(ensure-package)'config.h) (cons out #"~|out|.in"))]
      [_ (error "Invalid header name in cf-config-headers" h)])))

;; API
;; Like AC_OUTPUT
(define (cf-output . files)
  (define pa (ensure-package))
  (define base-substs (~ pa'substs))
  (define (make-defs)
    (if (null? (~ pa'config.h))
      (string-join
       (dict-map (~ pa'defs)
                 (^[k v]
                   (let1 vv ($ regexp-replace-all* (x->string v)
                               #/\\/ "\\\\\\\\"
                               #/\"/ "\\\\\"")
                     #"-D~|k|=~|vv|")))
       " ")
      "-DHAVE_CONFIG_H"))
  (define (make-subst path-prefix)
    (receive (srcdir top_srcdir builddir top_builddir)
        (adjust-srcdirs path-prefix)
      (let1 substs (make-stacked-map (alist->hash-table
                                      `((srcdir       . ,srcdir)
                                        (top_srcdir   . ,top_srcdir)
                                        (builddir     . ,builddir)
                                        (top_builddir . ,top_builddir)
                                        (DEFS . ,(make-defs)))
                                      'eq?)
                                     base-substs)
        (^[m]
          (let1 name (string->symbol (m 1))
            (or (dict-get substs name #f)
                (begin (warn "@~a@ isn't substituted.\n" name)
                       #"@~|name|@")))))))
  ;; We use '/' in the replaced pathname even on Windows; that's what
  ;; autoconf-generated configure does, and it's less likely to confuse
  ;; Unix-originated tools.
  (define (simplify-path+ path)
    (cond-expand
     [gauche.os.windows (string-tr (simplify-path path) "\\\\" "/")]
     [else (simplify-path path)]))
  (define (adjust-srcdirs path-prefix)
    (let ([srcdir    (~ base-substs'srcdir)]
          [tsrcdir   (~ base-substs'top_srcdir)]
          [builddir  (~ base-substs'builddir)]
          [tbuilddir (~ base-substs'top_builddir)])
      (if (equal? path-prefix ".")
        (values srcdir tsrcdir builddir tbuilddir)
        (let1 revpath ($ apply build-path
                         $ map (^_ "..") (string-split path-prefix #[\\/]))
          (values (if (equal? srcdir ".")
                    srcdir
                    (simplify-path+ (build-path srcdir path-prefix)))
                  (simplify-path+ (build-path revpath tsrcdir))
                  (if (equal? builddir ".")
                    builddir
                    (simplify-path+ (build-path builddir path-prefix)))
                  (simplify-path+ (build-path revpath tbuilddir)))))))

  (define (make-replace-1 output-file)
    (let1 subst (make-subst (sys-dirname (simplify-path+ output-file)))
      (^[line outp]
        (display (regexp-replace-all #/@(\w+)@/ line subst) outp)
        (newline outp))))

  (define (make-config.h)
    (^[line outp]
      (rxmatch-case line
        [#/^#undef\s+([A-Za-z_]+)/ (_ name)
         (if-let1 defval (dict-get (~ pa'defs) (string->symbol name) #f)
           (display #"#define ~name ~defval" outp)
           (display #"/* #undef ~name */" outp))]
        [else (display line outp)])
      (newline outp)))

  ;; Realize prefix and exec_prefix if they're not set.
  (when (equal? (cf$ 'prefix) "NONE")
    (cf-subst 'prefix (cf$ 'default_prefix)))
  (when (equal? (cf$ 'exec_prefix) "NONE")
    (cf-subst 'exec_prefix "${prefix}"))

  (dolist [f files]
    (let1 inf (build-path (cf$'srcdir) #"~|f|.in")
      (unless (file-is-readable? inf)
        (error "Cannot read input file ~s" inf))
      (unless (file-is-directory? (sys-dirname f))
        (make-directory* (sys-dirname f)))
      (cf-msg-notice "configure: creating ~a" f)
      (file-filter-for-each (make-replace-1 f) :input inf :output f
                            :temporary-file #t :leave-unchanged #t)))
  (dolist [h (~ pa'config.h)]
    (let1 inf (build-path (cf$'srcdir) (cdr h))
      (unless (file-is-readable? inf)
        (error "Cannot read input file ~s" inf))
      (unless (file-is-directory? (sys-dirname (car h)))
        (make-directory* (sys-dirname (car h))))
      (cf-msg-notice "configure: creating ~a" (car h))
      (file-filter-for-each (make-config.h) :input inf :output (car h)
                            :temporary-file #t :leave-unchanged #t)))

  ;; Record output variables and definitions to config.log
  (log-output-substs)
  (log-output-defs)
  )

(define (log-output-substs)
  (log-format ".")
  (log-format "## ----------------- ##")
  (log-format "## Output variables. ##")
  (log-format "## ----------------- ##")
  (log-format ".")
  (dolist [k (sort (hash-table-keys (~ (current-package)'substs)))]
    (log-format "~a=~a" k (shell-escape-string
                           (hash-table-get (~ (current-package)'substs) k)))))

(define (log-output-defs)
  (log-format ".")
  (log-format "## ------------ ##")
  (log-format "## Definitions. ##")
  (log-format "## ------------ ##")
  (log-format ".")
  (dolist [k (sort (hash-table-keys (~ (current-package)'defs)))]
    (log-format "#define ~a ~a" k
                (or (hash-table-get (~ (current-package)'defs) k) "/**/"))))

;; API
;; Show definitions.
(define (cf-show-substs :key (formatter (^[k v] (format #t "~16s ~s" k v))))
  (let1 dict (~ (ensure-package)'substs)
    (dolist [k (sort (dict-keys dict)
                     (^[a b] (string<? (x->string a) (x->string b))))]
      (formatter k (dict-get dict k))
      (newline))))

;; API
;; Create .gpd file.  This is Gauche-specific.
(define (cf-make-gpd)
  (let ([gpd-file #"~(cf$ 'PACKAGE_NAME).gpd"]
        [gpd (~ (ensure-package)'gpd)])
    (cf-echo #"creating ~gpd-file")
    (set! (~ gpd'configure)
          ($ string-join $ cons "./configure"
             $ map shell-escape-string $ cdr $ command-line))
    (with-output-to-file gpd-file
      (cut write-gauche-package-description gpd))))

;; API
;; Packages common output
(define (cf-output-default . output-files)
  (cf-make-gpd)
  (cf-echo (cf$ 'PACKAGE_VERSION) > "VERSION")
  (let* ([pfx (cf$'srcdir)]
         [outfiles (append
                    ($ map (^f (string-drop (string-drop-right f 3)
                                            (+ (string-length pfx) 1)))
                       $ glob #"~|pfx|/**/Makefile.in")
                    output-files)])
    (apply cf-output outfiles)))

;;;
;;; Tests - compilation
;;;

;; Dump CONTENT to a file conftext.$(cf-lang-ext) and run COMMAND.
;; The output and error goes to config.log.  Returns #t on success,
;; #f on failure.  Make sure to clean temporary files.
(define (run-compiler-with-content command content)
  (define (clean)
    (remove-files (glob "conftest.err*")
                  #"conftest.~(cf-lang-ext)"
                  #"conftest.~(cf$'OBJEXT)"
                  #"conftest~(cf$'EXEEXT)"))
  (define cmd
    (if (string? command)
      (shell-tokenize-string command)
      command))
  (unwind-protect
      (receive (errout erroutfile) (sys-mkstemp "conftest.err.")
        (log-format "configure: ~s" cmd)
        (with-output-to-file #"conftest.~(cf-lang-ext)"
          (^[] (write-tree content)))
        (let1 st ($ process-exit-status
                    (run-process cmd :wait #t
                                 :redirects `((> 1 ,errout) (> 2 ,errout))))
          (close-port errout)
          ($ generator-for-each (cut log-format "~a" <>)
             $ file->line-generator erroutfile)
          (log-format "configure: $? = ~s" (sys-wait-exit-status st))
          (unless (zero? st)
            (log-format "configure: failed program was:")
            ($ generator-for-each (cut log-format "| ~a" <>)
               $ file->line-generator #"conftest.~(cf-lang-ext)"))
          (zero? st)))
    (clean)))

;; API (no autoconf equivalent)
;; Run preprocessor and calls proc with an input port receiving the output
;; of the preprocessor.
(define (cf-call-with-cpp prologue body proc)
  (define file #"conftest.~(cf-lang-ext)")
  (define cmd `(,@(shell-tokenize-string (cf-lang-cpp-m (cf-lang))) ,file))
  (define (clean)
    (remove-files (glob "conftest.err*") file))
  (define process #f)
  (unwind-protect
      (begin
        (log-format "configure: ~s" cmd)
        (with-output-to-file file
          (cut write-tree #?=(cf-lang-program prologue body)))
        (set! process #?,(run-process cmd :output :pipe))
        (proc (process-output process)))
    (when process (process-kill process))
    (clean)))

;; API
;; Try compile BODY as the current language.
;; Returns #t on success, #f on failure.
(define (cf-try-compile prologue body)
  ($ run-compiler-with-content
     (cf-lang-compile-m (cf-lang))
     (cf-lang-program prologue body)))

;; API
;; Try compile and link BODY as the current language.
;; Returns #t on success, #f on failure.
(define (cf-try-compile-and-link prologue body)
  ($ run-compiler-with-content
     (cf-lang-link-m (cf-lang))
     (cf-lang-program prologue body)))

;; Try to produce executable from
;; This emits message---must be called in feature test api
(define (compiler-can-produce-executable?)
  (cf-msg-checking "whether the ~a compiler works" (~ (cf-lang)'name))
  (rlet1 result ($ run-compiler-with-content
                   (cf-lang-link-m (cf-lang))
                   (cf-lang-null-program-m (cf-lang)))
    (cf-msg-result (if result "yes" "no"))))

;; Feature Test API
;; Find c++ compiler.  Actually, we need the one that generates compatible
;; binary with which Gauche was compiled, but there's no reliable way
;; (except building an extension and trying to load into Gauche, but that's
;; a bit too much.)
(define (cf-prog-cxx :optional (compilers '("g++" "c++" "gpp" "aCC" "CC"
                                            "cxx" "cc++" "cl.exe" "FCC"
                                            "KCC" "RCC" "xlC_r" "xlC")))
  (cf-arg-var 'CXX)
  (cf-arg-var 'CXXFLAGS)
  (cf-arg-var 'CCC)
  (or (not (string-null? (cf-ref 'CXX)))
      (and-let* ([ccc (cf-ref 'CCC)]
                 [ (not (string-null? ccc)) ])
        (cf-subst 'CXX ccc)
        #t)
      (cf-check-tool 'CXX compilers :default "g++"))
  (parameterize ([cf-lang (instance-of <c++-language>)])
    (compiler-can-produce-executable?)))

;;;
;;; Tests - headers
;;;

;; API
;; Returns a string tree
;; Unlike AC_INCLUDES_DEFAULT, we don't accept argument.  The
;; behavior of AC_INCLUDES_DEFAULT is convenient for m4 macros,
;; but makes little sense for Scheme.
(define cf-includes-default
  (let* ([defaults '("#include <stdio.h>\n"
                     "#ifdef HAVE_SYS_TYPES_H\n"
                     "# include <sys/types.h>\n"
                     "#endif\n"
                     "#ifdef HAVE_SYS_STAT_H\n"
                     "# include <sys/stat.h>\n"
                     "#endif\n"
                     "#ifdef STDC_HEADERS\n"
                     "# include <stdlib.h>\n"
                     "# include <stddef.h>\n"
                     "#else\n"
                     "# ifdef HAVE_STDLIB_H\n"
                     "#  include <stdlib.h>\n"
                     "# endif\n"
                     "#endif\n"
                     "#ifdef HAVE_STRING_H\n"
                     "# if !defined STDC_HEADERS && defined HAVE_MEMORY_H\n"
                     "#  include <memory.h>\n"
                     "# endif\n"
                     "# include <string.h>\n"
                     "#endif\n"
                     "#ifdef HAVE_STRINGS_H\n"
                     "# include <strings.h>\n"
                     "#endif\n"
                     "#ifdef HAVE_INTTYPES_H\n"
                     "# include <inttypes.h>\n"
                     "#endif\n"
                     "#ifdef HAVE_STDINT_H\n"
                     "# include <stdint.h>\n"
                     "#endif\n"
                     "#ifdef HAVE_UNISTD_H\n"
                     "# include <unistd.h>\n"
                     "#endif\n")]
         [requires (delay
                     (begin (cf-check-headers '("sys/types.h" "sys/stat.h"
                                                "stdlib.h" "string.h" "memory.h"
                                                "strings.h" "inttypes.h"
                                                "stdint.h" "unistd.h")
                                              :includes defaults)
                            defaults))])
    (^[] (force requires))))

;; Feature Test API
;; Like AC_CHECK_HEADER.
;; Returns #t on success, #f on failure.
(define (cf-header-available? header-file :key (includes #f))
  (let1 includes (or includes (cf-includes-default))
    (cf-msg-checking "~a usability" header-file)
    (rlet1 result (cf-try-compile (list includes
                                        "/* Testing compilability */"
                                        #"#include <~|header-file|>\n")
                                  "")
      (cf-msg-result (if result "yes" "no")))))
(define cf-check-header cf-header-available?) ;; autoconf compatible name

;; Feature Test API
;; Like AC_CHECK_HEADERS.  Besides the check, it defines HAVE_<header-file>
;; definition.
(define (cf-check-headers header-files
                          :key (includes #f) (if-found #f) (if-not-found #f))
  (dolist [h header-files]
    (if (cf-check-header h :includes includes)
      (begin (cf-define (string->symbol #"HAVE_~(safe-variable-name h)"))
             (when if-found (if-found h)))
      (when if-not-found (if-not-found h)))))

;; Feature Test API
;; Like AC_CHECK_TYPE.
;; Returns #t on success, #f on failure.
;; If TYPE is a valid type, sizeof(TYPE) compiles and sizeof((TYPE)) fails.
;; The second test is needed in case TYPE happens to be a variable.
(define (cf-type-available? type :key (includes #f))
  (let1 includes (or includes (cf-includes-default))
    (cf-msg-checking "for ~a" type)
    (rlet1 result
        (and (cf-try-compile (list includes)
                             #"if (sizeof (~|type|)) return 0;")
             (not (cf-try-compile (list includes)
                                  #"if (sizeof ((~|type|))) return 0;")))
      (cf-msg-result (if result "yes" "no")))))
(define cf-check-type cf-type-available?)  ; autoconf-compatible name

;; Feature Test API
;; Like AC_CHECK_TYPES.
;; For each type in types, run cf-check-type and define HAVE_type if found.
(define (cf-check-types types :key (includes #f)
                                   (if-found identity)
                                   (if-not-found identity))
  (dolist [type types]
    (if (cf-check-type type :includes includes)
      (begin (cf-define (string->symbol #"HAVE_~(safe-variable-name type)"))
             (if-found type))
      (if-not-found type))))

;; Feature Test API
;; Like AC_CHECK_DECL
;; Returns #t on success, #f on failure.
;; Check SYMBOL is declared as a macro, a constant, a variable or a function.
(define (cf-decl-available? symbol :key (includes #f))
  (let1 includes (or includes (cf-includes-default))
    (cf-msg-checking "whether ~a is declared" symbol)
    (rlet1 result
        (cf-try-compile (list includes)
                        (list #"#ifndef ~|symbol|\n"
                              #" (void)~|symbol|;\n"
                              #"#endif\n"
                              "return 0;"))
      (cf-msg-result (if result "yes" "no")))))
(define cf-check-decl cf-decl-available?)  ;autoconf-compatible name

;; Feature Test API
;; Like AC_CHECK_DECLS
;; For each symbol in symbols, run cf-check-decl and define HAVE_DECL_symbol
;; to 1 (found) or 0 (not found).
(define (cf-check-decls symbols :key (includes #f)
                                     (if-found identity)
                                     (if-not-found identity))
  (dolist [symbol symbols]
    (let1 nam (string->symbol #"HAVE_DECL_~(safe-variable-name symbol)")
      (if (cf-check-decl symbol :includes includes)
        (begin (cf-define nam 1)
               (if-found symbol))
        (begin (cf-define nam 0)
               (if-not-found symbol))))))

;; Feature Test API
;; Like AC_CHECK_MEMBER
;; Works as a predicate
(define (cf-member-available? aggregate.member :key (includes #f))
  (receive (aggr memb) (string-scan aggregate.member #\. 'both)
    (unless (and aggr memb)
      (error "cf-check-member: argument doesn't contain a dot:"
             aggregate.member))
    (cf-msg-checking "`~a' is a member of `~a'" memb aggr)
    (let1 includes (or includes (cf-includes-default))
      (rlet1 result
          (or (cf-try-compile (list includes)
                              (list #"static ~aggr ac_aggr;\n"
                                    #"if (ac_aggr.~|memb|) return 0;"))
              (cf-try-compile (list includes)
                              (list #"static ~aggr ac_aggr;\n"
                                    #"if (sizeof ac_aggr.~|memb|) return 0;")))
        (cf-msg-result (if result "yes" "no"))))))
(define cf-check-member cf-member-available?) ;autoconf-compatible name

;; Feature Test API
;; Like AC_CHECK_MEMBERS
(define (cf-check-members members :key (includes #f)
                                       (if-found identity)
                                       (if-not-found identity))
  (dolist [mem members]
    (if (cf-check-member mem :includes includes)
      (begin (cf-define (string->symbol #"HAVE_~(safe-variable-name mem)"))
             (if-found mem))
      (if-not-found mem))))

;; Feature Test API
;; Like AC_CHECK_FUNC
;; NB: autoconf has language-dependent methods (AC_LANG_FUNC_LINK_TRY)
;; For now, we hardcode C.
(define (cf-func-available? func)
  (let1 includes (cf-includes-default)
    (cf-msg-checking #"for ~func")
    (rlet1 result ($ cf-try-compile-and-link
                     `(,#"#define ~func innocuous_~func\n"
                       "#ifdef __STDC__\n"
                       "# include <limits.h>\n"
                       "#else\n"
                       "# include <assert.h>\n"
                       "#endif\n"
                       ,#"#undef ~func\n"
                       "#ifdef __cplusplus\n"
                       "extern \"C\"\n"
                       "#endif\n"
                       ,#"char ~func ();\n")
                     `(,#"return ~func ();"))
      (cf-msg-result (if result "yes" "no")))))
(define cf-check-func cf-func-available?)  ;autoconf-compatible name

;; Feature Test API
;; Like AC_CHECK_FUNCS
(define (cf-check-funcs funcs :key (if-found identity)
                                   (if-not-found identity))
  (dolist [f funcs]
    (if (cf-check-func f)
      (begin (cf-define (string->symbol #"HAVE_~(safe-variable-name f)"))
             (if-found f))
      (if-not-found f))))


(define (default-lib-found libname)
  (when libname
    (cf-subst-prepend 'LIBS #"-l~|libname|")
    (cf-define (string->symbol #"HAVE_LIB~(safe-variable-name libname)")))
  #t)

(define (default-lib-not-found libname) #f)

;; Feature Test API
;; Like AC_CHECK_LIB
(define (cf-lib-available? lib fn
                        :key (other-libs '())
                        (if-found default-lib-found)
                        (if-not-found default-lib-not-found))
  (let1 includes (cf-includes-default)
    (cf-msg-checking "for ~a in -l~a" fn lib)
    (if (with-cf-subst
         ([LIBS #"-l~|lib| ~(string-join other-libs \" \") ~(cf$'LIBS)"])
         (cf-try-compile-and-link includes
                                  (format "extern void ~a(); ~a();" fn fn)))
      (begin
        (cf-msg-result "yes")
        (if-found lib))
      (begin
        (cf-msg-result "no")
        (if-not-found lib)))))
(define cf-check-lib cf-lib-available?)    ;autoconf-compatible name

(define (default-lib-search-found libname)
  (when libname
    (cf-subst-prepend 'LIBS #"-l~|libname|"))
  #t)

;; Feature test API
;; Like AC_CHECK_LIBS
(define (cf-search-libs fn libs
                        :key (other-libs '())
                             (if-found default-lib-search-found)
                             (if-not-found default-lib-not-found))
  (let ([includes (cf-includes-default)]
        [xlibs #"~(string-join other-libs \" \") ~(cf$'LIBS)"])
    (define (try lib)
      (with-cf-subst
       ([LIBS (if (eq? lib 'none) xlibs #"-l~|lib| ~xlibs")])
       (cf-try-compile-and-link includes
                                (format "extern void ~a(); ~a();"
                                        fn fn))))
    (cf-msg-checking "for ~a" fn)
    (if-let1 lib (find try (cons 'none libs))
      (begin
        (cf-msg-result (if (eq? lib 'none) "found" #"found in -l~|lib|"))
        (if-found (if (eq? lib 'none) #f lib)))
      (begin
        (cf-msg-result "no")
        (if-not-found #f)))))

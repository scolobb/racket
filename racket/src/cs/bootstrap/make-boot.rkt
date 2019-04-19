#lang racket/base
(require racket/runtime-path
         racket/match
         racket/file
         (only-in "r6rs-lang.rkt")
         (only-in "scheme-lang.rkt"
                  current-expand)
         (submod "scheme-lang.rkt" callback)
         "syntax-mode.rkt"
         "r6rs-readtable.rkt"
         "scheme-readtable.rkt"
         "parse-makefile.rkt"
         "config.rkt")

;; Writes ".boot" and ".h" files to a "compiled" subdirectory of the
;; current directory.

;; Set `SCHEME_DIR` and `MACH` to specify the ChezScheme source
;; directory and the target machine.

(define nano-dir (build-path scheme-dir "nanopass"))

(define-runtime-module-path r6rs-lang-mod "r6rs-lang.rkt")
(define-runtime-module-path scheme-lang-mod "scheme-lang.rkt")

(define-values (petite-sources scheme-sources)
  (get-sources-from-makefile scheme-dir))

(define (status msg)
  (printf "~a\n" msg)
  (flush-output))

(define ns (make-base-empty-namespace))
(namespace-attach-module (current-namespace) r6rs-lang-mod ns)
(namespace-attach-module (current-namespace) scheme-lang-mod ns)

(namespace-require/copy r6rs-lang-mod ns) ; get `library`

(status "Load nanopass")
(define (load-nanopass)
  (load/cd (build-path nano-dir "nanopass/helpers.ss"))
  (load/cd (build-path nano-dir "nanopass/syntaxconvert.ss"))
  (load/cd (build-path nano-dir "nanopass/records.ss"))
  (load/cd (build-path nano-dir "nanopass/meta-syntax-dispatch.ss"))
  (load/cd (build-path nano-dir "nanopass/meta-parser.ss"))
  (load/cd (build-path nano-dir "nanopass/pass.ss"))
  (load/cd (build-path nano-dir "nanopass/language-node-counter.ss"))
  (load/cd (build-path nano-dir "nanopass/unparser.ss"))
  (load/cd (build-path nano-dir "nanopass/language-helpers.ss"))
  (load/cd (build-path nano-dir "nanopass/language.ss"))
  (load/cd (build-path nano-dir "nanopass/nano-syntax-dispatch.ss"))
  (load/cd (build-path nano-dir "nanopass/parser.ss"))
  (load/cd (build-path nano-dir "nanopass.ss")))
(parameterize ([current-namespace ns]
               [current-readtable r6rs-readtable])
  (load/cd (build-path nano-dir "nanopass/implementation-helpers.ikarus.ss"))
  (load-nanopass))

(namespace-require/copy ''nanopass ns)

(namespace-require/copy scheme-lang-mod ns)

(namespace-require `(for-syntax ,r6rs-lang-mod) ns)
(namespace-require `(for-syntax ,scheme-lang-mod) ns)
(namespace-require `(for-meta 2 ,r6rs-lang-mod) ns)
(namespace-require `(for-meta 2 ,scheme-lang-mod) ns)

(namespace-require `(only (submod (file ,(path->string (resolved-module-path-name r6rs-lang-mod))) ikarus) with-implicit)
                   ns)

(define orig-eval (current-eval))

(define (call-with-expressions path proc)
  (call-with-input-file*
   path
   (lambda (i)
     (let loop ()
       (define e (read i))
       (unless (eof-object? e)
         (proc e)
         (loop))))))

(define (load-ss path)
  (define-values (base name dir) (split-path (path->complete-path path)))
  (parameterize ([current-directory base])
    (call-with-expressions path eval)))

(parameterize ([current-namespace ns]
               [current-readtable scheme-readtable]
               [compile-allow-set!-undefined #t]
               [current-eval (current-eval)])

  (status "Load cmacro parts")
  (call-with-expressions
   (build-path scheme-dir "s/cmacros.ss")
   (lambda (e)
     (define (define-macro? m)
       (memq m '(define-syntactic-monad define-flags set-flags)))
     (define (define-for-syntax? m)
       (memq m '(lookup-constant flag->mask)))
     (match e
       [`(define-syntax ,m . ,_)
        (when (define-macro? m)
          (orig-eval e))]
       [`(eval-when ,_ (define ,m . ,rhs))
        (when (define-for-syntax? m)
          (orig-eval `(begin-for-syntax (define ,m . ,rhs))))]
       [_ (void)])))

  (set-current-expand-set-callback!
   (lambda ()
     (start-fully-unwrapping-syntax!)
     (status "Load expander")
     (define $uncprep (orig-eval '$uncprep))
     (current-eval
      (lambda (stx)
        (syntax-case stx ()
          [("noexpand" form)
           (orig-eval ($uncprep (syntax-e #'form)))]
          [_
           (orig-eval stx)])))
     (call-with-expressions
      (build-path scheme-dir "s/syntax.ss")
      (lambda (e)
        (when (and (pair? e)
                   (eq? 'define-syntax (car e)))
          ((current-expand) `(define-syntax ,(cadr e)
                               ',(orig-eval (caddr e)))))))
     (status "Install evaluator")
     (current-eval
      (let ([e (current-eval)])
        (lambda (stx)
          (define ex ((current-expand)
                      (syntax->datum
                       (let loop ([stx stx])
                         (syntax-case* stx (#%top-interaction eval-when compile) (lambda (a b)
                                                                                   (eq? (syntax-e a) (syntax-e b)))
                           [(#%top-interaction . rest) (loop #'rest)]
                           [(eval-when (compile) . rest)
                            #'(eval-when (compile eval load) . rest)]
                           [_ stx])))))
          (define r (if (struct? ex)
                        ($uncprep ex)
                        ex))
          (e r))))
     (status "Load cmacros using expander")
     (load-ss (build-path scheme-dir "s/cmacros.ss"))
     (status "Continue loading expander")))

  (status "Load enum")
  (load-ss (build-path scheme-dir "s/enum.ss"))
  (eval '(define $annotation-options (make-enumeration '(debug profile))))
  (eval '(define $make-annotation-options (enum-set-constructor $annotation-options)))
  (eval
   '(define-syntax-rule (library-requirements-options id ...)
      (with-syntax ([members ($enum-set-members ($make-library-requirements-options (datum (id ...))))])
        #'($record (record-rtd $library-requirements-options) members))))

  (status "Load cprep")
  (load-ss (build-path scheme-dir "s/cprep.ss"))

  (status "Load expander")
  (load-ss (build-path scheme-dir "s/syntax.ss"))

  (status "Initialize system libraries")
  (define (init-libraries)
    (eval '($make-base-modules))
    (eval '($make-rnrs-libraries))
    (eval '(library-search-handler (lambda args (values #f #f #f))))
    (eval '(define-syntax guard
             (syntax-rules (else)
               [(_ (var clause ... [else e1 e2 ...]) b1 b2 ...)
                ($guard #f (lambda (var) (cond clause ... [else e1 e2 ...]))
                        (lambda () b1 b2 ...))]
               [(_ (var clause1 clause2 ...) b1 b2 ...)
                ($guard #t (lambda (var p) (cond clause1 clause2 ... [else (p)]))
                        (lambda () b1 b2 ...))]))))
  (init-libraries)
  
  (status "Load nanopass using expander")
  (load-ss (build-path nano-dir "nanopass/implementation-helpers.chezscheme.sls"))
  (load-nanopass)

  (status "Load priminfo and primvars")
  (load-ss (build-path scheme-dir "s/priminfo.ss"))
  (load-ss (build-path scheme-dir "s/primvars.ss"))

  (status "Load expander using expander")
  (set-current-expand-set-callback! void)
  (load-ss (build-path scheme-dir "s/syntax.ss"))

  (status "Initialize system libraries in bootstrapped expander")
  (init-libraries)
  
  (status "Declare nanopass in bootstrapped expander")
  (load-ss (build-path nano-dir "nanopass/implementation-helpers.chezscheme.sls"))
  (load-nanopass)

  (status "Load some io.ss declarations")
  (call-with-expressions
   (build-path scheme-dir "s/io.ss")
   (lambda (e)
     (define (want-syntax? id)
       (memq id '(file-options-list eol-style-list error-handling-mode-list)))
     (define (want-val? id)
       (memq id '($file-options $make-file-options $eol-style? buffer-mode? $error-handling-mode?)))
     (let loop ([e e])
       (match e
         [`(let () ,es ...)
          (for-each loop es)]
         [`(define-syntax ,id . ,_)
          (when (want-syntax? id)
            (eval e))]
         [`(set-who! ,id . ,_)
          (when (want-val? id)
            (eval e))]
         [_ (void)]))))

  (status "Load some strip.ss declarations")
  (call-with-expressions
   (build-path scheme-dir "s/strip.ss")
   (lambda (e)
     (let loop ([e e])
       (match e
         [`(let () ,es ...)
          (for-each loop es)]
         [`(set-who! $fasl-strip-options . ,_)
          (eval e)]
         [`(set-who! $make-fasl-strip-options . ,_)
          (eval e)]
         [_ (void)]))))

  (status "Load some 7.ss declarations")
  (call-with-expressions
   (build-path scheme-dir "s/7.ss")
   (lambda (e)
     (let loop ([e e])
       (match e
         [`(define $format-scheme-version . ,_)
          (eval e)]
         [`(define ($compiled-file-header? . ,_) . ,_)
          (eval e)]
         [_ (void)]))))

  (status "Load most front.ss declarations")
  (call-with-expressions
   (build-path scheme-dir "s/front.ss")
   (lambda (e)
     ;; Skip `package-stubs`, which would undo "syntax.ss" definitions
     (match e
       [`(package-stubs . ,_) (void)]
       [`(define-who make-parameter . ,_) (void)]
       [_ (eval e)])))
  ((orig-eval 'current-eval) eval)
  ((orig-eval 'current-expand) (current-expand))
  ((orig-eval 'enable-type-recovery) #f)

  (status "Define $filter-foreign-type")
  (eval `(define $filter-foreign-type
           (lambda (ty)
             (filter-foreign-type ty))))

  (status "Load mkheader")
  (load-ss (build-path scheme-dir "s/mkheader.ss"))
  (status "Generate headers")
  (eval `(mkscheme.h "compiled/scheme.h" ,target-machine))
  (eval `(mkequates.h "compiled/equates.h"))

  (for ([s (in-list '("ftype.ss"
                      "fasl.ss"
                      "reloc.ss"
                      "format.ss"
                      "cp0.ss"
                      "cpvalid.ss"
                      "cpcheck.ss"
                      "cpletrec.ss"
                      "cpcommonize.ss"
                      "cpnanopass.ss"
                      "compile.ss"
                      "back.ss"))])
    (status (format "Load ~a" s))
    (load-ss (build-path scheme-dir "s" s)))

  (make-directory* "compiled")
  
  (let ([failed? #f])
    (for ([src (append petite-sources scheme-sources)])
      (let ([dest (path->string (path->complete-path (build-path "compiled" (path-replace-suffix src #".so"))))])
        (parameterize ([current-directory (build-path scheme-dir "s")])
          ;; (status (format "Compile ~a" src)) - Chez Scheme prints its own message
          (with-handlers ([exn:fail? (lambda (exn)
                                       (eprintf "ERROR: ~s\n" (exn-message exn))
                                       (set! failed? #t))])
            ((orig-eval 'compile-file) src dest)))))
    (when failed?
      (raise-user-error 'make-boot "compilation failure(s)")))

  (let ([src->so (lambda (src)
                   (path->string (build-path "compiled" (path-replace-suffix src #".so"))))])
    (status "Writing petite.boot")
    (eval `($make-boot-file "compiled/petite.boot" ',(string->symbol target-machine) '()
                            ,@(map src->so petite-sources)))
    (status "Writing scheme.boot")
    (eval `($make-boot-file "compiled/scheme.boot" ',(string->symbol target-machine) '("petite")
                            ,@(map src->so scheme-sources)))))